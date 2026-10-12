-- Lucky Box RPCs. QR codes remain normal GamePass claim/bundle UUID URLs.
-- Guest reveal is single-use, owner-independent and server-side; points are credited only to PIN members.
create function private.yt_lucky_block_old_claim() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.lucky_mode='lucky' and new.status='claimed' and old.customer_id is null
 then raise exception 'lucky_box_use_open_flow';end if;
 return new;
end $$;
create trigger yt_lucky_block_old_claim before update of customer_id on public.game_passes
for each row execute function private.yt_lucky_block_old_claim();

create function private.yt_lucky_owner_settings() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare s jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select to_jsonb(c) into s from public.yt_lucky_settings c where id=true;
 return s||jsonb_build_object('opened',(select count(*) from public.yt_lucky_results),
  'claimed',(select count(*) from public.yt_lucky_results where claimed_at is not null),
  'points_credited',(select coalesce(sum(points),0) from public.yt_lucky_results where claimed_at is not null));
end $$;
create function private.yt_lucky_owner_save(p_settings jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare current_s public.yt_lucky_settings%rowtype; m text; bp numeric; cp numeric; ms numeric; cm integer; w integer[]; h integer[];
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select * into current_s from public.yt_lucky_settings where id=true for update;
 m:=coalesce(p_settings->>'mode',current_s.mode);
 bp:=coalesce((p_settings->>'base_points_per_rm')::numeric,current_s.base_points_per_rm);
 cp:=coalesce((p_settings->>'cap_points_per_rm')::numeric,current_s.cap_points_per_rm);
 ms:=coalesce((p_settings->>'minimum_spend_rm')::numeric,current_s.minimum_spend_rm);
 cm:=coalesce((p_settings->>'claim_minutes')::integer,current_s.claim_minutes);
 w:=coalesce((select array_agg((v.value)::integer order by v.ordinality)
   from jsonb_array_elements_text(p_settings->'weights') with ordinality v(value,ordinality)),current_s.weights);
 h:=coalesce((select array_agg((v.value)::integer order by v.ordinality)
   from jsonb_array_elements_text(p_settings->'hidden_probabilities') with ordinality v(value,ordinality)),current_s.hidden_probabilities);
 if m not in ('game','lucky','off') or bp not between 0.1 and 50 or cp not between 0.1 and 100
  or bp>cp or ms not between 1 and 5000 or cm not between 3 and 120
  or cardinality(w)<>4 or cardinality(h)<>4 or exists(select 1 from unnest(w) t where t<0 or t>100)
  or (select sum(t) from unnest(w) t)<>100 or exists(select 1 from unnest(h) t where t<0 or t>10)
  or not (h[1]<=h[2] and h[2]<=h[3] and h[3]<=h[4])
 then raise exception 'lucky_invalid_settings';end if;
 update public.yt_lucky_settings set mode=m,base_points_per_rm=bp,cap_points_per_rm=cp,minimum_spend_rm=ms,
 claim_minutes=cm,weights=w,hidden_probabilities=h,version=version+1,updated_at=now(),updated_by=auth.uid()
 where id=true;
 return private.yt_lucky_owner_settings();
end $$;
create function private.yt_lucky_owner_reset() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 perform private.yt_lucky_reset_settings();
 return private.yt_lucky_owner_settings();
end $$;
create function private.yt_lucky_public_mode() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('mode',mode,'minimum_spend_rm',minimum_spend_rm,'version',version) from public.yt_lucky_settings where id=true
$$;

create function private.yt_lucky_preview(p_token uuid,p_kind text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare h text;v_id uuid; v_mode text;v_status text;v_expires timestamptz;v_opened boolean:=false;
begin
 if p_token is null or p_kind not in ('claim','bundle') then raise exception 'invalid_lucky_code';end if;
 h:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 if p_kind='claim' then
  select p.id,p.lucky_mode,p.status,p.expires_at into v_id,v_mode,v_status,v_expires
   from public.game_passes p where p.claim_token_hash=h;
  if not found then return jsonb_build_object('lucky',false);end if;
  if v_mode<>'lucky' then return jsonb_build_object('lucky',false);end if;
  select exists(select 1 from public.yt_lucky_results where pass_id=v_id) into v_opened;
 else
  select b.id,b.lucky_mode,b.status,b.expires_at into v_id,v_mode,v_status,v_expires
   from public.yt_pos_pass_bundles b where b.token_hash=h;
  if not found or v_mode<>'lucky' then return jsonb_build_object('lucky',false);end if;
  select exists(select 1 from public.yt_lucky_results where bundle_id=v_id) into v_opened;
 end if;
 return jsonb_build_object('lucky',true,'valid',(v_status='issued' and v_expires>clock_timestamp() and not v_opened),
 'opened',v_opened,'expires_at',v_expires,'title','Lucky Box','claim_requires_member',true);
end $$;

create function private.yt_lucky_reveal(p_token uuid,p_kind text,p_secret uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare h text;secret_h text; v_ref uuid;v_pass uuid;v_order uuid;v_mode text;v_status text;v_exp timestamptz;
 v_order_row public.yt_member_orders%rowtype;v_result public.yt_lucky_results%rowtype;
 v_order_mode public.yt_lucky_order_modes%rowtype;v_draw public.yt_lucky_order_draws%rowtype;
 v_gross numeric:=0;v_eligible_gross numeric:=0;v_fraction numeric:=0;v_total numeric:=0;v_box_gross numeric:=0;v_box_amount numeric:=0;
 v_pick numeric;v_rnd numeric;v_chance integer;v_w integer[];v_h integer[];v_base numeric;v_cap numeric;v_min numeric;v_claim_minutes integer;
 v_pts integer;v_box_cap integer;v_grade text;v_legendary boolean:=false;v_hidden_item uuid;v_hidden_unit int;
 v_unit record;v_first uuid;
begin
 if p_token is null or p_secret is null or p_kind not in ('claim','bundle') then raise exception 'invalid_lucky_code';end if;
 perform pg_advisory_xact_lock(781943081);
 h:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 secret_h:=encode(sha256(convert_to(p_secret::text,'UTF8')),'hex');
 if p_kind='claim' then
  select id,lucky_mode,status,expires_at into v_ref,v_mode,v_status,v_exp from public.game_passes where claim_token_hash=h for update;
  select i.order_id into v_order from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id where u.game_pass_id=v_ref;
 else
  select id,lucky_mode,status,expires_at,order_id into v_ref,v_mode,v_status,v_exp,v_order from public.yt_pos_pass_bundles where token_hash=h for update;
 end if;
 if v_ref is null or v_mode<>'lucky' or v_order is null then raise exception 'invalid_lucky_code';end if;
 select * into v_result from public.yt_lucky_results
 where (p_kind='claim' and pass_id=v_ref) or (p_kind='bundle' and bundle_id=v_ref) for update;
 if found then
  if v_result.secret_hash<>secret_h then raise exception 'lucky_already_opened';end if;
  return jsonb_build_object('id',v_result.id,'points',v_result.points,'grade',v_result.grade,'amount_rm',v_result.box_amount_rm,
   'claim_deadline',v_result.claim_deadline,'claimed',v_result.claimed_at is not null,'idempotent',true);
 end if;
 if v_status<>'issued' or v_exp<=clock_timestamp() then raise exception 'lucky_code_expired';end if;
 select * into v_order_row from public.yt_member_orders where id=v_order and source='future_pos' for update;
 if not found or v_order_row.payment_status<>'paid' or v_order_row.status<>'fulfilled' or v_order_row.cancel_after_refund
  or v_order_row.settlement_due_since is not null then raise exception 'lucky_order_not_eligible';end if;
 select * into v_order_mode from public.yt_lucky_order_modes where order_id=v_order;
 if not found or v_order_mode.mode<>'lucky' then raise exception 'lucky_mode_mismatch';end if;
 v_base:=(v_order_mode.settings->>'base_points_per_rm')::numeric;
 v_cap:=(v_order_mode.settings->>'cap_points_per_rm')::numeric;
 v_min:=(v_order_mode.settings->>'minimum_spend_rm')::numeric;
 v_claim_minutes:=(v_order_mode.settings->>'claim_minutes')::integer;
 select array_agg(x::integer) into v_w from jsonb_array_elements_text(v_order_mode.settings->'weights') x;
 select array_agg(x::integer) into v_h from jsonb_array_elements_text(v_order_mode.settings->'hidden_probabilities') x;
 select coalesce(sum(i.quantity*i.unit_price_rm),0) into v_gross from public.yt_member_order_items i where i.order_id=v_order;
 select coalesce(sum(i.unit_price_rm),0) into v_eligible_gross from public.yt_member_order_items i
 join public.yt_pos_item_units u on u.order_item_id=i.id
 where i.order_id=v_order and i.is_drink_at_order and i.unit_price_rm>0 and not u.retired and u.unit_number<=i.quantity
 and u.reward_redemption_id is null;
 if v_gross<=0 or v_eligible_gross<=0 then raise exception 'lucky_order_not_eligible';end if;
 v_fraction:=least(1,v_order_row.amount_rm/v_gross);
 v_total:=round(v_eligible_gross*v_fraction,2);
 if v_total<v_min then raise exception 'lucky_minimum_spend';end if;
 if p_kind='claim' then
  if exists(select 1 from public.yt_pos_pass_bundle_items x join public.yt_pos_pass_bundles b on b.id=x.bundle_id
     where x.pass_id=v_ref and b.status='issued' and b.expires_at>clock_timestamp())
   then raise exception 'use_whole_order_claim';end if;
  if exists(select 1 from public.yt_lucky_results r join public.yt_pos_pass_bundle_items x on x.bundle_id=r.bundle_id where x.pass_id=v_ref)
   then raise exception 'lucky_already_opened';end if;
  select i.unit_price_rm into v_box_gross from public.yt_pos_item_units u
   join public.yt_member_order_items i on i.id=u.order_item_id
   where u.game_pass_id=v_ref and i.is_drink_at_order and i.unit_price_rm>0 and not u.retired and u.unit_number<=i.quantity
    and u.reward_redemption_id is null;
  v_first:=v_ref;
 else
  if exists(select 1 from public.yt_pos_pass_bundle_items x join public.yt_lucky_results r on r.pass_id=x.pass_id where x.bundle_id=v_ref)
   then raise exception 'lucky_already_opened';end if;
  select coalesce(sum(i.unit_price_rm),0),(array_agg(x.pass_id order by x.pass_id))[1] into v_box_gross,v_first
   from public.yt_pos_pass_bundle_items x join public.game_passes p on p.id=x.pass_id
   join public.yt_pos_item_units u on u.order_item_id=x.order_item_id and u.unit_number=x.unit_number and u.game_pass_id=p.id
   join public.yt_member_order_items i on i.id=x.order_item_id
   where x.bundle_id=v_ref and i.order_id=v_order and i.is_drink_at_order and i.unit_price_rm>0
    and p.lucky_mode='lucky' and p.status='issued' and p.customer_id is null and not u.retired and u.reward_redemption_id is null;
 end if;
 if v_box_gross is null or v_box_gross<=0 or v_first is null then raise exception 'lucky_box_not_eligible';end if;
 v_box_amount:=round(v_box_gross*v_fraction,2);
 v_box_cap:=least(1000000,floor(v_box_gross*v_fraction*v_cap)::integer);
 if v_box_cap<1 then raise exception 'lucky_box_not_eligible';end if;
 select * into v_draw from public.yt_lucky_order_draws where order_id=v_order for update;
 if not found then
  v_chance:=case when v_total<50 then v_h[1] when v_total<100 then v_h[2] when v_total<200 then v_h[3] else v_h[4] end;
  if random()*100 < v_chance then
   v_pick:=random()*v_eligible_gross;
   for v_unit in select i.id item_id,u.unit_number,i.unit_price_rm price from public.yt_member_order_items i
     join public.yt_pos_item_units u on u.order_item_id=i.id
     where i.order_id=v_order and i.is_drink_at_order and i.unit_price_rm>0 and not u.retired
      and u.unit_number<=i.quantity and u.reward_redemption_id is null order by i.id,u.unit_number
   loop
    v_pick:=v_pick-v_unit.price;
    if v_pick<=0 then v_hidden_item:=v_unit.item_id;v_hidden_unit:=v_unit.unit_number;exit;end if;
   end loop;
  end if;
  insert into public.yt_lucky_order_draws(order_id,eligible_total_rm,cap_points,hidden_item_id,hidden_unit)
   values(v_order,v_total,least(1000000,floor(v_eligible_gross*v_fraction*v_cap)::integer),v_hidden_item,v_hidden_unit)
   returning * into v_draw;
 end if;
 if v_draw.hidden_item_id is not null then
  if p_kind='claim' then
    select exists(select 1 from public.yt_pos_item_units u where u.game_pass_id=v_ref and
     u.order_item_id=v_draw.hidden_item_id and u.unit_number=v_draw.hidden_unit) into v_legendary;
  else
    select exists(select 1 from public.yt_pos_pass_bundle_items x where x.bundle_id=v_ref
      and x.order_item_id=v_draw.hidden_item_id and x.unit_number=v_draw.hidden_unit) into v_legendary;
  end if;
 end if;
 v_rnd:=random()*100;
 if v_rnd<v_w[1] then v_grade:='ordinary';v_pts:=floor(v_box_gross*v_fraction*v_base*0.5);
 elsif v_rnd<v_w[1]+v_w[2] then v_grade:='lucky';v_pts:=floor(v_box_gross*v_fraction*v_base);
 elsif v_rnd<v_w[1]+v_w[2]+v_w[3] then v_grade:='shining';v_pts:=floor(v_box_gross*v_fraction*v_base*1.5);
 else v_grade:='gold';v_pts:=floor(v_box_gross*v_fraction*v_base*2);end if;
 if v_legendary then v_grade:='legendary';v_pts:=floor(v_box_gross*v_fraction*v_base*2.5);end if;
 v_pts:=greatest(0,least(v_pts,v_box_cap));
 insert into public.yt_lucky_results(order_id,pass_id,bundle_id,secret_hash,points,grade,box_amount_rm,claim_deadline)
  values(v_order,case when p_kind='claim' then v_ref else null end,
   case when p_kind='bundle' then v_ref else null end,
   secret_h,v_pts,v_grade,v_box_amount,clock_timestamp()+make_interval(mins=>v_claim_minutes))
 returning * into v_result;
 return jsonb_build_object('id',v_result.id,'points',v_pts,'grade',v_grade,'amount_rm',v_box_amount,
  'claim_deadline',v_result.claim_deadline,'claimed',false,'idempotent',false);
end $$;

create function private.yt_lucky_claim(p_secret uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();r public.yt_lucky_results%rowtype;v_pass uuid;v_balance bigint;v_exp timestamptz;v_days integer;
begin
 if actor is null or not exists(select 1 from public.pin_accounts where auth_user_id=actor)
  or exists(select 1 from public.work_accounts where auth_user_id=actor) then raise exception 'customer_only';end if;
 if p_secret is null then raise exception 'invalid_lucky_secret';end if;
 perform pg_advisory_xact_lock(781943081);
 select * into r from public.yt_lucky_results where secret_hash=encode(sha256(convert_to(p_secret::text,'UTF8')),'hex') for update;
 if not found then raise exception 'invalid_lucky_secret';end if;
 if r.claimed_at is not null then
  if r.customer_id<>actor then raise exception 'lucky_already_claimed';end if;
  v_balance:=private.yt_points_sync(actor);
  return jsonb_build_object('ok',true,'idempotent',true,'points',r.points,'balance',v_balance);
 end if;
 if r.claim_deadline<=clock_timestamp() then raise exception 'lucky_claim_expired';end if;
 if not exists(select 1 from public.yt_member_orders o where o.id=r.order_id and o.source='future_pos'
   and o.payment_status='paid' and o.status='fulfilled' and not o.cancel_after_refund and o.settlement_due_since is null)
 then raise exception 'lucky_order_not_eligible';end if;
 if r.pass_id is not null then
  v_pass:=r.pass_id;
  if not exists(select 1 from public.game_passes where id=v_pass and lucky_mode='lucky' and status in ('issued','expired')
   and customer_id is null) then raise exception 'lucky_pass_not_available';end if;
  update public.game_passes set customer_id=actor,status='used',claimed_at=clock_timestamp(),used_at=clock_timestamp(),
   selection='points' where id=v_pass;
 else
  select pass_id into v_pass from public.yt_pos_pass_bundle_items where bundle_id=r.bundle_id order by pass_id limit 1;
  if v_pass is null or exists(select 1 from public.yt_pos_pass_bundle_items x join public.game_passes p on p.id=x.pass_id
   where x.bundle_id=r.bundle_id and (p.customer_id is not null or p.lucky_mode<>'lucky' or p.status not in ('issued','expired')))
   then raise exception 'lucky_pass_not_available';end if;
  update public.game_passes p set customer_id=actor,status='used',claimed_at=clock_timestamp(),used_at=clock_timestamp(),selection='points'
   from public.yt_pos_pass_bundle_items x where x.bundle_id=r.bundle_id and x.pass_id=p.id;
  update public.yt_pos_pass_bundles set status='claimed',customer_id=actor,claimed_at=clock_timestamp() where id=r.bundle_id;
 end if;
 v_balance:=private.yt_points_sync(actor);
 select points_validity_days into v_days from public.yt_loyalty_config where id=true;
 v_exp:=case when v_days>0 then clock_timestamp()+make_interval(days=>v_days) else null end;
 insert into public.yt_point_entries(customer_id,game_pass_id,direction,points,reference,
  spend_amount_rm,max_budget_points,conversion_points_per_rm,remaining_points,expires_at,source)
 values(actor,v_pass,'earn',r.points,'LUCKY:'||r.id::text,r.box_amount_rm,r.points,100,r.points,v_exp,'lucky_box');
 update public.yt_point_wallets set balance=balance+r.points,lifetime_earned=lifetime_earned+r.points,
 updated_at=clock_timestamp() where customer_id=actor returning balance into v_balance;
 update public.yt_lucky_results set claimed_at=clock_timestamp(),customer_id=actor where id=r.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(actor,'lucky.claim','game_pass',v_pass,jsonb_build_object('lucky_id',r.id,'points',r.points,'bundle_id',r.bundle_id));
 return jsonb_build_object('ok',true,'idempotent',false,'points',r.points,'balance',v_balance,'expires_at',v_exp);
end $$;

-- Narrow public API: never expose the private tables or secret hashes.
create function public.yt_lucky_public_mode() returns jsonb language sql security invoker set search_path='' as $$
select private.yt_lucky_public_mode() $$;
create function public.yt_lucky_owner_settings() returns jsonb language sql security invoker set search_path='' as $$
select private.yt_lucky_owner_settings() $$;
create function public.yt_lucky_owner_save(p_settings jsonb) returns jsonb language sql security invoker set search_path='' as $$
select private.yt_lucky_owner_save(p_settings) $$;
create function public.yt_lucky_owner_reset() returns jsonb language sql security invoker set search_path='' as $$
select private.yt_lucky_owner_reset() $$;
create function public.yt_lucky_preview(p_token uuid,p_kind text) returns jsonb language sql security invoker set search_path='' as $$
select private.yt_lucky_preview(p_token,p_kind) $$;
create function public.yt_lucky_reveal(p_token uuid,p_kind text,p_secret uuid) returns jsonb language sql security invoker set search_path='' as $$
select private.yt_lucky_reveal(p_token,p_kind,p_secret) $$;
create function public.yt_lucky_claim(p_secret uuid) returns jsonb language sql security invoker set search_path='' as $$
select private.yt_lucky_claim(p_secret) $$;
revoke all on function public.yt_lucky_public_mode(),public.yt_lucky_owner_settings(),
 public.yt_lucky_owner_save(jsonb),public.yt_lucky_owner_reset(),
 public.yt_lucky_preview(uuid,text),public.yt_lucky_reveal(uuid,text,uuid),public.yt_lucky_claim(uuid)
 from public,anon,authenticated;
grant execute on function public.yt_lucky_public_mode(),public.yt_lucky_preview(uuid,text),
 public.yt_lucky_reveal(uuid,text,uuid) to anon,authenticated;
grant execute on function public.yt_lucky_owner_settings(),public.yt_lucky_owner_save(jsonb),
 public.yt_lucky_owner_reset(),public.yt_lucky_claim(uuid) to authenticated;
grant execute on function private.yt_lucky_public_mode(),private.yt_lucky_preview(uuid,text),
 private.yt_lucky_reveal(uuid,text,uuid) to anon,authenticated;
grant execute on function private.yt_lucky_owner_settings(),private.yt_lucky_owner_save(jsonb),
 private.yt_lucky_owner_reset(),private.yt_lucky_claim(uuid) to authenticated;
