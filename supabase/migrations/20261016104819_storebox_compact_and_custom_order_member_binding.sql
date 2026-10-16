-- Store Box balance compaction is client-side. This migration aligns the Owner service RPC
-- and enforces one member per paid custom-drink order while keeping shared recipe memberships.
create table if not exists private.yt_pos_custom_order_members (
  order_id uuid primary key references public.yt_member_orders(id) on delete cascade,
  customer_id uuid not null references auth.users(id) on delete cascade,
  bound_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists yt_pos_custom_order_members_customer_created_idx
  on private.yt_pos_custom_order_members(customer_id, created_at desc);
alter table private.yt_pos_custom_order_members enable row level security;
revoke all on private.yt_pos_custom_order_members from public, anon, authenticated, service_role;

-- Preserve a single historical member for each order, preferring the member explicitly
-- attached to the order, then the play binding, then the original custom recipe binding.
with candidates as (
  select o.id order_id, o.customer_id, 1 priority
  from public.yt_member_orders o
  where o.source='future_pos' and o.customer_id is not null
    and exists(select 1 from public.yt_member_order_items i join public.yt_pos_custom_drinks d on d.product_id=i.product_id where i.order_id=o.id and i.quantity>0)
  union all
  select b.order_id,b.customer_id,2
  from public.yt_play_consumption_bindings b
  join public.yt_member_orders o on o.id=b.order_id and o.source='future_pos'
  where exists(select 1 from public.yt_member_order_items i join public.yt_pos_custom_drinks d on d.product_id=i.product_id where i.order_id=o.id and i.quantity>0)
  union all
  select m.first_order_id,m.customer_id,3
  from public.yt_pos_custom_drink_members m
  join public.yt_member_orders o on o.id=m.first_order_id and o.source='future_pos'
  where m.first_order_id is not null
)
insert into private.yt_pos_custom_order_members(order_id,customer_id)
select distinct on(order_id) order_id,customer_id from candidates
order by order_id,priority
on conflict(order_id) do nothing;

CREATE OR REPLACE FUNCTION private.yt_pos_custom_bind_member(p_order uuid, p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order public.yt_member_orders%rowtype; v_customer uuid; v_existing_customer uuid; v_source_customer uuid; v_count integer; v_already_bound boolean:=false;
begin
 if not (private.yt_pos_work_cashier() or private.yt_work_owner()) then raise exception 'cashier_only'; end if;
 if p_order is null or p_token is null then raise exception 'custom_member_binding_invalid'; end if;
 select * into v_order from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found or v_order.status in ('cancelled','rejected') or v_order.payment_status<>'paid' or v_order.status='refunded'
   or coalesce(v_order.cancel_after_refund,false) or private.yt_pos_received(p_order)<v_order.amount_rm then
  raise exception 'custom_order_not_paid';
 end if;
 select t.customer_id into v_customer from public.yt_play_member_tokens t
 where t.token_hash=private.yt_play_hash(p_token) and t.expires_at>clock_timestamp();
 if v_customer is null then raise exception 'member_code_expired'; end if;
 if not exists(select 1 from public.pin_accounts where auth_user_id=v_customer)
   or exists(select 1 from public.work_accounts where auth_user_id=v_customer) then raise exception 'customer_only'; end if;
 if not exists(select 1 from public.yt_member_order_items i join public.yt_pos_custom_drinks d on d.product_id=i.product_id where i.order_id=p_order and i.quantity>0) then
  raise exception 'custom_order_no_custom_items';
 end if;
 if v_order.customer_id is not null and v_order.customer_id<>v_customer then raise exception 'custom_order_already_bound'; end if;
 select b.customer_id into v_source_customer from public.yt_play_consumption_bindings b where b.order_id=p_order;
 if v_source_customer is not null and v_source_customer<>v_customer then raise exception 'custom_order_already_bound'; end if;
 select m.customer_id into v_existing_customer from private.yt_pos_custom_order_members m where m.order_id=p_order for update;
 if v_existing_customer is not null and v_existing_customer<>v_customer then raise exception 'custom_order_already_bound'; end if;
 if exists(select 1 from public.yt_pos_custom_drink_members m where m.first_order_id=p_order and m.customer_id<>v_customer) then
  raise exception 'custom_order_already_bound';
 end if;
 v_already_bound:=v_existing_customer is not null;
 insert into private.yt_pos_custom_order_members(order_id,customer_id,bound_by) values(p_order,v_customer,auth.uid()) on conflict(order_id) do nothing;
 insert into public.yt_pos_custom_drink_members(custom_drink_id,customer_id,first_order_id)
 select distinct d.id,v_customer,p_order from public.yt_member_order_items i
 join public.yt_pos_custom_drinks d on d.product_id=i.product_id where i.order_id=p_order and i.quantity>0
 on conflict(custom_drink_id,customer_id) do nothing;
 get diagnostics v_count=row_count;
 update public.yt_pos_custom_drinks d set customer_id=v_customer from public.yt_member_order_items i
 where i.order_id=p_order and i.quantity>0 and i.product_id=d.product_id and d.customer_id is null;
 return jsonb_build_object('bound',true,'already_bound',v_already_bound or v_count=0,'custom_drinks',v_count,'order_customer_id',v_customer);
end;
$function$


CREATE OR REPLACE FUNCTION private.yt_pos_custom_attach_customer(p_order uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare cid uuid; paid boolean; existing_customer uuid;
begin
 select exists(select 1 from public.yt_member_orders o where o.id=p_order and o.payment_status='paid' and o.status not in ('cancelled','refunded')) into paid;
 if not paid then return; end if;
 select customer_id into cid from public.yt_play_consumption_bindings where order_id=p_order limit 1;
 if cid is null then return; end if;
 select customer_id into existing_customer from private.yt_pos_custom_order_members where order_id=p_order for update;
 if existing_customer is not null and existing_customer<>cid then raise exception 'custom_order_already_bound'; end if;
 insert into private.yt_pos_custom_order_members(order_id,customer_id,bound_by) values(p_order,cid,auth.uid()) on conflict(order_id) do nothing;
 insert into public.yt_pos_custom_drink_members(custom_drink_id,customer_id,first_order_id)
 select distinct d.id,cid,p_order from public.yt_member_order_items i join public.yt_pos_custom_drinks d on d.product_id=i.product_id
 where i.order_id=p_order and i.quantity>0 on conflict(custom_drink_id,customer_id) do nothing;
 update public.yt_pos_custom_drinks d set customer_id=cid,updated_at=clock_timestamp()
 from public.yt_member_order_items i where i.order_id=p_order and i.product_id=d.product_id and d.customer_id is null;
end;
$function$


CREATE OR REPLACE FUNCTION private.yt_pos_orders(p_scope text DEFAULT 'active'::text, p_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_result jsonb;
begin
 if not private.yt_pos_work_staff() and not private.yt_work_owner() then raise exception 'staff_only'; end if;
 if p_scope not in ('active','pending','paid','all','mine') or p_limit is null or p_limit<1 or p_limit>150 then raise exception 'invalid_filter'; end if;
 if p_scope='pending' and not private.yt_pos_work_cashier() and not private.yt_work_owner() then raise exception 'cashier_only'; end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc),'[]'::jsonb) into v_result from (
  select x.id,x.order_no,x.table_label,x.notes,x.status,x.payment_status,x.checkout_mode,x.amount_rm,x.revision,x.pos_business_day,x.requested_business_day,x.backdate_approval_status,x.settlement_due_since,
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
    'custom_bound',exists(select 1 from private.yt_pos_custom_order_members cm where cm.order_id=i.order_id),
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
$function$


CREATE OR REPLACE FUNCTION private.yt_pos_orders_day(p_scope text DEFAULT 'active'::text, p_day date DEFAULT NULL::date, p_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_result jsonb;
begin
 if not private.yt_pos_work_staff() and not private.yt_work_owner() then raise exception 'staff_only'; end if;
 if p_scope not in ('active','pending','paid','all','mine') or p_limit is null or p_limit<1 or p_limit>150 then raise exception 'invalid_filter'; end if;
 if p_scope='pending' and not private.yt_pos_work_cashier() and not private.yt_work_owner() then raise exception 'cashier_only'; end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc),'[]'::jsonb) into v_result from (
  select x.id,x.order_no,x.table_label,x.notes,x.status,x.payment_status,x.checkout_mode,x.amount_rm,x.revision,x.pos_business_day,x.requested_business_day,x.backdate_approval_status,x.settlement_due_since,
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
    'custom_bound',exists(select 1 from private.yt_pos_custom_order_members cm where cm.order_id=i.order_id),
    'store_box_item',exists(select 1 from public.yt_store_box_product_rules sr where sr.product_id=i.product_id and sr.active)
   ) order by i.item_name) from public.yt_member_order_items i
   left join public.yt_pos_custom_drinks cd on cd.product_id=i.product_id
   where i.order_id=x.id and i.quantity>0),'[]'::jsonb) items
  from public.yt_member_orders x left join public.work_accounts wa on wa.auth_user_id=x.created_by
  where x.source='future_pos' and (
   (p_scope='active' and ((x.status in ('pending','confirmed') and x.payment_status in ('unpaid','paid')) or (x.status='fulfilled' and x.payment_status='unpaid')))
   or (p_scope='pending' and x.status='pending')
   or (p_scope='paid' and x.payment_status in ('paid','refunded')
    and coalesce(x.pos_business_day,private.yt_business_day(x.paid_at))=coalesce(p_day,private.yt_business_day(now())))
   or p_scope='all' or (p_scope='mine' and x.created_by=auth.uid())
  ) order by case when p_scope='paid' then x.paid_at else x.created_at end desc limit p_limit
 ) o;
 return v_result;
