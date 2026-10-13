-- Mixed package + ordinary drinks KDS routing, no QR double issuance, safe retries.
CREATE OR REPLACE FUNCTION private.yt_pos_checkout_with_prep(p_order uuid, p_method text, p_preps jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.yt_member_orders%rowtype;quote jsonb;line jsonb;rows jsonb;plan jsonb:='[]'::jsonb; v_item record;
 sel jsonb;v_total int;v_capacity int;prepared jsonb:='[]'::jsonb;result jsonb;box public.yt_store_boxes%rowtype;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if p_order is null or p_preps is null or jsonb_typeof(p_preps)<>'array' or jsonb_array_length(p_preps)>50 then raise exception 'invalid_store_box_selection';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into o from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found or o.payment_status<>'unpaid' then raise exception 'order_not_ready_for_checkout';end if;
 quote:=private.yt_store_box_checkout_prep_quote(p_order);
 if not (quote->>'can_prepare')::boolean then raise exception 'order_not_served';end if;
 rows:=quote->'items';
 if exists(select 1 from jsonb_array_elements(p_preps) z
   where not exists(select 1 from jsonb_array_elements(rows) x where x->>'item_id'=z->>'item_id'))
 then raise exception 'store_box_item_not_in_order';end if;
 if exists(select 1 from jsonb_array_elements(p_preps) z
    group by z->>'item_id' having count(*)>1) then raise exception 'duplicate_store_box_item';end if;
 for v_item in select value item from jsonb_array_elements(rows) loop
  select value into line from jsonb_array_elements(p_preps) where value->>'item_id'=v_item.item->>'item_id';
  if line is null then
   -- Challenge must always get exactly one first cup, even if a stale frontend omits this item.
   sel:=case when v_item.item->>'mode'='challenge'
     then jsonb_build_array(jsonb_build_object('key',v_item.item->'available'->0->>'key','quantity',1))
     else '[]'::jsonb end;
  else
   sel:=coalesce(line->'selections','[]'::jsonb);
  end if;
  if jsonb_typeof(sel)<>'array' or jsonb_array_length(sel)>20 then raise exception 'invalid_store_box_selection';end if;
  select coalesce(sum((x->>'quantity')::integer),0) into v_total from jsonb_array_elements(sel) x;
  if v_item.item->>'mode'='challenge' and v_total<>1 then raise exception 'challenge_one_cup_only';end if;
  if v_total<0 or v_total>99 or v_total>(v_item.item->>'capacity')::int then raise exception 'store_box_quantity_unavailable';end if;
  plan:=plan||jsonb_build_array(jsonb_build_object('item_id',v_item.item->>'item_id','quantity',v_total,'selections',sel));
 end loop;
 -- Original payment and existing reward/Moon redemption triggers remain authoritative.
 result:=private.yt_pos_action(p_order,'paid',null,p_method);
 for v_item in select value item from jsonb_array_elements(plan) loop
  select * into box from public.yt_store_boxes where source_order_item_id=(v_item.item->>'item_id')::uuid for update;
  if not found then
   -- Mixed orders remain KDS-confirmed for ordinary drinks. Create a cashier
   -- managed package balance with no initial guest QR.
   insert into public.yt_store_boxes(source_order_id,source_order_item_id,product_id,customer_id,
    name,mode,unit_label,total_units,request_limit,expiry_days,selection_mode,components,
    completion_reward_id,game_pass_enabled,table_label,created_by,cashier_managed)
   select i.order_id,i.id,i.product_id,o.customer_id,i.item_name,r.mode,r.unit_label,
    i.quantity*r.total_units,r.request_limit,r.expiry_days,r.selection_mode,
    case when jsonb_array_length(r.components)>0 then
      (select jsonb_agg(jsonb_build_object('key',c->>'key','name',c->>'name',
       'total_units',(c->>'quantity')::integer*i.quantity,'served_units',0) order by n)
       from jsonb_array_elements(r.components) with ordinality component(c,n))
     else jsonb_build_array(jsonb_build_object('key','default','name',i.item_name,
       'total_units',i.quantity*r.total_units,'served_units',0)) end,
    null,false,o.table_label,auth.uid(),true
   from public.yt_member_order_items i
   join public.yt_store_box_product_rules r on r.product_id=i.product_id and r.active
   where i.id=(v_item.item->>'item_id')::uuid and i.order_id=p_order
   on conflict(source_order_item_id) do nothing;
   select * into box from public.yt_store_boxes
     where source_order_item_id=(v_item.item->>'item_id')::uuid for update;
   if not found then raise exception 'store_box_not_created';end if;
  end if;
  if box.customer_id is not null or box.served_units>0 then raise exception 'store_box_already_claimed';end if;
  update public.yt_store_boxes set cashier_managed=true,
    storage_expires_at=coalesce(storage_expires_at,clock_timestamp()+make_interval(days=>expiry_days)),
    updated_at=clock_timestamp()
  where id=box.id;
  -- Cashier controls initial cups and remaining balance; no forced guest QR.
  update public.yt_store_box_claims set status='cancelled',claim_token=null,cancelled_by=auth.uid(),
   cancelled_at=clock_timestamp(),cancel_reason='Cashier-managed prep; customer QR not required'
  where box_id=box.id and status='issued';
  if (v_item.item->>'quantity')::int>0 then
   prepared:=prepared||jsonb_build_array(private.yt_store_box_cashier_request(
    box.id,v_item.item->'selections',gen_random_uuid(),true));
  end if;
 end loop;
 return result||jsonb_build_object('store_box_claims','[]'::jsonb,'cashier_prepared',prepared,
  'cashier_managed_packages',jsonb_array_length(plan));
end $function$
;

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
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if p_box is null or p_request is null or p_selections is null or jsonb_typeof(p_selections)<>'array'
  or jsonb_array_length(p_selections)<1 or jsonb_array_length(p_selections)>20 then raise exception 'invalid_store_box_selection';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into r from public.yt_store_box_requests where client_request_id=p_request for update;
 if found then
  if r.box_id<>p_box or not (r.selections @> p_selections and jsonb_array_length(r.selections)=jsonb_array_length(p_selections)) then raise exception 'request_conflict';end if;
  return jsonb_build_object('request_id',r.id,'quantity',r.quantity,'idempotent',true);
 end if;
 select * into b from public.yt_store_boxes where id=p_box for update;
 if not found or not b.cashier_managed or b.customer_id is not null
 or b.status not in('unclaimed','active') or b.storage_expires_at<=clock_timestamp()
 then raise exception 'store_box_not_available';end if;
 if exists(select 1 from public.yt_store_box_requests
    where box_id=p_box and status in('pending','accepted','preparing')) then raise exception 'store_box_request_already_active';end if;
 for entry in select value from jsonb_array_elements(p_selections) loop
  v_key:=nullif(btrim(entry->>'key'),'');
  if v_key is null or coalesce(entry->>'quantity','')!~'^[0-9]{1,2}$' then raise exception 'invalid_store_box_selection';end if;
  v_qty:=(entry->>'quantity')::integer;
  if v_qty<1 then raise exception 'invalid_store_box_selection';end if;
  if exists(select 1 from jsonb_array_elements(sel) x where x->>'key'=v_key) then raise exception 'duplicate_store_box_component';end if;
  select value into candidate from jsonb_array_elements(b.components) where value->>'key'=v_key;
  if candidate is null or (candidate->>'total_units')::integer-(candidate->>'served_units')::integer<v_qty then
   raise exception 'store_box_component_unavailable';end if;
  v_name:=candidate->>'name';
  sel:=sel||jsonb_build_array(jsonb_build_object('key',v_key,'name',v_name,'quantity',v_qty));
  total_qty:=total_qty+v_qty;
 end loop;
 if total_qty<1 or total_qty>99 or total_qty>b.total_units-b.served_units then raise exception 'store_box_quantity_unavailable';end if;
 if b.mode='challenge' and total_qty<>1 then raise exception 'challenge_one_cup_only';end if;
 insert into public.yt_store_box_requests(box_id,customer_id,quantity,component_key,component_name,
  selections,client_request_id,table_label,expires_at)
 values(b.id,null,total_qty,sel->0->>'key',sel->0->>'name',sel,p_request,b.table_label,clock_timestamp()+interval '8 hours')
 returning * into r;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,actor_id,metadata)
 values(b.id,r.id,'drink_requested',total_qty,actor,jsonb_build_object('source',case when p_initial then 'cashier_checkout' else 'cashier_direct' end,'selections',sel));
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(actor,'store_box.cashier_prep','store_box',b.id,jsonb_build_object('request_id',r.id,'quantity',total_qty,'initial',p_initial));
 return jsonb_build_object('request_id',r.id,'quantity',total_qty,'selections',sel,'idempotent',false);
