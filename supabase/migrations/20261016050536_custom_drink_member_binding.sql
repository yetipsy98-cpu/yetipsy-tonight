-- Associate paid custom drinks with a member without creating a points binding.
create or replace function private.yt_pos_custom_bind_member(p_order uuid,p_token uuid)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
 v_order public.yt_member_orders%rowtype;
 v_customer uuid;
 v_count integer;
begin
 if not (private.yt_pos_work_cashier() or private.yt_work_owner()) then raise exception 'cashier_only'; end if;
 if p_order is null or p_token is null then raise exception 'custom_member_binding_invalid'; end if;
 select * into v_order from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found or v_order.status in ('cancelled','rejected') or v_order.payment_status<>'paid'
   or v_order.status='refunded' or coalesce(v_order.cancel_after_refund,false)
   or private.yt_pos_received(p_order)<v_order.amount_rm then
  raise exception 'custom_order_not_paid';
 end if;
 select t.customer_id into v_customer from public.yt_play_member_tokens t
 where t.token_hash=private.yt_play_hash(p_token) and t.expires_at>clock_timestamp();
 if v_customer is null then raise exception 'member_code_expired'; end if;
 if not exists(select 1 from public.pin_accounts where auth_user_id=v_customer)
   or exists(select 1 from public.work_accounts where auth_user_id=v_customer) then
  raise exception 'customer_only';
 end if;
 if not exists(
   select 1 from public.yt_member_order_items i
   join public.yt_pos_custom_drinks d on d.product_id=i.product_id
   where i.order_id=p_order and i.quantity>0
 ) then raise exception 'custom_order_no_custom_items'; end if;
 if exists(
   select 1 from public.yt_member_order_items i
   join public.yt_pos_custom_drinks d on d.product_id=i.product_id
   where i.order_id=p_order and i.quantity>0 and d.customer_id is not null and d.customer_id<>v_customer
 ) then raise exception 'custom_already_bound'; end if;
 select count(*) into v_count from public.yt_member_order_items i
 join public.yt_pos_custom_drinks d on d.product_id=i.product_id
 where i.order_id=p_order and i.quantity>0 and d.customer_id is null;
 update public.yt_pos_custom_drinks d set customer_id=v_customer
 from public.yt_member_order_items i
 where i.order_id=p_order and i.quantity>0 and i.product_id=d.product_id and d.customer_id is null;
 return jsonb_build_object('bound',true,'already_bound',v_count=0,'custom_drinks',v_count);
end;
$function$;

create or replace function public.yt_pos_custom_bind_member(p_order uuid,p_token uuid)
returns jsonb language sql set search_path=''
as $function$ select private.yt_pos_custom_bind_member(p_order,p_token); $function$;
revoke all on function public.yt_pos_custom_bind_member(uuid,uuid) from public,anon;
grant execute on function public.yt_pos_custom_bind_member(uuid,uuid) to authenticated;
revoke all on function private.yt_pos_custom_bind_member(uuid,uuid) from public,anon,authenticated;

-- Mark custom items in POS receipt data so the custom-only action is shown only when needed.
create or replace function private.yt_pos_orders(p_scope text default 'active',p_limit integer default 60)
returns jsonb language plpgsql stable security definer set search_path='' as $function$
declare v_result jsonb;
begin
 if not private.yt_pos_work_staff() and not private.yt_work_owner() then raise exception 'staff_only'; end if;
 if p_scope not in ('active','pending','paid','all','mine') or p_limit is null or p_limit<1 or p_limit>150 then raise exception 'invalid_filter'; end if;
 if p_scope='pending' and not private.yt_pos_work_cashier() and not private.yt_work_owner() then raise exception 'cashier_only'; end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc),'[]'::jsonb) into v_result from (
  select x.id,x.order_no,x.table_label,x.notes,x.status,x.payment_status,x.checkout_mode,x.amount_rm,x.revision,x.settlement_due_since,
   private.yt_pos_received(x.id) received_rm,
   case when x.payment_status in ('paid','refunded') then x.amount_rm-private.yt_pos_received(x.id) else x.amount_rm end balance_rm,
   x.created_at,x.updated_at,x.created_by,wa.username created_by_name,x.accepted_at,x.fulfilled_at,x.paid_at,x.payment_method,
   coalesce((select e.source from public.yt_pos_order_events e where e.order_id=x.id and e.event_type='created' order by e.created_at limit 1),'staff') created_channel,
   exists(select 1 from public.yt_pos_order_chits chit where chit.order_id=x.id and chit.status='queued') has_chit,
   private.yt_store_box_order_only(x.id) store_box_only,
   case when b.order_id is not null then jsonb_build_object('source',b.source,
    'member_binding',b.source in ('pos_qr','member_qr'),
    'can_unbind',b.source in ('pos_qr','member_qr') and x.payment_status='unpaid' and x.status not in ('cancelled','rejected'))
    when x.customer_id is not null then jsonb_build_object('source','customer_order','member_binding',false,'can_unbind',false)
    else null end member_binding,
   coalesce((select jsonb_agg(jsonb_build_object(
    'id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'price_rm',i.unit_price_rm,
    'fulfilled',i.fulfilled,
    'custom_drink',cd.id is not null,
    'custom_bound',cd.customer_id is not null,
    'store_box_item',exists(select 1 from public.yt_store_box_product_rules sr where sr.product_id=i.product_id and sr.active)
   ) order by i.item_name) from public.yt_member_order_items i
   left join public.yt_pos_custom_drinks cd on cd.product_id=i.product_id
   where i.order_id=x.id and i.quantity>0),'[]'::jsonb) items
  from public.yt_member_orders x left join public.work_accounts wa on wa.auth_user_id=x.created_by
  left join public.yt_play_consumption_bindings b on b.order_id=x.id
  where x.source='future_pos' and (
   (p_scope='active' and ((x.status in ('pending','confirmed') and x.payment_status in ('unpaid','paid')) or (x.status='fulfilled' and x.payment_status='unpaid')))
   or (p_scope='pending' and x.status='pending') or (p_scope='paid' and x.payment_status in ('paid','refunded'))
   or p_scope='all' or (p_scope='mine' and x.created_by=auth.uid())
  ) order by x.created_at desc limit p_limit
 ) o;
 return v_result;
