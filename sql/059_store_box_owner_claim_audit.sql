-- V16.10 Owner workbench: show the staff issuer for claimed boxes and keep
-- claimed boxes visible in the customer history.
create or replace function private.yt_my_store_boxes() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;actor uuid:=auth.uid();
begin
 if not private.yt_store_box_customer() then raise exception 'customer_only';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.storage_expires_at,x.created_at desc),'[]'::jsonb) into rows from(
  select b.id,b.name,b.mode,b.unit_label,b.total_units,b.served_units,b.components,b.selection_mode,
   b.total_units-b.served_units remaining_units,b.request_limit,b.table_label,
   case when b.storage_expires_at<=clock_timestamp() and b.status not in ('completed','cancelled') then 'expired' else b.status end status,
   b.claimed_at,b.storage_expires_at,b.created_at,
   r.id active_request_id,r.quantity active_request_quantity,r.component_key active_request_component_key,
   r.component_name active_request_component_name,r.selections active_request_selections,r.status active_request_status,r.requested_at
  from public.yt_store_boxes b left join public.yt_store_box_requests r on r.box_id=b.id and r.status in ('pending','accepted','preparing')
  where b.customer_id=actor
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_staff_boxes() returns jsonb language plpgsql security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_boxes set status='expired',updated_at=clock_timestamp()
  where storage_expires_at<=clock_timestamp() and status in ('active','paused','exhausted');
 select coalesce(jsonb_agg(to_jsonb(x) order by x.storage_expires_at desc,x.updated_at desc),'[]'::jsonb) into rows from(
  select b.id,b.name,b.mode,b.status,b.unit_label,b.total_units,b.served_units,b.components,b.selection_mode,
   b.total_units-b.served_units remaining_units,b.request_limit,b.table_label,b.customer_id,
   coalesce(pr.display_name,p.phone) customer_name,p.phone customer_phone,b.claimed_at,b.storage_expires_at,b.updated_at,
   r.id active_request_id,r.status active_request_status,r.quantity active_request_quantity,r.component_name active_request_component_name,wa.username claimed_qr_issued_by_name
  from public.yt_store_boxes b left join public.pin_accounts p on p.auth_user_id=b.customer_id
  left join public.profiles pr on pr.id=b.customer_id
  left join public.yt_store_box_requests r on r.box_id=b.id and r.status in ('pending','accepted','preparing')
  left join lateral(select c.issued_by from public.yt_store_box_claims c where c.box_id=b.id and c.status='claimed' order by c.claimed_at desc,c.created_at desc limit 1) cq on true
  left join public.work_accounts wa on wa.auth_user_id=cq.issued_by
  where b.customer_id is not null and b.status in ('active','paused','exhausted','completed','expired','cancelled')
  order by b.storage_expires_at desc,b.updated_at desc limit 200
 )x;
 return rows;
end $$;

