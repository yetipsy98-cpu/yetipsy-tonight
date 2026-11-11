-- Production-only FreeFlow counts, separate from the paid-order sales ledger.
create function private.yt_owner_freeflow_report(p_start date,p_end date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not ((private.yt_has_role('owner') and private.yt_pos_work_staff()) or private.yt_owner_limited()) then raise exception 'owner_only';end if;
 if p_start is null or p_end is null or p_start>p_end or p_end-p_start>365 then raise exception 'invalid_report_range';end if;
 with served as materialized (
  select r.item_name,m.customer_id,m.guest_id,m.id member_id
  from public.yt_freeflow_sessions s join public.yt_freeflow_members m on m.session_id=s.id
  join public.yt_freeflow_requests r on r.member_id=m.id
  where s.business_day between p_start and p_end and r.status='served'
 ), leaders as (
  select customer_id,guest_id,min(member_id::text) label_id,count(*) cups
  from served group by customer_id,guest_id
  order by count(*) desc,coalesce(customer_id,guest_id) limit 5
 ), drinks as (
  select item_name name,count(*) cups from served group by item_name
 )
 select jsonb_build_object('cups',(select count(*) from served),
  'top5',coalesce((select jsonb_agg(jsonb_build_object('name',coalesce(nullif(btrim(p.display_name),''),
    case when l.guest_id is not null then '访客 '||upper(right(l.label_id,4)) else '会员 '||upper(right(l.customer_id::text,4)) end),'cups',l.cups)
    order by l.cups desc,coalesce(l.customer_id,l.guest_id)) from leaders l left join public.profiles p on p.id=l.customer_id),'[]'::jsonb),
  'drinks',coalesce((select jsonb_agg(jsonb_build_object('name',name,'cups',cups) order by cups desc,name) from drinks),'[]'::jsonb)) into result;
 return result;
end$$;
revoke all on function private.yt_owner_freeflow_report(date,date) from public,anon,authenticated;
grant execute on function private.yt_owner_freeflow_report(date,date) to authenticated;

-- Preserve the existing report/export authorization and all financial calculations.
create or replace function public.yt_owner_report_v8(p_start date,p_end date,p_member_page integer default 1,p_search text default '') returns jsonb
language sql security invoker set search_path='' as $$
 select private.yt_owner_report_v8(p_start,p_end,p_member_page,p_search)
  ||jsonb_build_object('freeflow',private.yt_owner_freeflow_report(p_start,p_end))
$$;
create or replace function public.yt_owner_financial_export(p_start date,p_end date) returns jsonb
language sql stable security invoker set search_path='' as $$
 select private.yt_owner_financial_export(p_start,p_end)
  ||jsonb_build_object('freeflow',private.yt_owner_freeflow_report(p_start,p_end))
$$;
