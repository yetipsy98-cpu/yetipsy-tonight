-- V16.8 Store Box combinations, serving choice and compact history.

alter table public.yt_store_box_product_rules add column if not exists selection_mode text not null default 'fixed';
alter table public.yt_store_box_product_rules add column if not exists components jsonb not null default '[]'::jsonb;
alter table public.yt_store_boxes add column if not exists selection_mode text not null default 'fixed';
alter table public.yt_store_boxes add column if not exists components jsonb not null default '[]'::jsonb;
alter table public.yt_store_box_requests add column if not exists component_key text;
alter table public.yt_store_box_requests add column if not exists component_name text;

do $$begin
 if not exists(select 1 from pg_constraint where conname='yt_store_box_rules_selection_mode_check') then
  alter table public.yt_store_box_product_rules add constraint yt_store_box_rules_selection_mode_check check(selection_mode in ('fixed','customer'));
 end if;
 if not exists(select 1 from pg_constraint where conname='yt_store_boxes_selection_mode_check') then
  alter table public.yt_store_boxes add constraint yt_store_boxes_selection_mode_check check(selection_mode in ('fixed','customer'));
 end if;
 if not exists(select 1 from pg_constraint where conname='yt_store_box_rules_components_check') then
  alter table public.yt_store_box_product_rules add constraint yt_store_box_rules_components_check check(jsonb_typeof(components)='array');
 end if;
 if not exists(select 1 from pg_constraint where conname='yt_store_boxes_components_check') then
  alter table public.yt_store_boxes add constraint yt_store_boxes_components_check check(jsonb_typeof(components)='array');
 end if;
end$$;

update public.yt_store_boxes
set components=jsonb_build_array(jsonb_build_object('key','default','name',name,'total_units',total_units,'served_units',served_units))
where jsonb_array_length(components)=0;