end;
$function$


CREATE OR REPLACE FUNCTION private.yt_store_box_cashier_request(p_box uuid, p_selections jsonb, p_request uuid, p_initial boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid:=auth.uid();b public.yt_store_boxes%rowtype;sel jsonb:='[]'::jsonb;
 entry jsonb;candidate jsonb;total_qty int:=0;v_qty int;v_key text;v_name text;
 r public.yt_store_box_requests%rowtype;
begin
 if not (private.yt_pos_work_cashier() or private.yt_work_owner()) then raise exception 'cashier_only';end if;
 if p_box is null or p_request is null or p_selections is null or jsonb_typeof(p_selections)<>'array'
  or jsonb_array_length(p_selections)<1 or jsonb_array_length(p_selections)>20 then raise exception 'invalid_store_box_selection';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into r from public.yt_store_box_requests where client_request_id=p_request for update;
 if found then
  if r.box_id<>p_box or not (r.selections @> p_selections and jsonb_array_length(r.selections)=jsonb_array_length(p_selections)) then raise exception 'request_conflict';end if;
  return jsonb_build_object('request_id',r.id,'quantity',r.quantity,'idempotent',true);
 end if;
 select * into b from public.yt_store_boxes where id=p_box for update;
 if not found or b.status not in('unclaimed','active') or b.storage_expires_at<=clock_timestamp()
  or (p_initial and (not b.cashier_managed or b.customer_id is not null))
  or (not p_initial and not (b.customer_id is not null and b.status='active' or b.cashier_managed and b.customer_id is null))
 then raise exception 'store_box_not_available';end if;
 if exists(select 1 from public.yt_store_box_requests where box_id=p_box and status in('pending','accepted','preparing')) then raise exception 'store_box_request_already_active';end if;
 for entry in select value from jsonb_array_elements(p_selections) loop
  v_key:=nullif(btrim(entry->>'key'),'');
  if v_key is null or coalesce(entry->>'quantity','')!~'^[0-9]{1,2}$' then raise exception 'invalid_store_box_selection';end if;
  v_qty:=(entry->>'quantity')::integer;
  if v_qty<1 then raise exception 'invalid_store_box_selection';end if;
  if exists(select 1 from jsonb_array_elements(sel) x where x->>'key'=v_key) then raise exception 'duplicate_store_box_component';end if;
  select value into candidate from jsonb_array_elements(b.components) where value->>'key'=v_key;
  if candidate is null or (candidate->>'total_units')::integer-(candidate->>'served_units')::integer<v_qty then raise exception 'store_box_component_unavailable';end if;
  v_name:=candidate->>'name';sel:=sel||jsonb_build_array(jsonb_build_object('key',v_key,'name',v_name,'quantity',v_qty));total_qty:=total_qty+v_qty;
 end loop;
 if total_qty<1 or total_qty>99 or total_qty>b.total_units-b.served_units then raise exception 'store_box_quantity_unavailable';end if;
 if b.mode='challenge' and total_qty<>1 then raise exception 'challenge_one_cup_only';end if;
 insert into public.yt_store_box_requests(box_id,customer_id,quantity,component_key,component_name,selections,client_request_id,table_label,expires_at)
 values(b.id,b.customer_id,total_qty,sel->0->>'key',sel->0->>'name',sel,p_request,b.table_label,clock_timestamp()+interval '8 hours')
 returning * into r;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,actor_id,customer_id,metadata)
 values(b.id,r.id,'drink_requested',total_qty,actor,b.customer_id,jsonb_build_object('source',case when p_initial then 'cashier_checkout' else 'cashier_direct' end,'selections',sel));
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(actor,'store_box.cashier_prep','store_box',b.id,jsonb_build_object('request_id',r.id,'quantity',total_qty,'initial',p_initial,'box_number',b.box_number));
 return jsonb_build_object('request_id',r.id,'quantity',total_qty,'selections',sel,'idempotent',false);
end $function$
