
create or replace function private.yt_ambassador_checkin(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_ambassador_passes%rowtype; a public.yt_ambassadors%rowtype; ci public.yt_ambassador_checkins%rowtype;
 d date:=private.yt_business_day(now()); req uuid; m integer; f integer; p jsonb; mp numeric; fp numeric; s numeric; comm numeric; done integer;
begin
 perform private.yt_ambassador_assert_work();
 begin req:=nullif(p_payload->>'request_id','')::uuid; exception when others then raise exception 'invalid_request_id'; end;
 begin v.id:=nullif(p_payload->>'pass_id','')::uuid; exception when others then raise exception 'invalid_pass'; end;
 begin m:=coalesce((p_payload->>'male_count')::integer,0); f:=coalesce((p_payload->>'female_count')::integer,0); exception when others then raise exception 'invalid_guest_count'; end;
 if req is null or v.id is null or m<0 or f<0 or m+f<1 or m+f>500 then raise exception 'invalid_guest_count'; end if;
 select * into ci from public.yt_ambassador_checkins where request_id=req;
 if ci.id is not null then return jsonb_build_object('id',ci.id,'sales',ci.sales,'commission',ci.commission_amount,'duplicate',true); end if;
 select * into v from public.yt_ambassador_passes where id=v.id and status='issued' for update;
 if v.id is null then raise exception 'ambassador_pass_not_found'; end if;
 select * into a from public.yt_ambassadors where id=v.ambassador_id and active;
 if a.id is null then raise exception 'ambassador_inactive'; end if;
 if a.member_user_id=auth.uid() or a.work_user_id=auth.uid() then raise exception 'cannot_redeem_own_pass'; end if;
 if d<>v.reservation_day or now()<private.yt_business_start(v.reservation_day) or now()>=private.yt_business_start(v.reservation_day+1) then raise exception 'ambassador_pass_not_valid_today'; end if;
 p:=private.yt_ambassador_price(v.reservation_day); mp:=(p->>'male')::numeric; fp:=(p->>'female')::numeric;
 if mp<=0 or fp<=0 then raise exception 'ambassador_prices_not_configured'; end if;
 s:=round(m*mp+f*fp,2); comm:=round(s*a.commission_rate/100,2);
 insert into public.yt_ambassador_checkins(request_id,pass_id,ambassador_id,checked_by,business_day,male_count,female_count,male_price,female_price,sales,commission_rate,commission_amount,note)
 values(req,v.id,a.id,auth.uid(),d,m,f,mp,fp,s,a.commission_rate,comm,left(coalesce(p_payload->>'note',''),300))
 on conflict(request_id) do nothing returning * into ci;
 if ci.id is null then select * into ci from public.yt_ambassador_checkins where request_id=req; return jsonb_build_object('id',ci.id,'sales',ci.sales,'commission',ci.commission_amount,'duplicate',true); end if;
 if comm>0 then
  insert into public.yt_ambassador_ledger(ambassador_id,checkin_id,entry_type,amount,created_by,business_day,note)
  values(a.id,ci.id,'commission',comm,auth.uid(),d,'Pass 核销佣金');
 end if;
 select coalesce(sum(male_count+female_count),0) into done from public.yt_ambassador_checkins where pass_id=v.id;
 return jsonb_build_object('id',ci.id,'sales',s,'commission',comm,'commission_rate',a.commission_rate,
  'checked_pax',done,'planned_pax',v.planned_pax,'over_planned',done>v.planned_pax,'duplicate',false);
end $$;

create or replace function private.yt_ambassador_owner_save(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare aid uuid; mem uuid; workid uuid; rate numeric; name text; v_phone text; active_flag boolean; result public.yt_ambassadors%rowtype;
begin
 perform private.yt_ambassador_assert_owner();
 begin aid:=nullif(p_payload->>'id','')::uuid; mem:=nullif(p_payload->>'member_user_id','')::uuid; workid:=nullif(p_payload->>'work_user_id','')::uuid;
  rate:=coalesce((p_payload->>'commission_rate')::numeric,0); exception when others then raise exception 'invalid_ambassador'; end;
 name:=left(trim(coalesce(p_payload->>'display_name','')),100); v_phone:=left(trim(coalesce(p_payload->>'phone','')),40); active_flag:=coalesce((p_payload->>'active')::boolean,true);
 if mem is null and workid is null then raise exception 'ambassador_identity_required'; end if;
 if mem is not null and not exists(select 1 from public.profiles where id=mem) then raise exception 'ambassador_member_not_found'; end if;
 if workid is not null and not exists(select 1 from public.work_accounts wa join public.staff_roles sr on sr.user_id=wa.auth_user_id and sr.active and sr.role=wa.role
  where wa.auth_user_id=workid and wa.active and not wa.must_change_password and wa.role in ('staff','cashier')) then raise exception 'ambassador_work_user_not_found'; end if;
 if rate<0 or rate>100 then raise exception 'invalid_commission_rate'; end if;
 if aid is null then
  insert into public.yt_ambassadors(member_user_id,work_user_id,display_name,phone,commission_rate,active,created_by)
   values(mem,workid,name,v_phone,rate,active_flag,auth.uid()) returning * into result;
 else
  update public.yt_ambassadors set member_user_id=mem,work_user_id=workid,display_name=name,phone=v_phone,
   commission_rate=rate,active=active_flag,updated_at=now() where id=aid returning * into result;
  if result.id is null then raise exception 'ambassador_not_found'; end if;
 end if;
 return jsonb_build_object('id',result.id);
end $$;

revoke all on function private.yt_ambassador_price(date) from public,anon,authenticated;
revoke all on function private.yt_ambassador_assert_owner() from public,anon,authenticated;
revoke all on function private.yt_ambassador_assert_work() from public,anon,authenticated;
