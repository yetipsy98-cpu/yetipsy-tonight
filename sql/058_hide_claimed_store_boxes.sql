-- V16.10 Hide claimed Store Boxes from the customer list, matching Game Pass.
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
  where b.customer_id=actor and b.claimed_at is null
 )x;
 return rows;
end $$;
