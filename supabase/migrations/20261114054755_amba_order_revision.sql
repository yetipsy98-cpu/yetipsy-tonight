-- Amba is an editable order category; preserve original lines and payment audit.
begin;
CREATE OR REPLACE FUNCTION private.yt_pos_revision_lines(p_order uuid, p_items jsonb, p_cancel boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare j jsonb;old_line public.yt_member_order_items%rowtype;p public.yt_shop_products%rowtype;
 item uuid;product uuid;qty integer;price numeric;gross numeric:=0;discount numeric:=0;line_discount numeric;units integer:=0;paid_drinks integer:=0;lines jsonb:='[]';seen uuid[]:='{}';
 sale public.yt_ambassador_pos_sales%rowtype;kind text;name text;amba_seen text[]:='{}';pax integer:=0;cap integer;session uuid;
begin
 if p_cancel then return jsonb_build_object('lines','[]'::jsonb,'gross',0,'discount',0,'net',0);end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 30 then raise exception 'invalid_order_revision';end if;
 select * into sale from public.yt_ambassador_pos_sales where order_id=p_order;
 for j in select value from jsonb_array_elements(p_items) loop
  kind:=nullif(j->>'amba_kind','');
  if kind is null and nullif(j->>'product_id','') is null and nullif(j->>'item_id','') is not null then
   select case item_name when 'Freeflow Male' then 'male' when 'Freeflow Female' then 'female' end into kind from public.yt_member_order_items where id=(j->>'item_id')::uuid and order_id=p_order and product_id is null;
  end if;
  if kind is not null then
   if sale.order_id is null or kind not in ('male','female') or kind=any(amba_seen) or nullif(j->>'product_id','') is not null then raise exception 'invalid_amba_line';end if;
   if coalesce(j->>'quantity','') !~ '^[0-9]{1,3}$' then raise exception 'invalid_quantity';end if;
   qty:=(j->>'quantity')::integer;
   if qty not between 1 and 500 then raise exception 'invalid_quantity';end if;
   name:=case kind when 'male' then 'Freeflow Male' else 'Freeflow Female' end;
   item:=null;old_line:=null;
   if nullif(j->>'item_id','') is not null then
    item:=(j->>'item_id')::uuid;select * into old_line from public.yt_member_order_items where id=item and order_id=p_order;
    if not found or item=any(seen) then raise exception 'invalid_order_line';end if;seen:=array_append(seen,item);
    if old_line.product_id is not null or old_line.item_name<>name then item:=null;end if;
   end if;
   price:=case kind when 'male' then sale.male_price else sale.female_price end;
   if j ? 'unit_price_rm' then
    if coalesce(j->>'unit_price_rm','') !~ '^[0-9]{1,4}(\.[0-9]{1,2})?$' then raise exception 'invalid_revision_price';end if;
    price:=(j->>'unit_price_rm')::numeric;
   end if;
   if price not between 0 and 5000 then raise exception 'invalid_revision_price';end if;
   amba_seen:=array_append(amba_seen,kind);pax:=pax+qty;gross:=gross+qty*price;
   if gross>100000 or pax>500 then raise exception 'order_too_large';end if;
   lines:=lines||jsonb_build_array(jsonb_build_object('item_id',item,'product_id',null,'amba_kind',kind,'name',name,'quantity',qty,'unit_price_rm',price,'discount_rm',0,'is_drink',false,'series_id',null));
   continue;
  end if;
  if coalesce(j->>'product_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or coalesce(j->>'quantity','') !~ '^[0-9]{1,2}$' then raise exception 'invalid_order_line';end if;
  product:=(j->>'product_id')::uuid;qty:=(j->>'quantity')::integer;
  if qty not between 1 and 20 then raise exception 'invalid_quantity';end if;
  item:=null;old_line:=null;
  if nullif(j->>'item_id','') is not null then
   item:=(j->>'item_id')::uuid;
   select * into old_line from public.yt_member_order_items where id=item and order_id=p_order;
   if not found or item=any(seen) then raise exception 'invalid_order_line';end if;seen:=array_append(seen,item);
  end if;
  select * into p from public.yt_shop_products where id=product for share;
  if not found or (not p.active and product is distinct from old_line.product_id) then raise exception 'product_unavailable';end if;
  -- A different product is a new line. Retire the original line in apply, retaining its immutable snapshot and benefit history.
  if old_line.id is not null and product is distinct from old_line.product_id then item:=null;end if;
  price:=case when product=old_line.product_id then old_line.unit_price_rm else p.price_rm end;
  if j ? 'unit_price_rm' then
   if coalesce(j->>'unit_price_rm','') !~ '^[0-9]{1,4}(\.[0-9]{1,2})?$' then raise exception 'invalid_revision_price';end if;
   price:=(j->>'unit_price_rm')::numeric;
  end if;
  if price not between 0 and 5000 then raise exception 'invalid_revision_price';end if;
  select coalesce(sum(least(u.reward_discount_rm,price)),0),count(*) filter(where price>u.reward_discount_rm)
  into line_discount,paid_drinks from public.yt_pos_item_units u where u.order_item_id=item and u.unit_number<=qty;
  gross:=gross+qty*price;discount:=discount+line_discount;units:=units+qty;
  if gross>100000 or units>80 then raise exception 'order_too_large';end if;
  lines:=lines||jsonb_build_array(jsonb_build_object('item_id',item,'product_id',product,'name',case when product=old_line.product_id then old_line.item_name else p.title end,
   'quantity',qty,'unit_price_rm',price,'discount_rm',line_discount,'is_drink',case when product=old_line.product_id then old_line.is_drink_at_order else p.is_drink end,'series_id',case when product=old_line.product_id then old_line.series_id_at_order else p.series_id end));
 end loop;
 if sale.order_id is not null then
  if pax<1 then raise exception 'amba_person_required';end if;
  select id into session from public.yt_freeflow_sessions where order_id=p_order for update;
  if session is not null then
   select greatest((select count(*) from public.yt_freeflow_members where session_id=session),(select count(*) from public.yt_freeflow_requests r join public.yt_freeflow_members m on m.id=r.member_id where m.session_id=session and r.status='pending')) into cap;
   if pax<cap then raise exception 'amba_capacity_in_use';end if;
  end if;
 end if;
 if discount>0 and not exists(select 1 from jsonb_array_elements(lines) l where (l->>'is_drink')::boolean and (l->>'quantity')::integer*(l->>'unit_price_rm')::numeric>(l->>'discount_rm')::numeric) then raise exception 'minimum_one_paid_drink';end if;
 return jsonb_build_object('lines',lines,'gross',gross,'discount',discount,'net',greatest(0,gross-discount));
end $function$;


-- Internal only: recompute the Amba entitlement and commission from the revised
-- source lines. Actual payment entries are never created or changed here.
create or replace function private.yt_pos_amba_revision_sync(p_order uuid,p_cancel boolean default false) returns void
language plpgsql set search_path='' as $$
declare s public.yt_ambassador_pos_sales%rowtype;o public.yt_member_orders%rowtype;
 male integer;female integer;mp numeric;fp numeric;received numeric;earned numeric;old_state jsonb;new_state jsonb;
begin
 select * into s from public.yt_ambassador_pos_sales where order_id=p_order for update;
 if not found then return;end if;
 select * into o from public.yt_member_orders where id=p_order;
 old_state:=to_jsonb(s)||jsonb_build_object('checkin',(select to_jsonb(c) from public.yt_ambassador_checkins c where request_id=p_order));
 if not p_cancel then
  select coalesce(sum(quantity) filter(where item_name='Freeflow Male'),0),coalesce(sum(quantity) filter(where item_name='Freeflow Female'),0),
   max(unit_price_rm) filter(where item_name='Freeflow Male'),max(unit_price_rm) filter(where item_name='Freeflow Female')
  into male,female,mp,fp from public.yt_member_order_items where order_id=p_order and product_id is null and quantity>0 and item_name in('Freeflow Male','Freeflow Female');
  update public.yt_ambassador_pos_sales set male_count=male,female_count=female,male_price=coalesce(mp,s.male_price),female_price=coalesce(fp,s.female_price)
   where order_id=p_order returning * into s;
  update public.yt_freeflow_sessions set capacity=male+female,table_label=coalesce(o.table_label,''),business_day=coalesce(o.pos_business_day,s.business_day) where order_id=p_order;
 else
  update public.yt_freeflow_sessions set status='closed',bind_token=null,token_expires_at=null where order_id=p_order;
 end if;
 received:=greatest(0,private.yt_pos_received(p_order)-(select coalesce(sum(quantity*unit_price_rm),0) from public.yt_member_order_items where order_id=p_order and item_name not in('Freeflow Male','Freeflow Female')));
 earned:=case when p_cancel then 0 else least(o.amount_rm,s.male_count*s.male_price+s.female_count*s.female_price,received) end;
 update public.yt_ambassador_checkins set male_count=s.male_count,female_count=s.female_count,male_price=s.male_price,female_price=s.female_price,
  sales=earned,commission_amount=round(earned*s.commission_rate/100,2) where request_id=p_order;
 -- Zero accrual has no ledger row (the ledger requires a positive commission).
 -- Before/after values, including zero, are preserved in audit history below.
 delete from public.yt_ambassador_ledger l using public.yt_ambassador_checkins c where c.request_id=p_order and l.checkin_id=c.id and l.entry_type='commission' and c.commission_amount=0;
 insert into public.yt_ambassador_ledger(ambassador_id,checkin_id,entry_type,amount,created_by,business_day,note)
 select c.ambassador_id,c.id,'commission',c.commission_amount,auth.uid(),c.business_day,'Amba 改单／实际款项同步' from public.yt_ambassador_checkins c
 where c.request_id=p_order and c.commission_amount>0 on conflict(checkin_id) do update set amount=excluded.amount;
 new_state:=to_jsonb(s)||jsonb_build_object('checkin',(select to_jsonb(c) from public.yt_ambassador_checkins c where request_id=p_order));
 if old_state is distinct from new_state then
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'amba.revision_sync','pos_order',p_order,jsonb_build_object('before',old_state,'after',new_state,'cancel',p_cancel));
 end if;
end$$;
revoke all on function private.yt_pos_amba_revision_sync(uuid,boolean) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.yt_pos_owner_revision_apply(p_order uuid, p_items jsonb, p_reason text, p_table text, p_note text, p_expected_updated timestamp with time zone, p_request uuid, p_revoke boolean DEFAULT false, p_cancel boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_member_orders%rowtype;old jsonb;r jsonb;j jsonb;item uuid;idx integer;keep uuid[]:='{}';received numeric;balance numeric;payload jsonb;done public.yt_pos_order_revisions%rowtype;after_state jsonb;benefits jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_order is null or p_request is null or p_expected_updated is null or p_revoke is null or p_cancel is null or length(btrim(coalesce(p_reason,''))) not between 3 and 300 or length(coalesce(p_table,''))>32 or length(coalesce(p_note,''))>600 then raise exception 'invalid_order_revision';end if;
 payload:=jsonb_build_object('order',p_order,'items',p_items,'reason',p_reason,'table',p_table,'note',p_note,'expected',p_expected_updated,'revoke',p_revoke,'cancel',p_cancel);
 perform pg_advisory_xact_lock(781943081);
 perform 1 from public.yt_freeflow_sessions where order_id=p_order for update;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 select * into done from public.yt_pos_order_revisions where request_id=p_request;
 if found then if done.request_payload<>payload then raise exception 'request_conflict';end if;return done.after_state||jsonb_build_object('ok',true,'retried',true);end if;
 if v.status in ('cancelled','refunded') then raise exception 'order_not_editable';end if;
 if v.updated_at<>p_expected_updated then raise exception 'order_changed_reload';end if;
 perform pg_advisory_xact_lock(781943080);
 if exists(select 1 from public.yt_pos_reward_holds where order_id=p_order and state in ('ready','reserved')) and not p_cancel then raise exception 'release_coupon_before_edit';end if;
 r:=private.yt_pos_revision_lines(p_order,p_items,p_cancel);received:=private.yt_pos_received(p_order);
 old:=to_jsonb(v)||jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(i) order by id),'[]') from public.yt_member_order_items i where order_id=p_order),'benefits',private.yt_pos_order_benefits(p_order),'received_rm',received);
 if p_revoke then benefits:=private.yt_pos_revoke_order_benefits(p_order);end if;
 if p_cancel then
  update public.yt_pos_reward_holds set state='released',updated_at=clock_timestamp() where order_id=p_order and state in ('ready','reserved');
  update public.yt_pos_preorder_holds set state='released',updated_at=clock_timestamp() where attached_order_id=p_order and state='attached';
 end if;
 for j in select value from jsonb_array_elements(r->'lines') loop
  item:=nullif(j->>'item_id','')::uuid;
  if item is null then
   insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
   values(p_order,(j->>'product_id')::uuid,j->>'name',(j->>'quantity')::integer,(j->>'unit_price_rm')::numeric) returning id into item;
  else
   update public.yt_member_order_items set product_id=(j->>'product_id')::uuid,item_name=j->>'name',quantity=(j->>'quantity')::integer,unit_price_rm=(j->>'unit_price_rm')::numeric,
   is_drink_at_order=(j->>'is_drink')::boolean,series_id_at_order=nullif(j->>'series_id','')::uuid where id=item;
  end if;
  keep:=array_append(keep,item);
  update public.yt_pos_item_units set retired=unit_number>(j->>'quantity')::integer,
   reward_discount_rm=case when unit_number<=(j->>'quantity')::integer then least(reward_discount_rm,(j->>'unit_price_rm')::numeric) else reward_discount_rm end where order_item_id=item;
  for idx in 1..(j->>'quantity')::integer loop insert into public.yt_pos_item_units(order_item_id,unit_number) values(item,idx) on conflict do nothing;end loop;
 end loop;
 update public.yt_member_order_items set quantity=0 where order_id=p_order and not(id=any(keep));
 update public.yt_pos_item_units u set retired=true from public.yt_member_order_items i where i.id=u.order_item_id and i.order_id=p_order and i.quantity=0;
 balance:=(r->>'net')::numeric-received;
 update public.yt_member_orders set amount_rm=(r->>'net')::numeric,table_label=nullif(btrim(coalesce(p_table,'')),''),notes=nullif(btrim(coalesce(p_note,'')),''),revision=v.revision+1,
 cancel_after_refund=p_cancel,settlement_due_since=case when v.payment_status='paid' and balance<>0 then coalesce(v.settlement_due_since,clock_timestamp()) else null end,
 status=case when p_cancel and v.payment_status='unpaid' then 'cancelled' when p_cancel and balance=0 then 'refunded' else v.status end,
 payment_status=case when p_cancel and v.payment_status='paid' and balance=0 then 'refunded' else v.payment_status end,updated_at=clock_timestamp() where id=p_order returning * into v;
 perform private.yt_pos_amba_revision_sync(p_order,p_cancel);
 if p_cancel then update public.yt_pos_order_chits set status='cancelled' where order_id=p_order;end if;
 after_state:=to_jsonb(v)||jsonb_build_object('items',r->'lines','received_rm',received,'balance_rm',case when v.payment_status='unpaid' then v.amount_rm else balance end,'revoked_benefits',benefits);
 insert into public.yt_pos_order_revisions(order_id,revision,request_id,request_payload,reason,actor_id,before_state,after_state,revoke_benefits)
 values(p_order,v.revision,p_request,payload,p_reason,auth.uid(),old,after_state,p_revoke);
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note) values(p_order,auth.uid(),'edited','cashier',p_reason);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.owner_revision','pos_order',p_order,jsonb_build_object('revision',v.revision,'reason',p_reason,'before_amount',old->'amount_rm','after_amount',v.amount_rm,'balance_rm',balance,'revoke_benefits',p_revoke,'cancel',p_cancel));
 return after_state||jsonb_build_object('ok',true);
