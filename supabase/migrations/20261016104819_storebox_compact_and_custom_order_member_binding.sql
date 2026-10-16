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

CREATE OR REPLACE FUNCTION private.yt_owner_reset_v9(p_actor uuid, p_session text, p_action text, p_challenge uuid DEFAULT NULL::uuid, p_request uuid DEFAULT NULL::uuid, p_done bigint[] DEFAULT '{}'::bigint[], p_scopes text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v private.yt_owner_reset_challenges%rowtype; s text[]; counts jsonb:='{}'; result jsonb; c uuid;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'owner_only';end if;
 if p_session is null or p_session !~ '^[0-9a-f]{64}$' then raise exception 'not_authenticated';end if;
 if not exists(select 1 from public.work_accounts a join public.staff_roles r on r.user_id=a.auth_user_id
  where a.auth_user_id=p_actor and a.role='owner' and a.active and not a.must_change_password and r.role='owner' and r.active)
 then raise exception 'owner_only';end if;
 if p_action in ('status','batch','ack') then
  result=private.yt_owner_reset_v7(p_actor,p_session,p_action,p_challenge,p_request,p_done);
  select * into v from private.yt_owner_reset_challenges where id=(result->>'challenge')::uuid and actor_id=p_actor;
  return result||jsonb_build_object('scopes',coalesce(v.scopes,'{}'::text[]));
 end if;
 if p_action='prepare' then
  if p_request is null then raise exception 'invalid_reset_request';end if;
  if p_scopes is null or cardinality(p_scopes)=0 or cardinality(p_scopes)>7 or exists(
   select 1 from unnest(p_scopes) x where x is null or x not in ('records','members','catalog','campaigns','team','banners','storebox'))
  then raise exception 'invalid_reset_scope';end if;
  select array_agg(distinct x order by x) into s from unnest(p_scopes) x;
  if s&&array['members','catalog','campaigns','team']::text[] and not ('records'=any(s)) then s=array_append(s,'records');end if;
  select array_agg(x order by x) into s from unnest(s) x;
  if exists(select 1 from private.yt_owner_reset_challenges where state='committed') then raise exception 'reset_cleanup_pending';end if;
  if 'members'=any(s) and not ('storebox'=any(s)) and exists (select 1 from public.yt_store_boxes where customer_id is not null) then raise exception 'storebox_member_reset_blocked';end if;
   if 'records'=any(s) then counts=counts||jsonb_build_object('订单',(select count(*) from public.yt_member_orders),'Game Pass',(select count(*) from public.game_passes),'钱包奖励',(select count(*) from public.user_rewards),'积分记录',(select count(*) from public.yt_point_entries),'Ambassador Pass',(select count(*) from public.yt_ambassador_passes),'Ambassador 核销',(select count(*) from public.yt_ambassador_checkins),'Ambassador 佣金记录',(select count(*) from public.yt_ambassador_ledger),'营业日回填申请',(select count(*) from public.yt_pos_order_backdate_requests),'订制饮品记录',(select count(*) from public.yt_pos_custom_drinks),'订制会员绑定',(select count(*) from public.yt_pos_custom_drink_members));end if;
  if 'members'=any(s) then counts=counts||jsonb_build_object('会员账号',(select count(*) from public.pin_accounts where auth_user_id<>p_actor and not exists(select 1 from public.work_accounts w where w.auth_user_id=pin_accounts.auth_user_id)));end if;
  if 'catalog'=any(s) then counts=counts||jsonb_build_object('商品',(select count(*) from public.yt_shop_products),'权益系列',(select count(*) from public.yt_pos_series));end if;
  if 'campaigns'=any(s) then counts=counts||jsonb_build_object('活动',(select count(*) from public.campaigns),'奖励种类',(select count(*) from public.rewards));end if;
  if 'team'=any(s) then counts=counts||jsonb_build_object('其他工作账号',(select count(*) from public.work_accounts where auth_user_id<>p_actor));end if;
  if 'storebox'=any(s) then counts=counts||jsonb_build_object('存酒箱',(select count(*) from public.yt_store_boxes),'未完成叫酒',(select count(*) from public.yt_store_box_requests where status not in ('served','cancelled','rejected')));end if;
   if 'banners'=any(s) then counts=counts||jsonb_build_object('广告',(select count(*) from public.yt_home_banners),'广告文件',(select count(*) from storage.objects where bucket_id='yetipsy-home-banners'));end if;
  insert into private.yt_owner_reset_challenges(actor_id,session_key,request_id,counts,scopes)
   values(p_actor,p_session,p_request,counts,s) on conflict(actor_id,session_key,request_id) do nothing;
  select * into v from private.yt_owner_reset_challenges where actor_id=p_actor and session_key=p_session and request_id=p_request;
  if v.scopes<>s then raise exception 'reset_scope_conflict';end if;
  if v.state<>'pending' or v.expires_at<=now() then raise exception 'reset_confirmation_expired';end if;
  return jsonb_build_object('challenge',v.id,'counts',v.counts,'scopes',v.scopes,'expires_at',v.expires_at);
 end if;
 if p_action<>'commit' or p_challenge is null then raise exception 'invalid_reset_request';end if;
 perform pg_advisory_xact_lock(781943071);
 select * into v from private.yt_owner_reset_challenges where id=p_challenge and actor_id=p_actor and session_key=p_session for update;
 if not found then raise exception 'reset_confirmation_expired';end if;
 if v.state in ('committed','complete') then return jsonb_build_object('challenge',v.id,'state',v.state,'scopes',v.scopes);end if;
 if v.state<>'pending' or v.expires_at<=now() then raise exception 'reset_confirmation_expired';end if;
 if exists(select 1 from private.yt_owner_reset_challenges where state='committed' and id<>v.id) then raise exception 'reset_cleanup_pending';end if;
 s=v.scopes;
  if 'members'=any(s) and not ('storebox'=any(s)) and exists (select 1 from public.yt_store_boxes where customer_id is not null) then raise exception 'storebox_member_reset_blocked';end if;
  if cardinality(s)=7 then delete from public.yt_business_cutoffs where true;insert into public.yt_business_cutoffs(effective_day,cutoff_minutes) values('1900-01-01',360);end if; -- Only this immutable first-confirmation snapshot controls deletion.
 if 'banners'=any(s) then
  insert into private.yt_owner_reset_cleanup(challenge_id,kind,target) select v.id,'asset',name from storage.objects where bucket_id='yetipsy-home-banners';
 end if;
 insert into private.yt_owner_reset_cleanup(challenge_id,kind,target)
 select v.id,'user',u.id::text from auth.users u where u.id<>p_actor and (
  ('members'=any(s) and 'team'=any(s))
  or ('members'=any(s) and exists(select 1 from public.pin_accounts a where a.auth_user_id=u.id) and not exists(select 1 from public.work_accounts a where a.auth_user_id=u.id))
  or ('team'=any(s) and exists(select 1 from public.work_accounts a where a.auth_user_id=u.id)));
 if 'storebox'=any(s) then
   truncate table public.yt_store_box_events,public.yt_store_box_requests,public.yt_store_box_claims,public.yt_store_boxes restart identity;
  end if;
  if 'records'=any(s) then
   UPDATE public.yt_moon_guest_codes SET status='available',reserved_order_id=NULL,reserved_item_id=NULL WHERE status='reserved';
   update public.yt_store_boxes b
   set source_order_snapshot=coalesce(b.source_order_snapshot,jsonb_build_object('id',o.id,'order_no',o.order_no,'created_at',o.created_at,'table_label',o.table_label,'amount_rm',o.amount_rm)),
       source_item_snapshot=coalesce(b.source_item_snapshot,jsonb_build_object('id',i.id,'item_name',i.item_name,'quantity',i.quantity,'unit_price_rm',i.unit_price_rm))
   from public.yt_member_orders o join public.yt_member_order_items i on i.order_id=o.id
   where b.source_order_id=o.id and b.source_order_item_id=i.id;
  -- Fixed transaction tables; configuration and account tables are retained.
  truncate table private.yt_offer_code_attempts,private.yt_offer_short_codes,private.yt_pos_draft_submissions,
   private.yt_redeem_code_attempts,private.yt_redeem_short_codes,
   public.audit_logs,public.game_passes,public.game_sessions,public.idempotency_keys,
   public.pin_auth_limits,public.pin_lookup_limits,public.pin_reset_tokens,public.redeem_tokens,public.redemptions,
   public.reward_offer_claims,public.reward_offers,public.user_rewards,public.work_auth_limits,
   public.yt_game_best_records,public.yt_game_leaderboard_preferences,public.yt_integration_events,
   public.yt_member_enrollments,public.yt_lucky_day_reservations,public.yt_moon_preorder_holds,public.yt_member_order_items,public.yt_pos_order_backdate_requests,public.yt_member_orders,public.yt_pos_custom_drink_versions,private.yt_pos_custom_order_members,public.yt_pos_custom_drink_members,public.yt_pos_custom_drinks,public.yt_point_shop_exchanges,public.yt_point_entries,public.yt_point_wallets,
   public.yt_ambassador_ledger,public.yt_ambassador_checkins,public.yt_ambassador_pos_sales,public.yt_ambassador_passes,public.yt_pos_owner_revision_requests,public.yt_pos_order_revisions,public.yt_pos_payment_entries,public.yt_pos_day_closings,public.yt_pos_item_units,public.yt_pos_order_chits,public.yt_pos_order_events,public.yt_pos_duitnow_proofs,public.yt_pos_pass_bundle_items,public.yt_pos_pass_bundles,
   public.yt_pos_preorder_holds,public.yt_pos_reward_holds,private.yt_store_box_prep_intents,public.yt_promo_grants,public.yt_referral_links,public.yt_play_order_tokens,public.yt_play_consumption_bindings,public.yt_play_first_purchases,public.yt_play_referral_events,public.yt_play_member_tokens,public.yt_play_invite_tokens,public.yt_play_bell_requests restart identity;
  delete from public.yt_shop_products where category='CUSTOM';
  update public.yt_point_shop_items set stock_used=0 where true;
  update public.reward_pool_entries set issued_total=0,issued_today=0,issued_day=null where true;
  -- Deleted enrollment/grant history must not automatically grant old members new gifts.
  update public.yt_loyalty_config set welcome_enabled=false,referral_enabled=false,updated_at=now() where true;
 end if;
 if 'campaigns'=any(s) then
  delete from public.yt_point_shop_items where true;
  update public.games set points_max=100,reaction_perfect_ms=200,reaction_zero_ms=1000 where true;
  delete from public.yt_pos_reward_rules where true;delete from public.reward_pool_entries where true;delete from public.campaign_games where true;
  delete from public.yt_point_tiers where true;delete from public.yt_loyalty_config where true;
  delete from public.rewards where true;delete from public.campaigns where true;
  insert into public.yt_loyalty_config(id) values(true);
  insert into public.campaigns(name,active) values('默认活动',false) returning id into c;
  insert into public.campaign_games(campaign_id,game_id) select c,id from public.games where active;
 end if;
 if 'catalog'=any(s) then
  delete from public.yt_pos_reward_rules where product_id is not null or series_id is not null;
  delete from public.yt_pos_custom_materials where true;delete from public.yt_shop_products where true;delete from public.yt_pos_series where true;
 end if;
 if 'banners'=any(s) then delete from public.yt_home_banners where true;end if;
 if s&&array['members','team']::text[] then
  update public.yt_home_banners set updated_by=null where updated_by::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  update public.yt_loyalty_config set updated_by=null where updated_by::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  update public.yt_pos_reward_rules set updated_by=null where updated_by::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  update public.work_accounts set created_by=null where created_by::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.pin_accounts where auth_user_id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.member_details where user_id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.work_accounts where auth_user_id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.staff_roles where user_id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.profiles where id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
 end if;
 update private.yt_owner_reset_challenges set state='cancelled' where state='pending' and id<>v.id;
 update private.yt_owner_reset_challenges set state='committed' where id=v.id;
 return jsonb_build_object('challenge',v.id,'state','committed','scopes',v.scopes);
end;$function$

