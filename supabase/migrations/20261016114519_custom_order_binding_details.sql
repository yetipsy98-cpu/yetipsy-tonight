create or replace function private.yt_pos_custom_order_bindings(p_order uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
 if not (private.yt_work_owner() or private.yt_pos_work_cashier()) then raise exception 'cashier_only';end if;
 if p_order is null or not exists(select 1 from public.yt_member_orders where id=p_order and source='future_pos' and payment_status='paid') then
  raise exception 'custom_order_not_paid';
 end if;
 return coalesce((
  select jsonb_agg(jsonb_build_object(
   'custom_drink_id',d.id,
   'name',d.public_name,
   'order_member',(
    select jsonb_build_object(
     'name',coalesce(nullif(btrim(p.display_name),''),'会员'),
     'created_at',m.created_at,
     'order_no',o.order_no
    )
    from private.yt_pos_custom_order_members m
    left join public.profiles p on p.id=m.customer_id
    left join public.yt_member_orders o on o.id=m.order_id
    where m.order_id=p_order
   ),
   'members',coalesce((
    select jsonb_agg(jsonb_build_object(
     'name',coalesce(nullif(btrim(p.display_name),''),'会员'),
     'created_at',m.created_at,
     'first_order_no',first_order.order_no
    ) order by m.created_at,m.customer_id)
    from public.yt_pos_custom_drink_members m
    left join public.profiles p on p.id=m.customer_id
    left join public.yt_member_orders first_order on first_order.id=m.first_order_id
    where m.custom_drink_id=d.id
   ),'[]'::jsonb)
  ) order by d.public_name)
  from (
   select distinct cd.id,cd.public_name
   from public.yt_member_order_items i
   join public.yt_pos_custom_drinks cd on cd.product_id=i.product_id
   where i.order_id=p_order and i.quantity>0
  ) d
 ),'[]'::jsonb);
end;
$function$;
