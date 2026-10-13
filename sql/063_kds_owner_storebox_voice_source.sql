-- Expose request origin so Cashier KDS can announce Owner and customer calls,
-- while keeping checkout-generated first-pour prep tickets silent.
CREATE OR REPLACE FUNCTION private.yt_store_box_queue()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_box_requests set status='expired' where status='pending' and expires_at<=clock_timestamp();
 select coalesce(jsonb_agg(to_jsonb(x) order by x.requested_at),'[]'::jsonb) into rows from(
  select r.id request_id,r.status,r.quantity,r.component_key,r.component_name,r.selections,
   r.customer_id request_customer_id,case when r.customer_id is not null then 'customer' else coalesce((select e.metadata->>'source' from public.yt_store_box_events e where e.request_id=r.id and e.event_type='drink_requested' order by e.created_at desc limit 1),'staff') end request_source,r.table_label,r.requested_at,r.expires_at,r.accepted_by,
   wa.username accepted_by_name,b.id box_id,b.name,b.mode,b.unit_label,b.total_units,b.served_units,
   b.components,b.selection_mode,b.total_units-b.served_units remaining_units,
   b.customer_id,p.phone customer_phone,coalesce(pr.display_name,p.phone) customer_name,o.order_no
  from public.yt_store_box_requests r join public.yt_store_boxes b on b.id=r.box_id
  join public.yt_member_orders o on o.id=b.source_order_id
  left join public.pin_accounts p on p.auth_user_id=b.customer_id
  left join public.profiles pr on pr.id=b.customer_id
  left join public.work_accounts wa on wa.auth_user_id=r.accepted_by
  where r.status in ('pending','accepted','preparing')
 )x;
 return rows;
end $function$;
