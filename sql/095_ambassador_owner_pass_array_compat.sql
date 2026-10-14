-- Owner sees all issued Passes scheduled within the current business day ±3 days.
-- Every issuer is included; cancellation is separately guarded against existing sales/check-ins.
create or replace function private.yt_ambassador_owner_passes()
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
 d date:=private.yt_business_day(now());
 rows jsonb;
begin
 perform private.yt_ambassador_assert_owner();
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',x.id,
  'pass_code',x.pass_code,
  'reservation_day',x.reservation_day,
  'pass_type',x.pass_type,
  'planned_pax',x.planned_pax,
  'guest_name',x.guest_name,
  'guest_phone',x.guest_phone,
  'status',x.status,
  'created_at',x.created_at,
  'ambassador_name',coalesce(nullif(a.display_name,''),''),
  'issued_by_name',coalesce(nullif(p.display_name,''),wa.username,case when x.ambassador_id is null then 'POS' else 'Ambassador' end),
  'checked_pax',coalesce(c.checked_pax,0),
  'has_orders',(exists(select 1 from public.yt_ambassador_checkins ci where ci.pass_id=x.id)
    or exists(select 1 from public.yt_ambassador_pos_sales ps where ps.pass_id=x.id))
 ) order by x.reservation_day,x.created_at desc),'[]'::jsonb)
 into rows
 from public.yt_ambassador_passes x
 left join public.yt_ambassadors a on a.id=x.ambassador_id
 left join public.profiles p on p.id=x.issued_by
 left join public.work_accounts wa on wa.auth_user_id=x.issued_by
 left join lateral(
  select sum(ci.male_count+ci.female_count)::integer checked_pax
  from public.yt_ambassador_checkins ci where ci.pass_id=x.id
 ) c on true
 where x.status='issued' and x.reservation_day between d-3 and d+3;
 return rows;
end $$;
