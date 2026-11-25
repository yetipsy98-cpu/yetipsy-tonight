-- Product-by-product manual Foodcourt reconciliation. Financial operations are
-- transactional, idempotent and deliberately separate from live POS checkout.
create table private.yt_foodcourt_checks (
 business_day date not null, product_key text not null,
 fingerprint text not null, checked_by uuid not null references auth.users(id),
 checked_at timestamptz not null default clock_timestamp(),
 primary key(business_day,product_key)
);
create index yt_foodcourt_checks_actor on private.yt_foodcourt_checks(checked_by);
create table private.yt_foodcourt_operations (
 request_id uuid primary key, actor_id uuid not null references auth.users(id),
 payload jsonb not null, result jsonb not null,
 created_at timestamptz not null default clock_timestamp()
);
create index yt_foodcourt_operations_actor on private.yt_foodcourt_operations(actor_id);
create table private.yt_foodcourt_history_orders (
 order_id uuid primary key references public.yt_member_orders(id),
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default clock_timestamp()
);
create index yt_foodcourt_history_actor on private.yt_foodcourt_history_orders(created_by);
alter table private.yt_foodcourt_checks enable row level security;
alter table private.yt_foodcourt_operations enable row level security;
alter table private.yt_foodcourt_history_orders enable row level security;
revoke all on private.yt_foodcourt_checks,private.yt_foodcourt_operations,private.yt_foodcourt_history_orders from public,anon,authenticated;

-- A historical FreeFlow product is a sale record, not newly issued access.
-- Match the exact existing trigger body so a future incompatible change fails safely.
do $$declare def text;needle text;begin
 def:=pg_get_functiondef('private.yt_ff_package_item()'::regprocedure);
 needle:='select * into rule from public.yt_freeflow_packages where product_id=new.product_id;';
 if position(needle in def)=0 then raise exception 'freeflow_package_trigger_changed';end if;
 execute replace(def,needle,'if exists(select 1 from private.yt_foodcourt_history_orders where order_id=new.order_id) then return new;end if;'||chr(10)||needle);
end$$;

-- Large historical product counts must remain editable without raising live POS limits.
do $$declare def text;needle text;begin
 def:=pg_get_functiondef('private.yt_pos_revision_lines(uuid,jsonb,boolean)'::regprocedure);
 needle:='case when exists(select 1 from public.yt_freeflow_packages where product_id=product) then 500 else 20 end';
 if position(needle in def)=0 then raise exception 'revision_quantity_definition_changed';end if;
 def:=replace(def,needle,'case when exists(select 1 from public.yt_freeflow_packages where product_id=product) or exists(select 1 from private.yt_foodcourt_history_orders where order_id=p_order) then 500 else 20 end');
 needle:='units>80';
 if position(needle in def)=0 then raise exception 'revision_units_definition_changed';end if;
 execute replace(def,needle,'units>(case when exists(select 1 from private.yt_foodcourt_history_orders where order_id=p_order) then 15000 else 80 end)');
end$$;

create function private.yt_foodcourt_rows(p_day date) returns jsonb
language sql stable security definer set search_path='' as $$
 with orders as (
  select o.*
  from public.yt_member_orders o where o.source='future_pos'
  and coalesce(o.pos_business_day,private.yt_business_day(o.created_at))=p_day
  and (o.payment_method in ('foodcourt','AB_Foodcourt','Freeflow-Foodcourt')
   or exists(select 1 from public.yt_pos_payment_entries e where e.order_id=o.id and e.kind='sale' and e.method in ('foodcourt','AB_Foodcourt','Freeflow-Foodcourt')))
  and (o.payment_status in ('paid','refunded') or o.status='cancelled')
 ), lines as (
  select coalesce(i.product_id::text,'legacy:'||i.item_name) product_key,i.product_id,i.item_name,
   i.id item_id,o.id order_id,o.order_no,o.table_label,o.updated_at,o.status,o.payment_status,o.payment_method,
   i.quantity recorded_quantity,i.unit_price_rm,
   case when o.status in ('cancelled','refunded') or o.cancel_after_refund then 0 else i.quantity end quantity
  from orders o join public.yt_member_order_items i on i.order_id=o.id
 ), grouped as (
  select product_key,product_id,max(item_name) name,sum(quantity) quantity,
   sum(quantity*unit_price_rm) gross_rm,count(distinct order_id) order_count,
   md5(jsonb_agg(to_jsonb(l) order by order_id,item_id)::text) fingerprint,
   jsonb_agg(to_jsonb(l) order by order_no,item_id) orders
  from lines l group by product_key,product_id
 ) select coalesce(jsonb_agg(to_jsonb(g)||jsonb_build_object('checked',c.fingerprint=g.fingerprint,
   'checked_at',case when c.fingerprint=g.fingerprint then c.checked_at end,
   'checked_by',case when c.fingerprint=g.fingerprint then w.username end) order by g.name),'[]'::jsonb)
 from grouped g left join private.yt_foodcourt_checks c on c.business_day=p_day and c.product_key=g.product_key
 left join public.work_accounts w on w.auth_user_id=c.checked_by;