create or replace function private.yt_store_box_rule_list() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order,x.title),'[]'::jsonb) into rows from(
  select p.id product_id,p.title,p.category,p.price_rm,p.active product_active,p.sort_order,
   r.mode,r.total_units,r.request_limit,r.expiry_days,r.unit_label,r.selection_mode,r.components,
   r.completion_reward_id,rw.name completion_reward_name,r.game_pass_enabled,r.active,r.updated_at
  from public.yt_shop_products p left join public.yt_store_box_product_rules r on r.product_id=p.id
  left join public.rewards rw on rw.id=r.completion_reward_id
  order by p.sort_order,p.title
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_request_v2(p_box uuid,p_quantity integer,p_component text,p_request uuid,p_table_label text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();b public.yt_store_boxes%rowtype;r public.yt_store_box_requests%rowtype;
 chosen jsonb;chosen_key text;chosen_name text;available integer;
begin
 if not private.yt_store_box_customer() then raise exception 'customer_only';end if;
 if p_box is null or p_request is null or p_quantity is null or p_quantity<1 or length(coalesce(p_table_label,''))>40 then raise exception 'invalid_store_box_request';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into r from public.yt_store_box_requests where client_request_id=p_request;
 if found then
  if r.box_id<>p_box or r.quantity<>p_quantity or r.customer_id<>actor or coalesce(r.component_key,'')<>coalesce(p_component,r.component_key,'') then raise exception 'request_conflict';end if;
  return to_jsonb(r);
 end if;
 select * into b from public.yt_store_boxes where id=p_box and customer_id=actor for update;
 if not found then raise exception 'store_box_not_found';end if;
 update public.yt_store_box_requests set status='expired' where box_id=b.id and status='pending' and expires_at<=clock_timestamp();
 if b.storage_expires_at<=clock_timestamp() then update public.yt_store_boxes set status='expired',updated_at=clock_timestamp() where id=b.id;raise exception 'store_box_expired';end if;
 if b.status<>'active' or b.served_units>=b.total_units then raise exception 'store_box_not_available';end if;
 if exists(select 1 from public.yt_store_box_requests where box_id=b.id and status in ('pending','accepted','preparing')) then raise exception 'store_box_request_already_active';end if;
 if b.selection_mode='customer' and nullif(btrim(coalesce(p_component,'')),'') is not null then
  select x into chosen from jsonb_array_elements(b.components)x where x->>'key'=p_component and (x->>'served_units')::integer<(x->>'total_units')::integer limit 1;
 else
  select x into chosen from jsonb_array_elements(b.components)x where (x->>'served_units')::integer<(x->>'total_units')::integer limit 1;
 end if;
 if chosen is null then raise exception 'store_box_component_unavailable';end if;
 chosen_key:=chosen->>'key';chosen_name:=chosen->>'name';available:=(chosen->>'total_units')::integer-(chosen->>'served_units')::integer;
 if p_quantity>b.request_limit or p_quantity>available then raise exception 'store_box_quantity_unavailable';end if;
 insert into public.yt_store_box_requests(box_id,customer_id,quantity,component_key,component_name,client_request_id,table_label)
 values(b.id,actor,p_quantity,chosen_key,chosen_name,p_request,nullif(btrim(p_table_label),'')) returning * into r;
 update public.yt_store_boxes set table_label=coalesce(nullif(btrim(p_table_label),''),table_label),updated_at=clock_timestamp() where id=b.id;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,customer_id,metadata)
 values(b.id,r.id,'drink_requested',p_quantity,actor,jsonb_build_object('component_key',chosen_key,'component_name',chosen_name));
 return to_jsonb(r);
end $$;

create or replace function private.yt_store_box_request(p_box uuid,p_quantity integer,p_request uuid,p_table_label text default null) returns jsonb language sql security definer set search_path='' as $$
 select private.yt_store_box_request_v2(p_box,p_quantity,null,p_request,p_table_label)
$$;

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
   r.component_name active_request_component_name,r.status active_request_status,r.requested_at
  from public.yt_store_boxes b left join public.yt_store_box_requests r on r.box_id=b.id and r.status in ('pending','accepted','preparing')
  where b.customer_id=actor
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_queue() returns jsonb language plpgsql security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_box_requests set status='expired' where status='pending' and expires_at<=clock_timestamp();
 select coalesce(jsonb_agg(to_jsonb(x) order by x.requested_at),'[]'::jsonb) into rows from(
  select r.id request_id,r.status,r.quantity,r.component_key,r.component_name,r.table_label,r.requested_at,r.expires_at,r.accepted_by,wa.username accepted_by_name,
   b.id box_id,b.name,b.mode,b.unit_label,b.total_units,b.served_units,b.components,b.selection_mode,b.total_units-b.served_units remaining_units,
   b.customer_id,p.phone customer_phone,coalesce(pr.display_name,p.phone) customer_name,o.order_no
  from public.yt_store_box_requests r join public.yt_store_boxes b on b.id=r.box_id
  join public.yt_member_orders o on o.id=b.source_order_id
  left join public.pin_accounts p on p.auth_user_id=b.customer_id
  left join public.profiles pr on pr.id=b.customer_id
  left join public.work_accounts wa on wa.auth_user_id=r.accepted_by
  where r.status in ('pending','accepted','preparing')
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_staff_boxes() returns jsonb language plpgsql security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_boxes set status='expired',updated_at=clock_timestamp()
  where storage_expires_at<=clock_timestamp() and status in ('active','paused','exhausted');
 select coalesce(jsonb_agg(to_jsonb(x) order by x.storage_expires_at desc,x.updated_at desc),'[]'::jsonb) into rows from(
  select b.id,b.name,b.mode,b.status,b.unit_label,b.total_units,b.served_units,b.components,b.selection_mode,
   b.total_units-b.served_units remaining_units,b.request_limit,b.table_label,b.customer_id,
   coalesce(pr.display_name,p.phone) customer_name,p.phone customer_phone,b.claimed_at,b.storage_expires_at,b.updated_at,
   r.id active_request_id,r.status active_request_status,r.quantity active_request_quantity,r.component_name active_request_component_name
  from public.yt_store_boxes b left join public.pin_accounts p on p.auth_user_id=b.customer_id
  left join public.profiles pr on pr.id=b.customer_id
  left join public.yt_store_box_requests r on r.box_id=b.id and r.status in ('pending','accepted','preparing')
  where b.customer_id is not null and b.status in ('active','paused','exhausted','completed','expired','cancelled')
  order by b.storage_expires_at desc,b.updated_at desc limit 200
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_request_action(p_request uuid,p_action text,p_completed_delta integer default 0,p_reason text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();r public.yt_store_box_requests%rowtype;b public.yt_store_boxes%rowtype;next_status text;
 chosen jsonb;available integer;new_components jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_request is null or p_action not in ('accept','prepare','serve','cancel') or length(coalesce(p_reason,''))>200 then raise exception 'invalid_store_box_action';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into r from public.yt_store_box_requests where id=p_request for update;
 if not found then raise exception 'store_box_request_not_found';end if;
 select * into b from public.yt_store_boxes where id=r.box_id for update;
 if p_action='accept' then
  if r.status='accepted' and r.accepted_by=actor then return to_jsonb(r);end if;
  if r.status<>'pending' or r.expires_at<=clock_timestamp() then raise exception 'store_box_request_not_pending';end if;
  update public.yt_store_box_requests set status='accepted',accepted_by=actor,accepted_at=clock_timestamp() where id=r.id returning * into r;
  next_status:='drink_request_accepted';
 elsif p_action='prepare' then
  if r.status<>'accepted' then raise exception 'store_box_request_not_accepted';end if;
  update public.yt_store_box_requests set status='preparing' where id=r.id returning * into r;
  next_status:='drink_request_preparing';
 elsif p_action='serve' then
  if r.status not in ('pending','accepted','preparing') then raise exception 'store_box_request_not_active';end if;
  if b.status<>'active' or b.storage_expires_at<=clock_timestamp() then raise exception 'store_box_not_available';end if;
  select x into chosen from jsonb_array_elements(b.components)x where x->>'key'=r.component_key limit 1;
  if chosen is null then raise exception 'store_box_component_unavailable';end if;
  available:=(chosen->>'total_units')::integer-(chosen->>'served_units')::integer;
  if r.quantity>available or r.quantity>b.total_units-b.served_units then raise exception 'store_box_quantity_unavailable';end if;
  select jsonb_agg(case when x->>'key'=r.component_key then jsonb_set(x,'{served_units}',to_jsonb((x->>'served_units')::integer+r.quantity)) else x end order by n)
  into new_components from jsonb_array_elements(b.components) with ordinality e(x,n);
  update public.yt_store_box_requests set status='served',served_by=actor,served_at=clock_timestamp(),completed_delta=0 where id=r.id returning * into r;
  update public.yt_store_boxes set served_units=served_units+r.quantity,components=new_components,
   status=case when served_units+r.quantity=total_units then 'exhausted' else 'active' end,
   updated_at=clock_timestamp() where id=b.id returning * into b;
  next_status:='drink_served';
 else
  if r.status not in ('pending','accepted','preparing') then raise exception 'store_box_request_not_active';end if;
  if r.status in ('accepted','preparing') and length(btrim(coalesce(p_reason,'')))<2 then raise exception 'cancel_reason_required';end if;
  update public.yt_store_box_requests set status='cancelled',cancelled_by=actor,cancelled_at=clock_timestamp(),cancel_reason=nullif(btrim(p_reason),'') where id=r.id returning * into r;
  next_status:='drink_request_cancelled';
 end if;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,completed_delta,actor_id,note,metadata)
 values(b.id,r.id,next_status,r.quantity,0,actor,nullif(btrim(p_reason),''),jsonb_build_object('component_key',r.component_key,'component_name',r.component_name));
 return jsonb_build_object('request',to_jsonb(r),'box',to_jsonb(b));
end $$;

create or replace function private.yt_store_box_rule_save_v2(
 p_product uuid,p_mode text,p_total_units integer,p_request_limit integer default 2,
 p_expiry_days integer default 30,p_unit_label text default '杯',p_selection_mode text default 'fixed',
 p_components jsonb default '[]'::jsonb,p_active boolean default true
) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.yt_store_box_product_rules%rowtype;normalized jsonb:='[]'::jsonb;component_total integer:=0;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_product is null or p_mode not in ('package','challenge') or p_request_limit not between 1 and 99
  or p_expiry_days not between 1 and 3650 or p_selection_mode not in ('fixed','customer')
  or length(btrim(coalesce(p_unit_label,''))) not between 1 and 12
  or jsonb_typeof(coalesce(p_components,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_components,'[]'::jsonb))>20
 then raise exception 'invalid_store_box_rule';end if;
 if not exists(select 1 from public.yt_shop_products where id=p_product) then raise exception 'product_not_found';end if;
 if jsonb_array_length(coalesce(p_components,'[]'::jsonb))>0 then
  if exists(select 1 from jsonb_array_elements(p_components) c
   where jsonb_typeof(c)<>'object' or length(btrim(coalesce(c->>'name',''))) not between 1 and 60
    or coalesce(c->>'quantity','')!~'^[0-9]+$' or (c->>'quantity')::integer not between 1 and 999)
  then raise exception 'invalid_store_box_components';end if;
  select jsonb_agg(jsonb_build_object('key','c'||n,'name',btrim(c->>'name'),'quantity',(c->>'quantity')::integer) order by n),
   sum((c->>'quantity')::integer)
  into normalized,component_total from jsonb_array_elements(p_components) with ordinality x(c,n);
 else
  if p_total_units not between 1 and 999 then raise exception 'invalid_store_box_rule';end if;
  component_total:=p_total_units;normalized:='[]'::jsonb;
 end if;
 insert into public.yt_store_box_product_rules(product_id,mode,total_units,request_limit,expiry_days,unit_label,selection_mode,components,completion_reward_id,game_pass_enabled,active,updated_by,updated_at)
 values(p_product,p_mode,component_total,p_request_limit,p_expiry_days,btrim(p_unit_label),p_selection_mode,normalized,null,false,coalesce(p_active,true),auth.uid(),clock_timestamp())
 on conflict(product_id) do update set mode=excluded.mode,total_units=excluded.total_units,request_limit=excluded.request_limit,
  expiry_days=excluded.expiry_days,unit_label=excluded.unit_label,selection_mode=excluded.selection_mode,components=excluded.components,
  completion_reward_id=null,game_pass_enabled=false,active=excluded.active,updated_by=excluded.updated_by,updated_at=excluded.updated_at
 returning * into r;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(auth.uid(),'store_box.rule_save','product',p_product,to_jsonb(r));
 return to_jsonb(r);
end $$;

create or replace function public.yt_store_box_rule_save_v2(
 p_product uuid,p_mode text,p_total_units integer,p_request_limit integer,p_expiry_days integer,
 p_unit_label text,p_selection_mode text,p_components jsonb,p_active boolean
) returns jsonb language sql security invoker set search_path='' as
$$select private.yt_store_box_rule_save_v2(p_product,p_mode,p_total_units,p_request_limit,p_expiry_days,p_unit_label,p_selection_mode,p_components,p_active)$$;
create or replace function public.yt_store_box_request_v2(
 p_box uuid,p_quantity integer,p_component text,p_request uuid,p_table_label text
) returns jsonb language sql security invoker set search_path='' as
$$select private.yt_store_box_request_v2(p_box,p_quantity,p_component,p_request,p_table_label)$$;

revoke all on function private.yt_store_box_rule_save_v2(uuid,text,integer,integer,integer,text,text,jsonb,boolean),private.yt_store_box_request_v2(uuid,integer,text,uuid,text) from public,anon;
revoke all on function public.yt_store_box_rule_save_v2(uuid,text,integer,integer,integer,text,text,jsonb,boolean),public.yt_store_box_request_v2(uuid,integer,text,uuid,text) from public,anon;
grant execute on function private.yt_store_box_rule_save_v2(uuid,text,integer,integer,integer,text,text,jsonb,boolean),private.yt_store_box_request_v2(uuid,integer,text,uuid,text) to authenticated;
grant execute on function public.yt_store_box_rule_save_v2(uuid,text,integer,integer,integer,text,text,jsonb,boolean),public.yt_store_box_request_v2(uuid,integer,text,uuid,text) to authenticated;

create or replace function private.yt_store_box_issue_quote(p_order uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare o public.yt_member_orders%rowtype;rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select * into o from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.item_name),'[]'::jsonb) into rows from(
  select i.id order_item_id,i.product_id,i.item_name,i.quantity,r.mode,
   i.quantity*r.total_units total_units,r.request_limit,r.expiry_days,r.unit_label,r.selection_mode,r.components,
   r.game_pass_enabled,b.id box_id,b.status box_status,b.customer_id,b.served_units,
   c.id active_claim_id,c.claim_token,c.expires_at claim_expires_at,c.issued_by,w.username issued_by_name
  from public.yt_member_order_items i join public.yt_store_box_product_rules r on r.product_id=i.product_id and r.active
  left join public.yt_store_boxes b on b.source_order_item_id=i.id
  left join public.yt_store_box_claims c on c.box_id=b.id and c.status='issued' and c.expires_at>clock_timestamp()
  left join public.work_accounts w on w.auth_user_id=c.issued_by
  where i.order_id=p_order and i.quantity>0
 )x;
 return jsonb_build_object('order_id',o.id,'order_no',o.order_no,'table_label',o.table_label,
  'ready',o.status='fulfilled' and o.payment_status='paid' and o.paid_at is not null and o.settlement_due_since is null and not o.cancel_after_refund,
  'items',rows);
end $$;

create or replace function private.yt_store_box_issue(p_order_item uuid,p_token uuid,p_request uuid,p_minutes integer default 2) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();i public.yt_member_order_items%rowtype;o public.yt_member_orders%rowtype;
 r public.yt_store_box_product_rules%rowtype;b public.yt_store_boxes%rowtype;c public.yt_store_box_claims%rowtype;h text;box_components jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_order_item is null or p_token is null or p_request is null or p_minutes not between 1 and 15 then raise exception 'invalid_store_box_issue';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into i from public.yt_member_order_items where id=p_order_item;
 if not found then raise exception 'order_item_not_found';end if;
 select * into o from public.yt_member_orders where id=i.order_id and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 if o.status<>'fulfilled' or o.payment_status<>'paid' or o.paid_at is null then raise exception 'store_box_after_payment_only';end if;
 if o.settlement_due_since is not null or o.cancel_after_refund then raise exception 'order_payment_adjustment_pending';end if;
 select * into r from public.yt_store_box_product_rules where product_id=i.product_id and active;
 if not found then raise exception 'store_box_product_not_configured';end if;
 if jsonb_array_length(r.components)>0 then
  select jsonb_agg(jsonb_build_object('key',x->>'key','name',x->>'name','total_units',(x->>'quantity')::integer*i.quantity,'served_units',0) order by n)
  into box_components from jsonb_array_elements(r.components) with ordinality e(x,n);
 else
  box_components:=jsonb_build_array(jsonb_build_object('key','default','name',i.item_name,'total_units',i.quantity*r.total_units,'served_units',0));
 end if;
 update public.yt_store_box_claims set status='expired',claim_token=null where box_id in(select id from public.yt_store_boxes where source_order_item_id=i.id) and status='issued' and expires_at<=clock_timestamp();
 select * into c from public.yt_store_box_claims where request_id=p_request;
 h:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 if found then
  if c.token_hash<>h then raise exception 'request_conflict';end if;
  return jsonb_build_object('box_id',c.box_id,'claim_id',c.id,'claim_token',c.claim_token,'expires_at',c.expires_at);
 end if;
 insert into public.yt_store_boxes(source_order_id,source_order_item_id,product_id,customer_id,name,mode,unit_label,total_units,request_limit,expiry_days,selection_mode,components,completion_reward_id,game_pass_enabled,table_label,created_by)
 values(o.id,i.id,i.product_id,o.customer_id,i.item_name,r.mode,r.unit_label,i.quantity*r.total_units,r.request_limit,r.expiry_days,r.selection_mode,box_components,null,false,o.table_label,actor)
 on conflict(source_order_item_id) do nothing;
 select * into b from public.yt_store_boxes where source_order_item_id=i.id for update;
 if b.status not in ('unclaimed','active','paused','exhausted') then raise exception 'store_box_not_issuable';end if;
 if b.customer_id is not null and b.claimed_at is not null then raise exception 'store_box_already_claimed';end if;
 if exists(select 1 from public.yt_store_box_claims where box_id=b.id and status='issued') then raise exception 'store_box_claim_already_active';end if;
 insert into public.yt_store_box_claims(box_id,token_hash,claim_token,request_id,issued_by,expires_at)
 values(b.id,h,p_token,p_request,actor,clock_timestamp()+make_interval(mins=>p_minutes)) returning * into c;
 insert into public.yt_store_box_events(box_id,event_type,actor_id,metadata)
 values(b.id,'claim_issued',actor,jsonb_build_object('claim_id',c.id,'order_id',o.id,'order_item_id',i.id));
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(actor,'store_box.claim_issue','store_box',b.id,jsonb_build_object('claim_id',c.id,'order_id',o.id));
 return jsonb_build_object('box_id',b.id,'claim_id',c.id,'claim_token',c.claim_token,'expires_at',c.expires_at,'name',b.name,'total_units',b.total_units,'unit_label',b.unit_label);
end $$;