end $function$;

CREATE OR REPLACE FUNCTION private.yt_pos_owner_order_context(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b jsonb;
begin
 if not (private.yt_work_owner() or private.yt_pos_work_cashier()) then raise exception 'owner_only';end if;
 b:=private.yt_pos_bill_v8(p_order);
 return b||jsonb_build_object('amba',(select jsonb_build_object('male_count',male_count,'female_count',female_count,'male_price',male_price,'female_price',female_price) from public.yt_ambassador_pos_sales where order_id=p_order),'items',coalesce((select jsonb_agg(jsonb_build_object('id',id,'product_id',product_id,'name',item_name,'amba_kind',case when product_id is null then case item_name when 'Freeflow Male' then 'male' when 'Freeflow Female' then 'female' end end,'quantity',quantity,'price_rm',unit_price_rm) order by id) from public.yt_member_order_items where order_id=p_order and quantity>0),'[]'::jsonb),
 'benefits',private.yt_pos_order_benefits(p_order),'received_rm',private.yt_pos_received(p_order),
 'revisions',coalesce((select jsonb_agg(to_jsonb(x) order by x.revision desc) from(select revision,reason,created_at,revoke_benefits,before_state->'amount_rm' before_amount,after_state->'amount_rm' after_amount,coalesce(before_state->>'business_day',before_state->>'pos_business_day',private.yt_business_day((before_state->>'created_at')::timestamptz)::text) before_business_day,coalesce(after_state->>'business_day',after_state->>'pos_business_day',private.yt_business_day((after_state->>'created_at')::timestamptz)::text) after_business_day from public.yt_pos_order_revisions where order_id=p_order order by revision desc limit 20)x),'[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION private.yt_pos_adjustment_pay(p_order uuid, p_amount numeric, p_method text, p_note text, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_member_orders%rowtype;e public.yt_pos_payment_entries%rowtype;balance numeric;entry_method text;ff_received numeric;
begin
 if not private.yt_work_owner() and not (private.yt_pos_work_cashier() and p_amount>0 and exists(select 1 from public.yt_ambassador_pos_sales where order_id=p_order) and exists(select 1 from public.audit_logs where action='freeflow.pax_add' and entity_id=p_order)) then raise exception 'owner_only';end if;
 if p_request is null or p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount=0 or abs(p_amount)>100000 or p_amount<>round(p_amount,2) or p_method is null or p_method not in ('foodcourt','cash','duitnow','card','bank_transfer','other') or length(btrim(coalesce(p_note,''))) not between 2 and 300 then raise exception 'invalid_adjustment_payment';end if;
 perform 1 from public.yt_freeflow_sessions where order_id=p_order for update;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 entry_method:=case when exists(select 1 from public.yt_ambassador_pos_sales where order_id=p_order) then 'AB_'||case p_method when 'cash' then 'Cash' when 'duitnow' then 'DuitNow' when 'card' then 'Card' when 'bank_transfer' then 'Bank_Transfer' when 'foodcourt' then 'Foodcourt' else 'Other' end else p_method end;
 select * into e from public.yt_pos_payment_entries where request_id=p_request;
 if found then if e.order_id<>p_order or e.amount_rm<>p_amount or (e.method<>entry_method and e.method<>p_method) or coalesce(e.note,'')<>p_note then raise exception 'request_conflict';end if;return private.yt_pos_owner_order_context(p_order);end if;
 if v.payment_status<>'paid' then raise exception 'order_not_paid';end if;
 balance:=v.amount_rm-private.yt_pos_received(p_order);
 if balance=0 or sign(balance)<>sign(p_amount) or abs(p_amount)>abs(balance) then raise exception 'adjustment_exceeds_balance';end if;
 perform pg_advisory_xact_lock(781943080);
 insert into public.yt_pos_payment_entries(order_id,request_id,method,amount_rm,kind,received_at,business_day,actor_id,note)
 values(p_order,p_request,entry_method,p_amount,case when p_amount<0 then 'refund' else 'adjustment' end,clock_timestamp(),coalesce(v.pos_business_day,(select sale.business_day from public.yt_pos_payment_entries sale where sale.order_id=v.id and sale.kind='sale' order by sale.received_at,sale.id limit 1),private.yt_business_day(v.created_at)),auth.uid(),p_note);
 balance:=v.amount_rm-private.yt_pos_received(p_order);
 update public.yt_member_orders set settlement_due_since=case when balance=0 then null else coalesce(settlement_due_since,clock_timestamp()) end,
 payment_status=case when cancel_after_refund and balance=0 then 'refunded' else payment_status end,
 status=case when cancel_after_refund and balance=0 then 'refunded' else status end,updated_at=clock_timestamp() where id=p_order;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.adjustment_payment','pos_order',p_order,jsonb_build_object('amount_rm',p_amount,'method',p_method,'note',p_note,'remaining',balance));
 perform private.yt_pos_amba_revision_sync(p_order,v.cancel_after_refund);
 return private.yt_pos_owner_order_context(p_order);
end $function$;

CREATE OR REPLACE FUNCTION private.yt_pos_owner_revision_apply_v3(p_order uuid, p_items jsonb, p_reason text, p_table text, p_note text, p_expected_updated timestamp with time zone, p_request uuid, p_revoke boolean, p_cancel boolean, p_payment_method text, p_business_day date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.yt_member_orders%rowtype;done public.yt_pos_order_revisions%rowtype;payload jsonb;result jsonb;
 old_day date;new_day date;affected date[];new_updated timestamptz;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_request is null or p_order is null then raise exception 'invalid_order_revision';end if;
 payload:=jsonb_build_object('order',p_order,'items',p_items,'reason',p_reason,'table',p_table,'note',p_note,'expected',p_expected_updated,'revoke',p_revoke,'cancel',p_cancel,'payment_method',p_payment_method,'business_day',p_business_day);
 perform pg_advisory_xact_lock(781943081);
 perform 1 from public.yt_freeflow_sessions where order_id=p_order for update;
 select * into o from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 select * into done from public.yt_pos_order_revisions where request_id=p_request;
 if found then
  if done.order_id<>p_order or done.actor_id is distinct from auth.uid() or done.request_payload is distinct from payload then raise exception 'request_conflict';end if;
  return done.after_state||jsonb_build_object('ok',true,'retried',true);
 end if;
 old_day:=coalesce(o.pos_business_day,private.yt_business_day(o.created_at));
 new_day:=coalesce(p_business_day,old_day);
 if new_day<'2020-01-01' or new_day>private.yt_business_day(clock_timestamp()) then raise exception 'invalid_business_day';end if;
 select array_agg(distinct d) into affected from (
  select business_day d from public.yt_pos_payment_entries where order_id=p_order
  union select old_day union select new_day)x;
 result:=private.yt_pos_owner_revision_apply_v2(p_order,p_items,p_reason,p_table,p_note,p_expected_updated,p_request,p_revoke,p_cancel,p_payment_method);
 perform pg_advisory_xact_lock(781943080);
 update public.yt_member_orders set pos_business_day=new_day,
  backdate_approval_status=case when backdate_approval_status='pending' then 'approved' else backdate_approval_status end,
  updated_at=clock_timestamp() where id=p_order returning updated_at into new_updated;
 update public.yt_pos_order_backdate_requests set status=case when requested_business_day=new_day then 'approved' else 'rejected' end,
  reviewer_id=auth.uid(),reviewed_at=clock_timestamp(),review_note='Owner 改单指定营业日 '||new_day::text||'；'||p_reason
  where order_id=p_order and status='pending';
 update public.yt_pos_payment_entries set business_day=new_day where order_id=p_order and business_day is distinct from new_day;
 update public.yt_freeflow_sessions set business_day=new_day where order_id=p_order and business_day is distinct from new_day;
 -- Keep Ambassador sales and their commission accrual on the same accounting day.
 update public.yt_ambassador_pos_sales set business_day=new_day where order_id=p_order and business_day is distinct from new_day;
 update public.yt_ambassador_checkins set business_day=new_day where request_id=p_order and business_day is distinct from new_day;
 update public.yt_ambassador_ledger l set business_day=new_day from public.yt_ambassador_checkins c
 where c.id=l.checkin_id and c.request_id=p_order and l.entry_type='commission' and l.business_day is distinct from new_day;
 if old_day is distinct from new_day or exists(select 1 from unnest(affected) d where d<>new_day) then
  update public.yt_pos_day_closings set state='reopened',reopened_at=clock_timestamp(),reopened_by=auth.uid(),reopen_reason='订单 '||o.order_no||' 营业日更正：'||old_day::text||' → '||new_day::text
  where business_day=any(affected) and state='closed';
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.order_business_day_corrected','pos_order',p_order,jsonb_build_object('request',p_request,'before_day',old_day,'after_day',new_day,'reason',p_reason,'receipt_timestamps_preserved',true));
 end if;
 result:=result||jsonb_build_object('pos_business_day',new_day,'business_day',new_day,'updated_at',new_updated);
 update public.yt_pos_order_revisions set request_payload=payload,
  before_state=before_state||jsonb_build_object('business_day',old_day),after_state=after_state||result
  where request_id=p_request;
 return result;
end $function$;

commit;