end $function$
;

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
  if not v_cashier then raise exception 'cashier_only';end if;
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
end $function$
;

CREATE OR REPLACE FUNCTION private.yt_pos_orders(p_scope text DEFAULT 'active'::text, p_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_result jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_scope not in ('active','pending','paid','all','mine') or p_limit is null or p_limit<1 or p_limit>150 then raise exception 'invalid_filter';end if;
 if p_scope='pending' and not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc),'[]'::jsonb) into v_result from(
  select x.id,x.order_no,x.table_label,x.notes,x.status,x.payment_status,x.checkout_mode,x.amount_rm,x.revision,x.settlement_due_since,
   private.yt_pos_received(x.id) received_rm,case when x.payment_status in ('paid','refunded') then x.amount_rm-private.yt_pos_received(x.id) else x.amount_rm end balance_rm,
   x.created_at,x.updated_at,x.created_by,wa.username created_by_name,x.accepted_at,x.fulfilled_at,x.paid_at,x.payment_method,
   coalesce((select e.source from public.yt_pos_order_events e where e.order_id=x.id and e.event_type='created' order by e.created_at limit 1),'staff') created_channel,
   exists(select 1 from public.yt_pos_order_chits chit where chit.order_id=x.id and chit.status='queued') has_chit,
   private.yt_store_box_order_only(x.id) store_box_only,
   coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'price_rm',i.unit_price_rm,'store_box_item',exists(select 1 from public.yt_store_box_product_rules sr where sr.product_id=i.product_id and sr.active)) order by i.item_name)
    from public.yt_member_order_items i where i.order_id=x.id and i.quantity>0),'[]'::jsonb) items
  from public.yt_member_orders x left join public.work_accounts wa on wa.auth_user_id=x.created_by
  where x.source='future_pos' and ((p_scope='active' and ((x.status in ('pending','confirmed') and x.payment_status in ('unpaid','paid')) or (x.status='fulfilled' and x.payment_status='unpaid')))
   or (p_scope='pending' and x.status='pending') or (p_scope='paid' and x.payment_status in ('paid','refunded')) or p_scope='all' or (p_scope='mine' and x.created_by=auth.uid()))
  order by x.created_at desc limit p_limit
 )o;return v_result;
