-- Qualify rate-limit column to distinguish it from the PL/pgSQL variable.
CREATE OR REPLACE FUNCTION private.yt_moon_preorder_scan(p_draft uuid, p_code text, p_cart jsonb, p_drink text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor uuid:=auth.uid();v_code text;v public.yt_moon_guest_codes%rowtype;
 hold_id uuid;v_paid int;v_gross numeric;v_name text;v_now timestamptz:=clock_timestamp();attempts int;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_draft is null or p_cart is null then raise exception 'invalid_draft';end if;
 select gross_rm,paid_drinks into v_gross,v_paid from private.yt_pos_draft_price(p_cart);
 if v_paid<1 or v_gross<=0 then raise exception 'minimum_one_paid_drink';end if;
 insert into private.yt_redeem_code_attempts as a(operator_id,window_started_at,attempts)
 values(v_actor,v_now,1) on conflict(operator_id) do update set
 attempts=case when a.window_started_at<=v_now-interval '1 minute' then 1 else least(a.attempts+1,26) end,
 window_started_at=case when a.window_started_at<=v_now-interval '1 minute' then v_now else a.window_started_at end
 returning a.attempts into attempts;
 if attempts>25 then return jsonb_build_object('error_code','short_code_rate_limited');end if;
 begin v_code:=private.yt_moon_norm(p_code);
 exception when others then return jsonb_build_object('error_code','moon_invalid_code');end;
 perform pg_advisory_xact_lock(hashtextextended('moon:'||v_code,0));
 select * into v from public.yt_moon_guest_codes where code=v_code for update;
 if not found then return jsonb_build_object('error_code','moon_code_not_found');end if;
 if v.status='redeemed' then return jsonb_build_object('error_code','moon_already_redeemed');end if;
 if v.status<>'available' then return jsonb_build_object('error_code','moon_reserved_elsewhere');end if;
 if v.valid_until<(v_now at time zone 'Asia/Kuala_Lumpur')::date then return jsonb_build_object('error_code','moon_expired');end if;
 if v.issued_on>(v_now at time zone 'Asia/Kuala_Lumpur')::date then return jsonb_build_object('error_code','moon_not_started');end if;
 if v.kind in ('R5','R4') and length(btrim(coalesce(p_drink,'')))<2 then
  return jsonb_build_object('requires_drink',true,'code',v_code,'kind',v.kind,
   'label',case when v.kind='R5' then '断片指南' else '微醺特调' end);
 end if;
 v_name:=case when v.kind='R3' then '彩虹 Shot' when v.kind in ('R5','R4') then btrim(p_drink) else null end;
 if v_name is not null and length(v_name)>110 then raise exception 'moon_drink_required';end if;
 update public.yt_moon_preorder_holds set state='released'
 where code_id=v.id and state='held' and expires_at<=v_now;
 select id into hold_id from public.yt_moon_preorder_holds
 where code_id=v.id and state='held' and operator_id=v_actor and draft_id=p_draft for update;
 if hold_id is not null then
  return jsonb_build_object('id',hold_id,'code',v_code,'kind',v.kind,'drink',v_name,'idempotent',true);
 end if;
 if exists(select 1 from public.yt_moon_preorder_holds where code_id=v.id and state='held')
 then return jsonb_build_object('error_code','moon_reserved_elsewhere');end if;
 insert into public.yt_moon_preorder_holds(draft_id,operator_id,code_id,drink_name)
 values(p_draft,v_actor,v.id,v_name) returning id into hold_id;
 return jsonb_build_object('id',hold_id,'code',v_code,'kind',v.kind,'drink',v_name,'idempotent',false);
end $function$
;
