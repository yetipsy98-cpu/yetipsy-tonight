ALTER TABLE public.yt_member_orders
 ADD COLUMN IF NOT EXISTS pos_business_day date,
 ADD COLUMN IF NOT EXISTS requested_business_day date,
 ADD COLUMN IF NOT EXISTS backdate_approval_status text NOT NULL DEFAULT 'not_required';

CREATE TABLE IF NOT EXISTS public.yt_pos_order_backdate_requests(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 order_id uuid NOT NULL UNIQUE REFERENCES public.yt_member_orders(id) ON DELETE CASCADE,
 requested_business_day date NOT NULL,
 requester_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
 reviewer_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','approved','rejected')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 reviewed_at timestamptz,
 review_note text
);
CREATE INDEX IF NOT EXISTS yt_pos_order_backdate_requests_status_created_idx ON public.yt_pos_order_backdate_requests(status,created_at DESC);
ALTER TABLE public.yt_pos_order_backdate_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.yt_pos_order_backdate_requests FROM PUBLIC,anon,authenticated,service_role;

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
    and coalesce(x.pos_business_day,private.yt_business_day(x.paid_at))=coalesce(p_day,private.yt_business_day(now())))
   or p_scope='all' or (p_scope='mine' and x.created_by=auth.uid())
  ) order by case when p_scope='paid' then x.paid_at else x.created_at end desc limit p_limit
 ) o;
 return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_action(p_order uuid, p_action text, p_reason text DEFAULT NULL::text, p_method text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_member_orders%rowtype;v_cashier boolean:=private.yt_pos_work_cashier();
 v_actor uuid:=auth.uid();v_reason text:=nullif(btrim(coalesce(p_reason,'')),'');v_store_box_only boolean;
 v_claims jsonb:='[]'::jsonb;v_issue jsonb;v_item record;v_result_status text;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_order is null or p_action not in ('accept','reject','fulfilled','paid','cancel') then raise exception 'invalid_action';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 v_store_box_only:=private.yt_store_box_order_only(p_order);
 if v.created_at<=clock_timestamp()-interval '72 hours' and private.yt_work_owner() and length(btrim(coalesce(p_reason,'')))<2 then raise exception 'reason_required';end if;
 if p_action='accept' then
  if not v_cashier then raise exception 'cashier_only';end if;
  if v.status<>'pending' or v.payment_status<>'unpaid' then raise exception 'order_not_pending';end if;
  update public.yt_member_orders set status='confirmed',accepted_by=v_actor,accepted_at=clock_timestamp(),updated_at=clock_timestamp() where id=p_order;
  if not v_store_box_only then
   insert into public.yt_pos_order_chits(order_id) values(p_order)
   on conflict(order_id) do update set status='queued',issued_at=clock_timestamp(),printed_at=null,printed_by=null;
  end if;
 elsif p_action='reject' then
  if not v_cashier then raise exception 'cashier_only';end if;
  if v.status<>'pending' or v.payment_status<>'unpaid' then raise exception 'order_not_pending';end if;
  if length(coalesce(v_reason,''))<2 or length(v_reason)>300 then raise exception 'reason_required';end if;
  update public.yt_member_orders set status='cancelled',rejected_by=v_actor,rejected_at=clock_timestamp(),reject_reason=v_reason,updated_at=clock_timestamp() where id=p_order;
 elsif p_action='fulfilled' then
  if v.status<>'confirmed' or v.payment_status not in ('unpaid','paid') then raise exception 'order_not_accepted';end if;
  update public.yt_member_orders set status='fulfilled',fulfilled_by=v_actor,fulfilled_at=clock_timestamp(),updated_at=clock_timestamp() where id=p_order;
  if v.payment_status='paid' then
   for v_item in
    select i.id from public.yt_member_order_items i
    join public.yt_store_box_product_rules r on r.product_id=i.product_id and r.active
    where i.order_id=p_order and i.quantity>0 and not exists(select 1 from public.yt_store_boxes b where b.source_order_item_id=i.id and b.cashier_managed) order by i.id
   loop
    v_issue:=private.yt_store_box_issue(v_item.id,gen_random_uuid(),gen_random_uuid(),2);
    v_claims:=v_claims||jsonb_build_array(v_issue);
   end loop;
  end if;
 elsif p_action='paid' then
  if v.backdate_approval_status='pending' then raise exception 'backdate_approval_pending';end if;
  if p_method='duitnow' and not v_cashier then raise exception 'cashier_only';end if;
  if v.payment_status<>'unpaid' or v.status not in ('confirmed','fulfilled') then raise exception 'order_not_served';end if;
  if p_method is null or btrim(p_method)='' then p_method:='foodcourt';end if;
  if p_method not in ('foodcourt','cash','duitnow','card','bank_transfer','other') then raise exception 'invalid_payment_method';end if;
  v_result_status:=case when v.status='fulfilled' or v_store_box_only then 'fulfilled' else 'confirmed' end;
  update public.yt_member_orders set status=v_result_status,
   fulfilled_by=case when v_result_status='fulfilled' and v.status='confirmed' then v_actor else fulfilled_by end,
   fulfilled_at=case when v_result_status='fulfilled' and v.status='confirmed' then clock_timestamp() else fulfilled_at end,
   payment_status='paid',paid_by=v_actor,paid_at=clock_timestamp(),payment_method=p_method,updated_at=clock_timestamp()
  where id=p_order;
  if v_result_status='fulfilled' then
   for v_item in
    select i.id from public.yt_member_order_items i
    join public.yt_store_box_product_rules r on r.product_id=i.product_id and r.active
    where i.order_id=p_order and i.quantity>0 and not exists(select 1 from public.yt_store_boxes b where b.source_order_item_id=i.id and b.cashier_managed) order by i.id
   loop
    v_issue:=private.yt_store_box_issue(v_item.id,gen_random_uuid(),gen_random_uuid(),2);
    v_claims:=v_claims||jsonb_build_array(v_issue);
   end loop;
  end if;
 elsif p_action='cancel' then
  if not v_cashier then raise exception 'cashier_only';end if;
  if v.status not in ('pending','confirmed') or v.payment_status<>'unpaid' then raise exception 'order_cannot_cancel';end if;
  if length(coalesce(v_reason,''))<2 or length(v_reason)>300 then raise exception 'reason_required';end if;
  update public.yt_member_orders set status='cancelled',rejected_by=v_actor,rejected_at=clock_timestamp(),reject_reason=v_reason,updated_at=clock_timestamp() where id=p_order;
  update public.yt_pos_order_chits set status='cancelled' where order_id=p_order;
 end if;
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note)
 values(p_order,v_actor,case when p_action='fulfilled' then 'fulfilled' when p_action='paid' then 'paid' when p_action in ('reject','cancel') then case when p_action='reject' then 'rejected' else 'cancelled' end else 'accepted' end,
  case when v_cashier then 'cashier' else 'staff' end,case when p_action='paid' then p_method else v_reason end);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(v_actor,'pos.'||p_action,'pos_order',p_order,jsonb_build_object('payment_method',p_method,'note',v_reason,'store_box_claims',jsonb_array_length(v_claims)));
 select * into v from public.yt_member_orders where id=p_order;
 return jsonb_build_object('ok',true,'order_id',p_order,'action',p_action,'status',v.status,
  'payment_status',v.payment_status,'store_box_claims',v_claims);
