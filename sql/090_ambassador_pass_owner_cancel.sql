-- Owner-managed cancellation for issued Ambassador Passes.
-- Owners can cancel an unused Pass. Passes tied to any POS sale/order are locked
-- so an unpaid cart cannot later settle against a cancelled Pass.

create or replace function private.yt_ambassador_owner_passes()
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare result jsonb;
begin
 perform private.yt_ambassador_assert_owner();
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',x.id,'pass_code',x.pass_code,'reservation_day',x.reservation_day,'pass_type',x.pass_type,
  'planned_pax',x.planned_pax,'guest_name',x.guest_name,'guest_phone',x.guest_phone,
  'status',x.status,'created_at',x.created_at,'ambassador_name',coalesce(nullif(a.display_name,''),''),
  'issued_by_name',coalesce(nullif(p.display_name,''),wa.username,case when x.ambassador_id is null then 'POS' else 'Ambassador' end),
  'checked_pax',coalesce(c.checked_pax,0)
 ) order by x.created_at desc),'[]'::jsonb)
 into result
 from (
  select * from public.yt_ambassador_passes
  where status='issued'
  order by created_at desc
  limit 200
 ) x
 left join public.yt_ambassadors a on a.id=x.ambassador_id
 left join public.profiles p on p.id=x.issued_by
 left join public.work_accounts wa on wa.auth_user_id=x.issued_by
 left join lateral(
  select sum(ci.male_count+ci.female_count)::integer checked_pax
  from public.yt_ambassador_checkins ci where ci.pass_id=x.id
 ) c on true;
 return result;
end $$;

create or replace function private.yt_ambassador_owner_cancel_pass(p_pass_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare v public.yt_ambassador_passes%rowtype;
begin
 perform private.yt_ambassador_assert_owner();
 select * into v from public.yt_ambassador_passes where id=p_pass_id for update;
 if v.id is null then raise exception 'ambassador_pass_not_found';end if;
 if v.status<>'issued' then raise exception 'pass_not_cancellable';end if;
 if exists(select 1 from public.yt_ambassador_checkins c where c.pass_id=v.id)
  or exists(select 1 from public.yt_ambassador_pos_sales s where s.pass_id=v.id) then
  raise exception 'pass_has_orders';
 end if;
 update public.yt_ambassador_passes set status='void',updated_at=now() where id=v.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(auth.uid(),'ambassador.pass_cancelled','ambassador_pass',v.id,
  jsonb_build_object('pass_code',v.pass_code,'reservation_day',v.reservation_day,'issued_by',v.issued_by));
 return jsonb_build_object('id',v.id,'status','void');
end $$;

create or replace function public.yt_ambassador_owner_passes()
returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_ambassador_owner_passes()
$$;
create or replace function public.yt_ambassador_owner_cancel_pass(p_pass_id uuid)
returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_ambassador_owner_cancel_pass(p_pass_id)
$$;

revoke all on function private.yt_ambassador_owner_passes(),
 private.yt_ambassador_owner_cancel_pass(uuid) from public,anon,authenticated;
grant execute on function private.yt_ambassador_owner_passes(),
 private.yt_ambassador_owner_cancel_pass(uuid) to authenticated;
revoke all on function public.yt_ambassador_owner_passes(),
 public.yt_ambassador_owner_cancel_pass(uuid) from public,anon;
grant execute on function public.yt_ambassador_owner_passes(),
 public.yt_ambassador_owner_cancel_pass(uuid) to authenticated;