end $function$
;

CREATE OR REPLACE FUNCTION private.yt_pos_orders_day(p_scope text DEFAULT 'active'::text, p_day date DEFAULT NULL::date, p_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_result jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_scope not in ('active','pending','paid','all','mine') or p_limit is null or p_limit<1 or p_limit>150 then raise exception 'invalid_filter';end if;
 if p_scope='pending' and not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc),'[]'::jsonb) into v_result from(
  select x.id,x.order_no,x.table_label,x.notes,x.status,x.payment_status,x.checkout_mode,x.amount_rm,x.revision,x.settlement_due_since,
   private.yt_pos_received(x.id) received_rm,case when x.payment_status in ('paid','refunded') then x.amount_rm-private.yt_pos_received(x.id) else x.amount_rm end balance_rm,
   x.created_at,x.updated_at,x.created_by,wa.username created_by_name,x.accepted_at,x.fulfilled_at,x.paid_at,x.payment_method,
   coalesce((select e.source from public.yt_pos_order_events e where e.order_id=x.id and e.event_type='created' order by e.created_at limit 1),'staff') created_channel,
   exists(select 1 from public.yt_pos_order_chits chit where chit.order_id=x.id and chit.status='queued') has_chit,
   private.yt_store_box_order_only(x.id) store_box_only,
   coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'price_rm',i.unit_price_rm,'store_box_item',exists(select 1 from public.yt_store_box_product_rules sr where sr.product_id=i.product_id and sr.active)) order by i.item_name)
    from public.yt_member_order_items i where i.order_id=x.id and i.quantity>0),'[]'::jsonb) items
  from public.yt_member_orders x left join public.work_accounts wa on wa.auth_user_id=x.created_by
  where x.source='future_pos' and ((p_scope='active' and ((x.status in ('pending','confirmed') and x.payment_status in ('unpaid','paid')) or (x.status='fulfilled' and x.payment_status='unpaid')))
   or (p_scope='pending' and x.status='pending')
   or (p_scope='paid' and x.payment_status in ('paid','refunded') and x.paid_at>=private.yt_business_start(coalesce(p_day,private.yt_business_day(now()))) and x.paid_at<private.yt_business_start(coalesce(p_day,private.yt_business_day(now()))+1))
   or p_scope='all' or (p_scope='mine' and x.created_by=auth.uid()))
  order by case when p_scope='paid' then x.paid_at else x.created_at end desc limit p_limit
 )o;return v_result;
end $function$
;