end;
$function$;

create or replace function private.yt_pos_orders_day(p_scope text default 'active',p_day date default null,p_limit integer default 60)
returns jsonb language plpgsql stable security definer set search_path='' as $function$
declare v_result jsonb;
begin
 if not private.yt_pos_work_staff() and not private.yt_work_owner() then raise exception 'staff_only'; end if;
 if p_scope not in ('active','pending','paid','all','mine') or p_limit is null or p_limit<1 or p_limit>150 then raise exception 'invalid_filter'; end if;
 if p_scope='pending' and not private.yt_pos_work_cashier() and not private.yt_work_owner() then raise exception 'cashier_only'; end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc),'[]'::jsonb) into v_result from (
  select x.id,x.order_no,x.table_label,x.notes,x.status,x.payment_status,x.checkout_mode,x.amount_rm,x.revision,x.settlement_due_since,
   private.yt_pos_received(x.id) received_rm,
   case when x.payment_status in ('paid','refunded') then x.amount_rm-private.yt_pos_received(x.id) else x.amount_rm end balance_rm,
   x.created_at,x.updated_at,x.created_by,wa.username created_by_name,x.accepted_at,x.fulfilled_at,x.paid_at,x.payment_method,
   coalesce((select e.source from public.yt_pos_order_events e where e.order_id=x.id and e.event_type='created' order by e.created_at limit 1),'staff') created_channel,
   exists(select 1 from public.yt_pos_order_chits chit where chit.order_id=x.id and chit.status='queued') has_chit,
   private.yt_store_box_order_only(x.id) store_box_only,
   coalesce((select jsonb_agg(jsonb_build_object(
    'id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'price_rm',i.unit_price_rm,
    'fulfilled',i.fulfilled,
    'custom_drink',cd.id is not null,
    'custom_bound',cd.customer_id is not null,
    'store_box_item',exists(select 1 from public.yt_store_box_product_rules sr where sr.product_id=i.product_id and sr.active)
   ) order by i.item_name) from public.yt_member_order_items i
   left join public.yt_pos_custom_drinks cd on cd.product_id=i.product_id
   where i.order_id=x.id and i.quantity>0),'[]'::jsonb) items
  from public.yt_member_orders x left join public.work_accounts wa on wa.auth_user_id=x.created_by
  where x.source='future_pos' and (
   (p_scope='active' and ((x.status in ('pending','confirmed') and x.payment_status in ('unpaid','paid')) or (x.status='fulfilled' and x.payment_status='unpaid')))
   or (p_scope='pending' and x.status='pending')
   or (p_scope='paid' and x.payment_status in ('paid','refunded')
    and x.paid_at>=private.yt_business_start(coalesce(p_day,private.yt_business_day(now())))
    and x.paid_at<private.yt_business_start(coalesce(p_day,private.yt_business_day(now()))+1))
   or p_scope='all' or (p_scope='mine' and x.created_by=auth.uid())
  ) order by case when p_scope='paid' then x.paid_at else x.created_at end desc limit p_limit
 ) o;
 return v_result;
end;
$function$;
