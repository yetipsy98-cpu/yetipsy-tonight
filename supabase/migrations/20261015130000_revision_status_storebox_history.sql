-- Persist Cashier revision status and expose dated Store Box audit history.
create or replace function private.yt_pos_owner_revision_requests_mine()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_pos_work_cashier() or private.yt_work_owner() then raise exception 'cashier_only';end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',q.id,'order_id',q.order_id,'order_no',o.order_no,'table_label',o.table_label,
  'status',q.status,'created_at',q.created_at,'reviewed_at',q.reviewed_at,
  'review_note',q.review_note,'reviewer_name',coalesce(r.username,'Owner')
 ) order by q.created_at desc),'[]'::jsonb)
 into rows from (
  select * from public.yt_pos_owner_revision_requests
  where requester_id=auth.uid()
  order by created_at desc limit 100
 ) q
 join public.yt_member_orders o on o.id=q.order_id
 left join public.work_accounts r on r.auth_user_id=q.reviewer_id;
 return rows;
end $$;
create or replace function public.yt_pos_owner_revision_requests_mine()
returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_pos_owner_revision_requests_mine()
$$;

create or replace function private.yt_store_box_staff_history(p_day date default null,p_limit integer default 100)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare d date:=coalesce(p_day,private.yt_business_day(clock_timestamp()));start_at timestamptz;end_at timestamptz;rows jsonb;can_view boolean:=private.yt_store_box_can_view_claim_identity();
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_limit is null or p_limit not between 1 and 150 then raise exception 'invalid_filter';end if;
 start_at:=private.yt_business_start(d);end_at:=private.yt_business_start(d+1);
 select coalesce(jsonb_agg(to_jsonb(x) order by x.event_at desc),'[]'::jsonb) into rows from (
  select e.id,e.event_type,e.quantity,e.completed_delta,e.note,e.metadata,e.created_at event_at,
   b.id box_id,b.name,b.unit_label,b.status box_status,b.total_units,b.served_units,
   b.total_units-b.served_units remaining_units,b.table_label,o.order_no,
   case when can_view then wa.username else null end actor_name
  from public.yt_store_box_events e
  join public.yt_store_boxes b on b.id=e.box_id
  left join public.yt_member_orders o on o.id=b.source_order_id
  left join public.work_accounts wa on wa.auth_user_id=e.actor_id
  where e.created_at>=start_at and e.created_at<end_at
  order by e.created_at desc limit p_limit
 ) x;
 return jsonb_build_object('day',d,'events',rows);
end $$;
create or replace function public.yt_store_box_staff_history(p_day date default null,p_limit integer default 100)
returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_store_box_staff_history(p_day,p_limit)
$$;

revoke all on function private.yt_pos_owner_revision_requests_mine(),private.yt_store_box_staff_history(date,integer) from public,anon,authenticated;
revoke all on function public.yt_pos_owner_revision_requests_mine(),public.yt_store_box_staff_history(date,integer) from public,anon;
grant execute on function private.yt_pos_owner_revision_requests_mine(),private.yt_store_box_staff_history(date,integer) to authenticated;
grant execute on function public.yt_pos_owner_revision_requests_mine(),public.yt_store_box_staff_history(date,integer) to authenticated;
