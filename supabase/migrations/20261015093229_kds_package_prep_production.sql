-- Expose only Cashier-selected Package production quantities to active KDS staff.
create or replace function private.yt_pos_kds_package_preps(p_orders uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $function$
declare result jsonb;
begin
 if auth.uid() is null or not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_orders is null or cardinality(p_orders)>80 then raise exception 'invalid_filter';end if;
 select coalesce(jsonb_object_agg(i.order_id::text,i.preps),'{}'::jsonb)
 into result
 from private.yt_store_box_prep_intents i
 join public.yt_member_orders o on o.id=i.order_id
 where i.order_id=any(p_orders)
  and o.source='future_pos'
  and o.status='confirmed'
  and o.payment_status in ('unpaid','paid')
  and exists(
   select 1 from public.yt_member_order_items oi
   join public.yt_store_box_product_rules r on r.product_id=oi.product_id and r.active
   where oi.order_id=o.id and oi.quantity>0
  );
 return result;
end
$function$;

revoke all on function private.yt_pos_kds_package_preps(uuid[]) from public,anon;
grant execute on function private.yt_pos_kds_package_preps(uuid[]) to authenticated;

create or replace function public.yt_pos_kds_package_preps(p_orders uuid[])
returns jsonb
language sql
security definer
set search_path=''
as $function$
 select private.yt_pos_kds_package_preps(p_orders)
$function$;

revoke all on function public.yt_pos_kds_package_preps(uuid[]) from public,anon;
grant execute on function public.yt_pos_kds_package_preps(uuid[]) to authenticated;
