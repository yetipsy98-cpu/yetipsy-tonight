create or replace function private.yt_ambassador_work_portal()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.yt_ambassadors%rowtype; d date:=private.yt_business_day(now()); p jsonb; prices jsonb; wallet numeric;
begin
 perform private.yt_ambassador_assert_work();
 select * into a from public.yt_ambassadors where work_user_id=auth.uid() and active limit 1;
 if a.id is null then raise exception 'ambassador_work_only'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'pass_code',x.pass_code,'reservation_day',x.reservation_day,'pass_type',x.pass_type,'planned_pax',x.planned_pax,'guest_name',x.guest_name,'guest_phone',x.guest_phone,'remark',x.remark,'status',x.status,'created_at',x.created_at,'checked_pax',coalesce(c.checked_pax,0),'sales',coalesce(c.sales,0),'commission',coalesce(c.commission,0)) order by x.reservation_day desc,x.created_at desc),'[]'::jsonb)
 into p from public.yt_ambassador_passes x
 left join lateral (select sum(ci.male_count+ci.female_count)::integer checked_pax,sum(ci.sales)::numeric sales,sum(ci.commission_amount)::numeric commission from public.yt_ambassador_checkins ci where ci.pass_id=x.id) c on true
 where x.ambassador_id=a.id;
 select coalesce(sum(l.amount),0) into wallet from public.yt_ambassador_ledger l where l.ambassador_id=a.id;
 select jsonb_build_object('weekday_male',weekday_male,'weekday_female',weekday_female,'weekend_male',weekend_male,'weekend_female',weekend_female,'specials',coalesce((select jsonb_agg(jsonb_build_object('business_day',s.business_day,'male',s.male_price,'female',s.female_price) order by s.business_day desc) from public.yt_ambassador_special_prices s),'[]'::jsonb)) into prices from public.yt_ambassador_prices where id=true;
 return jsonb_build_object('enabled',true,'ambassador',jsonb_build_object('id',a.id,'display_name',a.display_name,'commission_rate',a.commission_rate),'business_day',d,'prices',prices,'wallet_balance',wallet,'passes',p);
end $$;
create or replace function private.yt_ambassador_pass_save(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.yt_ambassadors%rowtype; v public.yt_ambassador_passes%rowtype; pid uuid; d date; cnt integer;
begin
 if auth.uid() is null then raise exception 'not_authenticated'; end if;
 select * into a from public.yt_ambassadors where work_user_id=auth.uid() and active limit 1;
 if a.id is not null then perform private.yt_ambassador_assert_work();
 else select * into a from public.yt_ambassadors where member_user_id=auth.uid() and active limit 1; if a.id is null then raise exception 'ambassador_member_only'; end if; end if;
 begin pid:=nullif(p_payload->>'id','')::uuid; exception when others then raise exception 'invalid_pass'; end;
 begin d:=nullif(p_payload->>'reservation_day','')::date; exception when others then raise exception 'invalid_reservation_day'; end;
 if d is null or d<private.yt_business_day(now()) or d>private.yt_business_day(now())+180 then raise exception 'invalid_reservation_day'; end if;
 if coalesce((p_payload->>'planned_pax')::integer,0) not between 1 and 500 then raise exception 'invalid_planned_pax'; end if;
 if coalesce(p_payload->>'pass_type','group') not in ('group','individual') then raise exception 'invalid_pass_type'; end if;
 if length(coalesce(p_payload->>'guest_name',''))>100 or length(coalesce(p_payload->>'guest_phone',''))>40 or length(coalesce(p_payload->>'remark',''))>500 then raise exception 'invalid_pass'; end if;
 if pid is null then
  insert into public.yt_ambassador_passes(ambassador_id,reservation_day,pass_type,planned_pax,guest_name,guest_phone,remark) values(a.id,d,coalesce(p_payload->>'pass_type','group'),(p_payload->>'planned_pax')::integer,coalesce(p_payload->>'guest_name',''),coalesce(p_payload->>'guest_phone',''),coalesce(p_payload->>'remark','')) returning * into v;
 else
  select * into v from public.yt_ambassador_passes where id=pid and ambassador_id=a.id and status='issued' for update;
  if v.id is null then raise exception 'pass_not_editable'; end if;
  select count(*) into cnt from public.yt_ambassador_checkins where pass_id=v.id;if cnt>0 then raise exception 'pass_already_checked_in'; end if;
  update public.yt_ambassador_passes set reservation_day=d,pass_type=coalesce(p_payload->>'pass_type','group'),planned_pax=(p_payload->>'planned_pax')::integer,guest_name=coalesce(p_payload->>'guest_name',''),guest_phone=coalesce(p_payload->>'guest_phone',''),remark=coalesce(p_payload->>'remark',''),updated_at=now() where id=v.id returning * into v;
 end if;
 return jsonb_build_object('id',v.id,'pass_code',v.pass_code,'reservation_day',v.reservation_day,'planned_pax',v.planned_pax,'pass_type',v.pass_type,'guest_name',v.guest_name);
end $$;
create or replace function private.yt_ambassador_owner_delete(p_ambassador_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare has_history boolean;
begin
 perform private.yt_ambassador_assert_owner();if p_ambassador_id is null then raise exception 'ambassador_not_found';end if;
 perform 1 from public.yt_ambassadors where id=p_ambassador_id for update;if not found then raise exception 'ambassador_not_found';end if;
 select exists(select 1 from public.yt_ambassador_checkins where ambassador_id=p_ambassador_id) or exists(select 1 from public.yt_ambassador_ledger where ambassador_id=p_ambassador_id) into has_history;
 if has_history then update public.yt_ambassadors set active=false,member_user_id=null,work_user_id=null,updated_at=now() where id=p_ambassador_id;return jsonb_build_object('deleted',false,'history_preserved',true);end if;
 delete from public.yt_ambassador_passes where ambassador_id=p_ambassador_id;delete from public.yt_ambassadors where id=p_ambassador_id;return jsonb_build_object('deleted',true,'history_preserved',false);
end $$;
grant execute on function private.yt_ambassador_work_portal() to authenticated;
grant execute on function private.yt_ambassador_owner_delete(uuid) to authenticated;
revoke all on function private.yt_ambassador_work_portal() from public,anon;
revoke all on function private.yt_ambassador_owner_delete(uuid) from public,anon;
create or replace function public.yt_ambassador_work_portal() returns jsonb language sql set search_path='' as $$ select private.yt_ambassador_work_portal() $$;
create or replace function public.yt_ambassador_owner_delete(p_ambassador_id uuid) returns jsonb language sql set search_path='' as $$ select private.yt_ambassador_owner_delete(p_ambassador_id) $$;
revoke all on function public.yt_ambassador_work_portal() from public,anon;
revoke all on function public.yt_ambassador_owner_delete(uuid) from public,anon;
grant execute on function public.yt_ambassador_work_portal() to authenticated;
grant execute on function public.yt_ambassador_owner_delete(uuid) to authenticated;