$$;
revoke all on function private.yt_foodcourt_rows(date) from public,anon,authenticated;

create function private.yt_foodcourt_reconcile(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare d date;month_start date;month_end date;rows jsonb;item jsonb;result jsonb;
 rid uuid;v_bill public.yt_member_orders%rowtype;done private.yt_foodcourt_operations%rowtype;
 payload jsonb;reason text;before_items jsonb;after_items jsonb;
 product public.yt_shop_products%rowtype;qty integer;price numeric;total numeric;balance numeric;
 v_order uuid;item_id uuid;order_no text;v_method text;cancel_order boolean;preview jsonb;expected timestamptz;
 stamp timestamptz:=clock_timestamp();catalog jsonb;days jsonb;
begin
 if not coalesce(private.yt_pos_work_cashier(),false) then raise exception 'cashier_only';end if;
 d:=coalesce(nullif(p_data->>'day','')::date,private.yt_business_day(stamp));
 if d<'2020-01-01' or d>private.yt_business_day(stamp) then raise exception 'invalid_business_day';end if;
 if p_action='day' then
  rows:=private.yt_foodcourt_rows(d);
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.title,'price_rm',p.price_rm) order by p.sort_order,p.title),'[]') into catalog from public.yt_shop_products p where p.active and p.price_rm is not null;
  month_start:=date_trunc('month',d)::date;month_end:=least((month_start+interval '1 month'-interval '1 day')::date,private.yt_business_day(stamp));
  select coalesce(jsonb_agg(jsonb_build_object('day',x.date_key,'orders',x.orders,'quantity',x.quantity) order by x.date_key),'[]') into days from (
   select s::date as date_key,count(distinct o.id) orders,coalesce(sum(case when o.status in ('cancelled','refunded') or o.cancel_after_refund then 0 else i.quantity end),0) quantity
   from generate_series(month_start::timestamp,month_end::timestamp,interval '1 day') s
   left join public.yt_member_orders o on o.source='future_pos' and coalesce(o.pos_business_day,private.yt_business_day(o.created_at))=s::date
    and (o.payment_status in ('paid','refunded') or o.status='cancelled')
    and (o.payment_method in ('foodcourt','AB_Foodcourt','Freeflow-Foodcourt') or exists(select 1 from public.yt_pos_payment_entries e where e.order_id=o.id and e.kind='sale' and e.method in ('foodcourt','AB_Foodcourt','Freeflow-Foodcourt')))
   left join public.yt_member_order_items i on i.order_id=o.id group by s
  )x;
  return jsonb_build_object('business_day',private.yt_business_day(stamp),'day',d,'rows',rows,'catalog',catalog,'days',days,'can_edit',private.yt_work_owner());
 end if;
 if p_action='mark' then
  perform pg_advisory_xact_lock(hashtextextended('foodcourt-check:'||d::text||':'||coalesce(p_data->>'product_key',''),0));
  select value into item from jsonb_array_elements(private.yt_foodcourt_rows(d)) where value->>'product_key'=p_data->>'product_key';
  if item is null or item->>'fingerprint' is distinct from p_data->>'fingerprint' then raise exception 'order_changed_reload';end if;
  if coalesce((p_data->>'checked')::boolean,false) then
   insert into private.yt_foodcourt_checks(business_day,product_key,fingerprint,checked_by) values(d,item->>'product_key',item->>'fingerprint',auth.uid())
    on conflict(business_day,product_key) do update set fingerprint=excluded.fingerprint,checked_by=excluded.checked_by,checked_at=clock_timestamp();
  else delete from private.yt_foodcourt_checks where business_day=d and product_key=item->>'product_key';end if;
  return jsonb_build_object('ok',true);
 end if;
 if p_action='orders' then
  -- Also find a sale accidentally entered under another payment method.
  select coalesce(jsonb_agg(x.order_row order by x.created_at desc),'[]') into rows from (
   select o.created_at,jsonb_build_object('id',o.id,'order_no',o.order_no,'table_label',o.table_label,'amount_rm',o.amount_rm,'payment_method',o.payment_method,'status',o.status,'payment_status',o.payment_status) as order_row
   from public.yt_member_orders o where o.source='future_pos' and coalesce(o.pos_business_day,private.yt_business_day(o.created_at))=d
   and (coalesce(p_data->>'search','')='' or position(lower(p_data->>'search') in lower(coalesce(o.order_no,'')||' '||coalesce(o.table_label,'')))>0)
   order by o.created_at desc limit 100
  )x;return rows;
 end if;
 v_order:=nullif(p_data->>'order_id','')::uuid;
 if p_action='preview' then
  if not coalesce(private.yt_work_owner(),false) then raise exception 'owner_only';end if;
  return private.yt_pos_owner_revision_preview(v_order,p_data->'items',coalesce((p_data->>'cancel')::boolean,false));
 end if;
 if p_action='context' then
  select * into v_bill from public.yt_member_orders where id=v_order and source='future_pos';
  if not found or coalesce(v_bill.pos_business_day,private.yt_business_day(v_bill.created_at))<>d then raise exception 'order_not_found';end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'unit_price_rm',i.unit_price_rm,
   'amba_kind',case when i.product_id is null then case i.item_name when 'Freeflow Male' then 'male' when 'Freeflow Female' then 'female' end end) order by i.id),'[]') into rows
   from public.yt_member_order_items i where i.order_id=v_bill.id and i.quantity>0;
  return to_jsonb(v_bill)||jsonb_build_object('items',rows,'received_rm',private.yt_pos_received(v_bill.id),
   'revisions',(select coalesce(jsonb_agg(jsonb_build_object('created_at',r.created_at,'actor_name',coalesce((select w.username from public.work_accounts w where w.auth_user_id=r.actor_id),'Owner'),'reason',r.reason,'before_state',r.before_state,'after_state',r.after_state) order by r.created_at desc),'[]') from public.yt_pos_order_revisions r where r.order_id=v_bill.id));
 end if;
 if p_action not in ('supplement','revise') or p_action is null then raise exception 'invalid_action';end if;
 if not coalesce(private.yt_work_owner(),false) then raise exception 'owner_only';end if;
 rid:=nullif(p_data->>'request_id','')::uuid;if rid is null then raise exception 'request_required';end if;
 payload:=jsonb_build_object('action',p_action,'data',p_data);
 -- Serialize request retries before taking the standard revision/day-close locks.
 perform pg_advisory_xact_lock(hashtextextended('foodcourt-operation:'||rid::text,0));
 select * into done from private.yt_foodcourt_operations where request_id=rid;
 if found then
  if done.actor_id is distinct from auth.uid() or done.payload is distinct from payload then raise exception 'request_conflict';end if;
  return done.result||jsonb_build_object('retried',true);
 end if;
 perform pg_advisory_xact_lock(781943081);
 reason:='Foodcourt 对账 '||d::text||' · '||case when p_action='supplement' then '补录商品' else '修正原单' end;
 if p_action='supplement' then
  if coalesce(p_data->>'quantity','') !~ '^[0-9]{1,3}$' or coalesce(p_data->>'unit_price_rm','') !~ '^[0-9]{1,4}(\.[0-9]{1,2})?$' then raise exception 'invalid_order_line';end if;
  qty:=(p_data->>'quantity')::integer;price:=(p_data->>'unit_price_rm')::numeric;
  if qty not between 1 and 500 or price not between 0.01 and 5000 or qty*price>100000 then raise exception 'invalid_order_line';end if;
  select * into product from public.yt_shop_products where id=(p_data->>'product_id')::uuid and active for share;
  if not found or product.price_rm is null then raise exception 'product_unavailable';end if;
  if nullif(p_data->>'expected_price','')::numeric is distinct from product.price_rm then raise exception 'product_price_changed';end if;
  total:=qty*price;
  order_no:='YT'||to_char(stamp at time zone 'Asia/Kuala_Lumpur','YYMMDD')||'-'||lpad(nextval('public.yt_pos_order_serial'::regclass)::text,6,'0');
  insert into public.yt_member_orders(source,status,order_no,notes,payment_status,payment_method,created_by,paid_by,paid_at,fulfilled_at,fulfilled_by,client_request_id,amount_rm,pos_business_day,backdate_approval_status,checkout_mode)
   values('future_pos','fulfilled',order_no,reason,'paid','foodcourt',auth.uid(),auth.uid(),stamp,stamp,auth.uid(),rid,total,d,'not_required','pay_now') returning id into v_order;
  insert into private.yt_foodcourt_history_orders(order_id,created_by) values(v_order,auth.uid());
  insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm,fulfilled,fulfilled_at,fulfilled_by)
   values(v_order,product.id,product.title,qty,price,true,stamp,auth.uid()) returning id into item_id;
  -- Unit snapshots permit later corrections, but never grant redeemable benefits.
  insert into public.yt_pos_item_units(order_item_id,unit_number,benefit_status) select item_id,s,'void' from generate_series(1,qty)s;
  v_method:=case when exists(select 1 from public.yt_freeflow_packages where product_id=product.id) then 'Freeflow-Foodcourt' else 'foodcourt' end;
  update public.yt_member_orders set payment_method=v_method where id=v_order;
  insert into public.yt_pos_payment_entries(order_id,request_id,method,amount_rm,kind,received_at,business_day,actor_id,note)
   values(v_order,md5(rid::text||':payment')::uuid,v_method,total,'sale',stamp,d,auth.uid(),reason);
  insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note) values(v_order,auth.uid(),'created','cashier',reason);
  result:=jsonb_build_object('order_id',v_order,'order_no',order_no,'amount_rm',total,'settled_rm',total,'day',d);
 else
  perform 1 from public.yt_freeflow_sessions where yt_freeflow_sessions.order_id=v_order for update;
  select * into v_bill from public.yt_member_orders mo where mo.id=v_order and mo.source='future_pos' for update;
  if not found or coalesce(v_bill.pos_business_day,private.yt_business_day(v_bill.created_at))<>d then raise exception 'order_not_found';end if;
  if v_bill.status in ('cancelled','refunded') or v_bill.payment_status<>'paid' then raise exception 'order_not_editable';end if;
  expected:=nullif(p_data->>'expected_updated','')::timestamptz;
  if expected is null or expected is distinct from v_bill.updated_at then raise exception 'order_changed_reload';end if;
  cancel_order:=coalesce((p_data->>'cancel')::boolean,false);
  after_items:=p_data->'items';
  if jsonb_typeof(after_items) is distinct from 'array' then raise exception 'invalid_order_revision';end if;
  -- This page corrects existing lines. Additional goods use a separate numbered supplement.
  if exists(select 1 from jsonb_array_elements(after_items) j where not exists(select 1 from public.yt_member_order_items i where i.id=nullif(j->>'item_id','')::uuid and i.order_id=v_bill.id and i.product_id is not distinct from nullif(j->>'product_id','')::uuid and i.quantity>0)) then raise exception 'existing_lines_only';end if;
  select coalesce(jsonb_agg(to_jsonb(i) order by i.id),'[]') into before_items from public.yt_member_order_items i where i.order_id=v_bill.id;
  preview:=private.yt_pos_revision_lines(v_bill.id,after_items,cancel_order);
  total:=(preview->>'net')::numeric;balance:=total-private.yt_pos_received(v_bill.id);
  if nullif(p_data->>'expected_net','')::numeric is distinct from total or nullif(p_data->>'expected_balance','')::numeric is distinct from balance then raise exception 'settlement_changed_reload';end if;
  v_method:=coalesce(nullif(p_data->>'payment_method',''),lower(replace(replace(coalesce(v_bill.payment_method,'foodcourt'),'Freeflow-',''),'AB_','')));
  if v_method not in ('foodcourt','cash','duitnow','card','bank_transfer','other') then raise exception 'invalid_payment_method';end if;
  result:=private.yt_pos_owner_revision_apply_v3(v_bill.id,after_items,reason,v_bill.table_label,v_bill.notes,expected,md5(rid::text||':revision')::uuid,false,cancel_order,
   case when cancel_order or lower(replace(replace(v_bill.payment_method,'Freeflow-',''),'AB_',''))=v_method then null else v_method end,d);
  if balance<>0 then perform private.yt_pos_adjustment_pay(v_bill.id,balance,v_method,reason,md5(rid::text||':payment')::uuid);end if;
  -- History-only FreeFlow has no session, so explicitly retain its accounting label.
  if exists(select 1 from private.yt_foodcourt_history_orders h where h.order_id=v_bill.id)
   and exists(select 1 from public.yt_member_order_items i join public.yt_freeflow_packages p on p.product_id=i.product_id where i.order_id=v_bill.id)
   and not exists(select 1 from public.yt_member_order_items i where i.order_id=v_bill.id and not exists(select 1 from public.yt_freeflow_packages p where p.product_id=i.product_id)) then
   v_method:='Freeflow-'||case v_method when 'cash' then 'Cash' when 'duitnow' then 'DuitNow' when 'card' then 'Card' when 'foodcourt' then 'Foodcourt' when 'bank_transfer' then 'Bank_Transfer' else 'Other' end;
   update public.yt_member_orders set payment_method=v_method where id=v_bill.id;
   update public.yt_pos_payment_entries set method=v_method where request_id=md5(rid::text||':payment')::uuid;
  end if;
  -- Historical corrections do not queue a fresh kitchen ticket or issue new benefits.
  update public.yt_member_order_items set fulfilled=true,fulfilled_at=coalesce(fulfilled_at,stamp),fulfilled_by=coalesce(fulfilled_by,auth.uid()) where public.yt_member_order_items.order_id=v_bill.id and exists(select 1 from private.yt_foodcourt_history_orders h where h.order_id=v_bill.id);
  result:=jsonb_build_object('order_id',v_bill.id,'order_no',v_bill.order_no,'amount_rm',total,'settled_rm',balance,'day',d);
  result:=result||jsonb_build_object('before_items',before_items,'after_items',preview->'lines');
  update public.yt_pos_item_units u set benefit_status='void' from public.yt_member_order_items i where i.id=u.order_item_id and i.order_id=v_bill.id and exists(select 1 from private.yt_foodcourt_history_orders h where h.order_id=v_bill.id);
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'foodcourt.'||p_action,'pos_order',v_order,jsonb_build_object('business_day',d,'reason',reason,'request_id',rid,'result',result));
 insert into private.yt_foodcourt_operations(request_id,actor_id,payload,result) values(rid,auth.uid(),payload,result);
 return result;
end$$;
create function public.yt_foodcourt_reconcile(p_action text,p_data jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$select private.yt_foodcourt_reconcile(p_action,p_data)$$;
revoke all on function private.yt_foodcourt_reconcile(text,jsonb),public.yt_foodcourt_reconcile(text,jsonb) from public,anon;
grant execute on function private.yt_foodcourt_reconcile(text,jsonb),public.yt_foodcourt_reconcile(text,jsonb) to authenticated;

-- Keep the established records reset compatible with the new FK child and checks.
do $$declare def text;needle text;begin
 def:=pg_get_functiondef('private.yt_owner_reset_v9(uuid,text,text,uuid,uuid,bigint[],text[])'::regprocedure);
 needle:='truncate table public.yt_freeflow_sale_lines,';
 if position(needle in def)=0 then raise exception 'reset_definition_changed';end if;
 execute replace(def,needle,'truncate table private.yt_foodcourt_checks,private.yt_foodcourt_operations,private.yt_foodcourt_history_orders,public.yt_freeflow_sale_lines,');
end$$;