end $function$;

CREATE OR REPLACE FUNCTION private.yt_pos_payment_capture()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.source='future_pos' and new.payment_status='paid' and old.payment_status<>'paid' and new.amount_rm>0 then
  insert into public.yt_pos_payment_entries(order_id,request_id,method,amount_rm,kind,received_at,business_day,actor_id)
  values(new.id,gen_random_uuid(),new.payment_method,new.amount_rm,'sale',new.paid_at,coalesce(new.pos_business_day,private.yt_business_day(new.paid_at)),new.paid_by);
 end if;return new;
end $function$;

CREATE OR REPLACE FUNCTION private.yt_owner_report_v8(p_start date, p_end date, p_member_page integer DEFAULT 1, p_search text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare today date:=private.yt_business_day(now());
 a timestamptz;z timestamptz;t timestamptz;m timestamptz; result jsonb; stats jsonb; days jsonb; pay jsonb; products jsonb; orders jsonb; members jsonb; member_total bigint;
begin
 if not ((private.yt_has_role('owner') and private.yt_pos_work_staff()) or private.yt_owner_limited()) then raise exception 'owner_only';end if;
 if p_start is null or p_end is null or p_start>p_end or p_end-p_start>365 or p_member_page is null or p_member_page<1 or p_member_page>10000 or p_search is null or length(p_search)>80 then raise exception 'invalid_report_range';end if;
 a=private.yt_business_start(p_start);z=private.yt_business_start(p_end+1);
 t=private.yt_business_start(today);m=private.yt_business_start(date_trunc('month',today::timestamp)::date);
 select jsonb_build_object('today_amount',coalesce(sum(amount_rm) filter(where business_day=today),0),
  'today_orders',count(distinct order_id) filter(where business_day=today),
  'month_amount',coalesce(sum(amount_rm) filter(where business_day>=date_trunc('month',today::timestamp)::date and business_day<(date_trunc('month',today::timestamp)+interval '1 month')::date),0),
  'month_orders',count(distinct order_id) filter(where business_day>=date_trunc('month',today::timestamp)::date and business_day<(date_trunc('month',today::timestamp)+interval '1 month')::date))
 into stats from public.yt_pos_payment_entries where business_day>=date_trunc('month',today::timestamp)::date;
 select stats||jsonb_build_object('range_amount',coalesce(sum(e.amount_rm),0),'range_orders',count(distinct e.order_id),
  'average_order',case when count(distinct e.order_id)>0 then round(sum(e.amount_rm)/count(distinct e.order_id),2) else 0 end) into stats
 from public.yt_pos_payment_entries e where business_day between p_start and p_end;
 select stats||jsonb_build_object('range_gross',coalesce(sum(i.gross),0),'range_discount',coalesce(sum(i.gross-o.amount_rm),0),
  'range_items',coalesce(sum(i.quantity),0)) into stats
 from public.yt_member_orders o cross join lateral(select coalesce(sum(quantity*unit_price_rm),0) gross,coalesce(sum(quantity),0) quantity from public.yt_member_order_items where order_id=o.id and quantity>0) i
 where o.source='future_pos' and o.payment_status='paid' and o.status='fulfilled' and coalesce(o.pos_business_day,private.yt_business_day(o.paid_at)) between p_start and p_end;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.day),'[]'::jsonb) into days from(
  select business_day as day,count(distinct order_id) orders,sum(amount_rm) amount_rm
  from public.yt_pos_payment_entries where business_day between p_start and p_end group by 1) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.amount_rm desc),'[]'::jsonb) into pay from(
  select method,count(distinct order_id) orders,sum(amount_rm) amount_rm
  from public.yt_pos_payment_entries where business_day between p_start and p_end group by 1) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.quantity desc,x.item_name),'[]'::jsonb) into products from(
  select i.product_id,i.item_name,sum(i.quantity) quantity,sum(i.quantity*i.unit_price_rm) gross_rm,
   sum(i.quantity*i.unit_price_rm-coalesce(u.discount,0)) net_rm
  from public.yt_member_order_items i join public.yt_member_orders o on o.id=i.order_id
  left join lateral(select sum(reward_discount_rm) discount from public.yt_pos_item_units where order_item_id=i.id and not retired and unit_number<=i.quantity) u on true
  where o.source='future_pos' and o.payment_status='paid' and o.status='fulfilled' and coalesce(o.pos_business_day,private.yt_business_day(o.paid_at)) between p_start and p_end and i.quantity>0
  group by i.product_id,i.item_name order by quantity desc,i.item_name limit 20) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.paid_at desc),'[]'::jsonb) into orders from(
  select o.id,o.order_no,o.table_label,max(e.received_at) paid_at,string_agg(distinct e.method,', ' order by e.method) payment_method,sum(e.amount_rm) amount_rm
  from public.yt_pos_payment_entries e join public.yt_member_orders o on o.id=e.order_id
  where e.business_day between p_start and p_end group by o.id order by max(e.received_at) desc,o.id limit 50) x;
 select count(*) into member_total from public.pin_accounts p left join public.profiles f on f.id=p.auth_user_id
 where not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)
 and (p_search='' or position(lower(p_search) in lower(coalesce(f.display_name,'')||' '||p.phone))>0);
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id),'[]'::jsonb) into members from(
  select p.auth_user_id id,p.phone,coalesce(nullif(f.display_name,''),'会员') display_name,p.created_at,
   (select coalesce(sum(remaining_points),0) from public.yt_point_entries e where e.customer_id=p.auth_user_id and e.direction='earn' and (e.expires_at is null or e.expires_at>clock_timestamp())) points,
   (select count(*) from public.user_rewards r where r.customer_id=p.auth_user_id and r.status='available' and r.expires_at>now()) wallet_rewards,
   (select count(*) from public.game_passes g where g.customer_id=p.auth_user_id and g.status='claimed' and g.expires_at>now()) game_passes,
   (select coalesce(sum(i.unit_price_rm-u.reward_discount_rm),0) from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id join public.yt_member_orders o on o.id=i.order_id
     where u.assigned_customer_id=p.auth_user_id and not u.retired and u.unit_number<=i.quantity and o.payment_status='paid' and o.source='future_pos') attributed_amount,
   greatest((select max(claimed_at) from public.game_passes where customer_id=p.auth_user_id),
    (select max(started_at) from public.game_sessions where customer_id=p.auth_user_id),
    (select max(redeemed_at) from public.redemptions where customer_id=p.auth_user_id)) last_activity
  from public.pin_accounts p left join public.profiles f on f.id=p.auth_user_id left join public.yt_point_wallets w on w.customer_id=p.auth_user_id
  where not exists(select 1 from public.work_accounts wa where wa.auth_user_id=p.auth_user_id)
   and (p_search='' or position(lower(p_search) in lower(coalesce(f.display_name,'')||' '||p.phone))>0)
  order by p.created_at desc,p.auth_user_id limit 40 offset (p_member_page-1)*40) x;
 result=jsonb_build_object('financial_source','payment_ledger','generated_at',now(),'timezone','Asia/Kuala_Lumpur','start',p_start,'end',p_end,'stats',stats,'days',days,'payments',pay,'products',products,'orders',orders,
  'members',members,'member_page',p_member_page,'member_page_size',40,'member_filtered_total',member_total,
  'member_stats',jsonb_build_object(
   'total',(select count(*) from public.pin_accounts p where not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)),
   'month_new',(select count(*) from public.pin_accounts p where created_at>=m and created_at<private.yt_business_start(today+1) and not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)),
   'active_30d',(select count(distinct customer_id) from(
     select customer_id from public.game_passes where claimed_at>=now()-interval '30 days'
     union select customer_id from public.game_sessions where started_at>=now()-interval '30 days'
     union select customer_id from public.redemptions where redeemed_at>=now()-interval '30 days') q where customer_id is not null and exists(select 1 from public.pin_accounts pa where pa.auth_user_id=q.customer_id) and not exists(select 1 from public.work_accounts wa where wa.auth_user_id=q.customer_id)),
   'point_balance',(select coalesce(sum(remaining_points),0) from public.yt_point_entries where direction='earn' and (expires_at is null or expires_at>clock_timestamp()))),
  'live',jsonb_build_object(
   'active_point_shop_items',(select count(*) from public.yt_point_shop_items i join public.rewards r on r.id=i.reward_id where i.active and r.active and (i.starts_at is null or i.starts_at<=now()) and (i.ends_at is null or i.ends_at>now()) and (i.stock_limit is null or i.stock_used<i.stock_limit)),
   'pending_orders',(select count(*) from public.yt_member_orders where source='future_pos' and status='pending' and payment_status='unpaid'),
   'preparing_orders',(select count(*) from public.yt_member_orders where source='future_pos' and status='confirmed' and payment_status='unpaid'),
   'unpaid_orders',(select count(*) from public.yt_member_orders where source='future_pos' and status='fulfilled' and payment_status='unpaid'),
   'active_products',(select count(*) from public.yt_shop_products where active),
   'active_series',(select count(*) from public.yt_pos_series where active and benefit_mode in('games','choose') and game_plays=1),
   'active_campaigns',(select count(*) from public.campaigns where active and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>now())),
   'active_rewards',(select count(*) from public.rewards r where r.active and exists(select 1 from public.yt_pos_reward_rules b where b.reward_id=r.id and b.mode<>'disabled')),
   'unbound_rewards',(select count(*) from public.rewards r where r.active and not exists(select 1 from public.yt_pos_reward_rules b where b.reward_id=r.id and b.mode<>'disabled')),
   'active_banners',(select count(*) from public.yt_home_banners where enabled),
   'work_accounts',(select count(*) from public.work_accounts where active),
   'unclaimed_passes',(select count(*) from public.game_passes where status='issued' and expires_at>now()),
   'claimed_passes',(select count(*) from public.game_passes where status='claimed' and expires_at>now()),
   'open_game_sessions',(select count(*) from public.game_sessions where status='started' and started_at>=now()-interval '1 day'),
   'wallet_rewards',(select count(*) from public.user_rewards where status='available' and expires_at>now()),
   'expiring_rewards',(select count(*) from public.user_rewards where status='available' and expires_at>now() and expires_at<=now()+interval '7 days'),
   'active_offers',(select count(*) from public.reward_offers where active and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>now()) and (max_claims is null or claimed_count<max_claims)),
   'held_rewards',(select count(*) from public.yt_pos_reward_holds where state in('reserved','ready') and expires_at>now()),
   'low_stock_pool_entries',(select count(*) from public.reward_pool_entries p join public.campaigns c on c.id=p.campaign_id where c.active and p.weight>0 and p.max_total is not null and p.max_total-p.issued_total<=5)),
  'reward_activity',jsonb_build_object(
   'point_exchanges',(select count(*) from public.yt_point_shop_exchanges where created_at>=a and created_at<z),
   'issued',(select count(*) from public.user_rewards where created_at>=a and created_at<z),
   'redeemed',(select count(*) from public.redemptions where redeemed_at>=a and redeemed_at<z),
   'passes_claimed',(select count(*) from public.game_passes where claimed_at>=a and claimed_at<z),
   'games_completed',(select count(*) from public.game_sessions where status='completed' and completed_at>=a and completed_at<z),
   'points_earned',(select coalesce(sum(points),0) from public.yt_point_entries where direction='earn' and created_at>=a and created_at<z),
   'points_spent',(select coalesce(sum(points),0) from public.yt_point_entries where direction='spend' and created_at>=a and created_at<z)));
 result=result||jsonb_build_object(
  'months',coalesce((select jsonb_agg(to_jsonb(x) order by x.month) from(
   select to_char(business_day,'YYYY-MM') as month,count(distinct order_id) orders,sum(amount_rm) amount_rm
   from public.yt_pos_payment_entries where business_day between p_start and p_end group by 1) x),'[]'::jsonb),
  'cashiers',coalesce((select jsonb_agg(to_jsonb(x) order by x.amount_rm desc) from(
   select coalesce(w.username,'原工作账号') username,count(distinct e.order_id) orders,sum(e.amount_rm) amount_rm
   from public.yt_pos_payment_entries e left join public.work_accounts w on w.auth_user_id=e.actor_id
   where e.business_day between p_start and p_end group by w.username) x),'[]'::jsonb),
  'reward_types',coalesce((select jsonb_agg(to_jsonb(x) order by x.reward_name) from(
   select r.name reward_name,
    (select count(*) from public.user_rewards u where u.reward_id=r.id and u.created_at>=a and u.created_at<z) issued,
    (select count(*) from public.user_rewards u join public.redemptions d on d.user_reward_id=u.id where u.reward_id=r.id and d.redeemed_at>=a and d.redeemed_at<z) redeemed,
    (select count(*) from public.user_rewards u where u.reward_id=r.id and u.status='available' and u.expires_at>now()) outstanding,
    (select count(*) from public.user_rewards u where u.reward_id=r.id and u.status='available' and u.expires_at>now() and u.expires_at<=now()+interval '7 days') expiring
   from public.rewards r order by r.name,r.id limit 100) x),'[]'::jsonb));
 return result||jsonb_build_object('business_day',today);
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_create_order_with_rewards_v4(
 p_request uuid,p_table text,p_note text,p_items jsonb,p_channel text,p_draft uuid,p_checkout_mode text,p_business_day date
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $function$
declare
 data jsonb; v_order uuid; v_day date:=coalesce(p_business_day,private.yt_business_day(clock_timestamp()));
 v_today date:=private.yt_business_day(clock_timestamp()); v_owner boolean:=private.yt_work_owner();
 v_status text; v_requested date; v_effective date;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if v_day<'2020-01-01' or v_day>v_today then raise exception 'invalid_business_day';end if;
 if v_day<v_today and not (v_owner or private.yt_pos_work_cashier()) then raise exception 'cashier_only';end if;
 data:=private.yt_pos_create_order_with_rewards_v3(p_request,p_table,p_note,p_items,p_channel,p_draft,p_checkout_mode);
 v_order:=(data->>'id')::uuid;
 if v_order is null then raise exception 'order_not_found';end if;
 if not coalesce((data->>'idempotent')::boolean,false) then
  if v_day<v_today and v_owner then
   update public.yt_member_orders set pos_business_day=v_day,requested_business_day=v_day,
    backdate_approval_status='approved',updated_at=clock_timestamp() where id=v_order;
   insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
    values(auth.uid(),'pos.order_backdated','pos_order',v_order,jsonb_build_object('business_day',v_day,'approved_by_owner',true));
  elsif v_day<v_today then
   update public.yt_member_orders set requested_business_day=v_day,
    backdate_approval_status='pending',updated_at=clock_timestamp() where id=v_order;
   insert into public.yt_pos_order_backdate_requests(order_id,requested_business_day,requester_id)
    values(v_order,v_day,auth.uid()) on conflict(order_id) do nothing;
  end if;
 end if;
 select backdate_approval_status,requested_business_day,pos_business_day
  into v_status,v_requested,v_effective from public.yt_member_orders where id=v_order;
 return data||jsonb_build_object('backdate_approval_status',v_status,
  'requested_business_day',v_requested,'business_day',v_effective);
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_owner_backdate_requests_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $function$
declare rows jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',q.id,'order_id',q.order_id,'order_no',o.order_no,'table_label',o.table_label,
  'requested_business_day',q.requested_business_day,'status',q.status,'created_at',q.created_at,
  'reviewed_at',q.reviewed_at,'review_note',q.review_note,
  'requester_name',coalesce(w.username,'Cashier'),'reviewer_name',coalesce(r.username,'Owner')
 ) order by (q.status='pending') desc,q.created_at desc),'[]'::jsonb)
 into rows from (
  select * from public.yt_pos_order_backdate_requests order by created_at desc limit 100
 ) q join public.yt_member_orders o on o.id=q.order_id
 left join public.work_accounts w on w.auth_user_id=q.requester_id
 left join public.work_accounts r on r.auth_user_id=q.reviewer_id;
 return rows;
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_owner_backdate_request_review(p_request uuid,p_approve boolean,p_note text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $function$
declare q public.yt_pos_order_backdate_requests%rowtype; o public.yt_member_orders%rowtype; note_text text:=nullif(btrim(coalesce(p_note,'')),'');
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_request is null or p_approve is null then raise exception 'invalid_backdate_request';end if;
 if not p_approve and length(coalesce(note_text,'')) not between 2 and 300 then raise exception 'reason_required';end if;
 select * into q from public.yt_pos_order_backdate_requests where id=p_request for update;
 if not found or q.status<>'pending' then raise exception 'backdate_request_not_pending';end if;
 select * into o from public.yt_member_orders where id=q.order_id and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 if p_approve then
  if o.payment_status<>'unpaid' or o.status in ('cancelled','rejected','refunded') then raise exception 'order_not_editable';end if;
  update public.yt_member_orders set pos_business_day=q.requested_business_day,
   backdate_approval_status='approved',updated_at=clock_timestamp() where id=o.id;
  update public.yt_pos_order_backdate_requests set status='approved',reviewer_id=auth.uid(),
   reviewed_at=clock_timestamp(),review_note=note_text where id=q.id;
 else
  update public.yt_member_orders set backdate_approval_status='rejected',updated_at=clock_timestamp() where id=o.id;
  update public.yt_pos_order_backdate_requests set status='rejected',reviewer_id=auth.uid(),
   reviewed_at=clock_timestamp(),review_note=note_text where id=q.id;
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(auth.uid(),case when p_approve then 'pos.order_backdate_approved' else 'pos.order_backdate_rejected' end,
  'pos_order',o.id,jsonb_build_object('business_day',q.requested_business_day,'note',note_text));
 return jsonb_build_object('ok',true,'order_id',o.id,'status',case when p_approve then 'approved' else 'rejected' end,
  'business_day',case when p_approve then q.requested_business_day else null end);
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_backdate_close_cancelled_order()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $function$
begin
 if new.status in ('cancelled','rejected','refunded') and old.status is distinct from new.status then
  update public.yt_pos_order_backdate_requests set status='rejected',reviewer_id=auth.uid(),
   reviewed_at=clock_timestamp(),review_note='订单已取消，营业日回填申请自动关闭'
   where order_id=new.id and status='pending';
 end if;
 return new;
end;$function$;
DROP TRIGGER IF EXISTS yt_pos_backdate_close_cancelled_order ON public.yt_member_orders;
CREATE TRIGGER yt_pos_backdate_close_cancelled_order AFTER UPDATE OF status ON public.yt_member_orders
FOR EACH ROW EXECUTE FUNCTION private.yt_pos_backdate_close_cancelled_order();

CREATE OR REPLACE FUNCTION private.yt_pos_custom_order_bindings(p_order uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $function$
begin
 if not (private.yt_work_owner() or private.yt_pos_work_cashier()) then raise exception 'cashier_only';end if;
 if p_order is null or not exists(select 1 from public.yt_member_orders where id=p_order and source='future_pos' and payment_status='paid') then
  raise exception 'custom_order_not_paid';
 end if;
 return coalesce((
  select jsonb_agg(jsonb_build_object(
   'custom_drink_id',d.id,'name',d.public_name,
   'members',coalesce((
    select jsonb_agg(jsonb_build_object(
     'name',coalesce(nullif(btrim(p.display_name),''),'会员'),
     'created_at',m.created_at,'first_order_no',first_order.order_no
    ) order by m.created_at,m.customer_id)
    from public.yt_pos_custom_drink_members m
    left join public.profiles p on p.id=m.customer_id
    left join public.yt_member_orders first_order on first_order.id=m.first_order_id
    where m.custom_drink_id=d.id
   ),'[]'::jsonb)
  ) order by d.public_name)
  from (
   select distinct cd.id,cd.public_name from public.yt_member_order_items i
   join public.yt_pos_custom_drinks cd on cd.product_id=i.product_id
   where i.order_id=p_order and i.quantity>0
  ) d
 ),'[]'::jsonb);
end;$function$;

CREATE OR REPLACE FUNCTION public.yt_pos_create_order_with_rewards_v4(p_request uuid,p_table text,p_note text,p_items jsonb,p_channel text,p_draft uuid,p_checkout_mode text,p_business_day date)
RETURNS jsonb LANGUAGE sql SET search_path='' AS $function$
 select private.yt_pos_create_order_with_rewards_v4($1,$2,$3,$4,$5,$6,$7,$8)
$function$;

CREATE OR REPLACE FUNCTION public.yt_pos_owner_backdate_requests_list()
RETURNS jsonb LANGUAGE sql SET search_path='' AS $function$ SELECT private.yt_pos_owner_backdate_requests_list() $function$;
CREATE OR REPLACE FUNCTION public.yt_pos_owner_backdate_request_review(p_request uuid,p_approve boolean,p_note text DEFAULT '')
RETURNS jsonb LANGUAGE sql SET search_path='' AS $function$ SELECT private.yt_pos_owner_backdate_request_review($1,$2,$3) $function$;
CREATE OR REPLACE FUNCTION public.yt_pos_custom_order_bindings(p_order uuid)
RETURNS jsonb LANGUAGE sql SET search_path='' AS $function$ SELECT private.yt_pos_custom_order_bindings($1) $function$;

DO $patch$
DECLARE
 v_definition text;
 v_updated text;
 v_count_anchor text := '''订制饮品记录'',(select count(*) from public.yt_pos_custom_drinks),''订制会员绑定'',(select count(*) from public.yt_pos_custom_drink_members)';
 v_truncate_anchor text := 'public.yt_member_orders,public.yt_pos_custom_drink_versions';
BEGIN
 SELECT pg_get_functiondef(
  'private.yt_owner_reset_v9(uuid,text,text,uuid,uuid,bigint[],text[])'::regprocedure
 ) INTO v_definition;

 IF position('public.yt_pos_order_backdate_requests' IN v_definition)=0 THEN
  IF position(v_count_anchor IN v_definition)=0 OR position(v_truncate_anchor IN v_definition)=0 THEN
   RAISE EXCEPTION 'backdate_reset_patch_anchor_missing';
  END IF;
  v_updated:=replace(
   v_definition,
   v_count_anchor,
   '''营业日回填申请'',(select count(*) from public.yt_pos_order_backdate_requests),''订制饮品记录'',(select count(*) from public.yt_pos_custom_drinks),''订制会员绑定'',(select count(*) from public.yt_pos_custom_drink_members)'
  );
  v_updated:=replace(
   v_updated,
   v_truncate_anchor,
   'public.yt_pos_order_backdate_requests,public.yt_member_orders,public.yt_pos_custom_drink_versions'
  );
  IF v_updated=v_definition THEN RAISE EXCEPTION 'backdate_reset_patch_failed';END IF;
  EXECUTE v_updated;
 END IF;
END
$patch$;

REVOKE ALL ON FUNCTION private.yt_pos_create_order_with_rewards_v4(uuid,text,text,jsonb,text,uuid,text,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_pos_create_order_with_rewards_v4(uuid,text,text,jsonb,text,uuid,text,date) TO authenticated;
REVOKE ALL ON FUNCTION public.yt_pos_create_order_with_rewards_v4(uuid,text,text,jsonb,text,uuid,text,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.yt_pos_create_order_with_rewards_v4(uuid,text,text,jsonb,text,uuid,text,date) TO authenticated;
REVOKE ALL ON FUNCTION private.yt_pos_owner_backdate_requests_list() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_pos_owner_backdate_requests_list() TO authenticated;
REVOKE ALL ON FUNCTION public.yt_pos_owner_backdate_requests_list() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.yt_pos_owner_backdate_requests_list() TO authenticated;
REVOKE ALL ON FUNCTION private.yt_pos_owner_backdate_request_review(uuid,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_pos_owner_backdate_request_review(uuid,boolean,text) TO authenticated;
REVOKE ALL ON FUNCTION public.yt_pos_owner_backdate_request_review(uuid,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.yt_pos_owner_backdate_request_review(uuid,boolean,text) TO authenticated;
REVOKE ALL ON FUNCTION private.yt_pos_custom_order_bindings(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_pos_custom_order_bindings(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.yt_pos_custom_order_bindings(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.yt_pos_custom_order_bindings(uuid) TO authenticated;
