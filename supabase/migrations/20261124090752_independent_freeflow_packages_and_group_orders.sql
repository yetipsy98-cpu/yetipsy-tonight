-- Independent FreeFlow packages. Existing Amba sessions and money remain intact.
begin;
create table public.yt_freeflow_packages(
 product_id uuid primary key references public.yt_shop_products(id) on delete cascade,
 menu_id uuid not null references public.yt_freeflow_menus(id),pax_per_unit integer not null default 1 check(pax_per_unit between 1 and 500),
 active boolean not null default true,created_at timestamptz not null default clock_timestamp()
);
alter table public.yt_freeflow_packages enable row level security;
revoke all on public.yt_freeflow_packages from public,anon,authenticated;
alter table public.yt_freeflow_sessions drop constraint yt_freeflow_sessions_order_id_key;
alter table public.yt_freeflow_sessions add package_product_id uuid references public.yt_shop_products(id),add package_name text,add person_price numeric check(person_price>=0),add anchor_item_id uuid references public.yt_member_order_items(id) on delete cascade;
create unique index yt_freeflow_legacy_order on public.yt_freeflow_sessions(order_id) where anchor_item_id is null;
create unique index yt_freeflow_anchor on public.yt_freeflow_sessions(anchor_item_id) where anchor_item_id is not null;
create table public.yt_freeflow_sale_lines(
 order_item_id uuid primary key references public.yt_member_order_items(id) on delete cascade,
 session_id uuid not null references public.yt_freeflow_sessions(id) on delete cascade,
 pax_per_unit integer not null check(pax_per_unit between 1 and 500)
);
create index yt_freeflow_sale_session on public.yt_freeflow_sale_lines(session_id);
alter table public.yt_freeflow_sale_lines enable row level security;
revoke all on public.yt_freeflow_sale_lines from public,anon,authenticated;
alter table public.yt_freeflow_requests add session_id uuid references public.yt_freeflow_sessions(id),add is_group_order boolean not null default false,
 add submitted_member_id uuid references public.yt_freeflow_members(id) on delete set null,add requested_by uuid references auth.users(id),
 add owner_override boolean not null default false,add kitchen_batch_id uuid,add kitchen_started_at timestamptz;
update public.yt_freeflow_requests r set session_id=m.session_id from public.yt_freeflow_members m where m.id=r.member_id;
alter table public.yt_freeflow_requests alter column session_id set not null;
alter table public.yt_freeflow_requests alter column member_id drop not null;
alter table public.yt_freeflow_requests drop constraint yt_freeflow_request_identity;
update public.yt_freeflow_requests set is_group_order=true,submitted_member_id=member_id,requested_by=customer_id,member_id=null,customer_id=null,guest_id=null where batch_id is not null;
alter table public.yt_freeflow_requests add constraint yt_freeflow_request_identity check(
 (is_group_order and member_id is null and customer_id is null and guest_id is null)
 or (not is_group_order and member_id is not null and num_nonnulls(customer_id,guest_id)=1));
update public.yt_freeflow_requests set kitchen_batch_id=coalesce(batch_id,id),kitchen_started_at=requested_at;
update public.yt_freeflow_requests r set kitchen_started_at=x.started from(select kitchen_batch_id,min(requested_at) started from public.yt_freeflow_requests group by kitchen_batch_id)x where x.kitchen_batch_id=r.kitchen_batch_id;
alter table public.yt_freeflow_requests alter column kitchen_batch_id set not null,alter column kitchen_started_at set not null;
create index yt_freeflow_group_pending on public.yt_freeflow_requests(session_id,kitchen_started_at,id) where status='pending';
create index yt_freeflow_group_served on public.yt_freeflow_requests(session_id) where status='served';

create or replace function private.yt_ff_request_snapshot() returns trigger language plpgsql security definer set search_path='' as $$
declare s public.yt_freeflow_sessions%rowtype;b uuid;started timestamptz;
begin
 if new.session_id is null and new.member_id is not null then select session_id into new.session_id from public.yt_freeflow_members where id=new.member_id;end if;
 select * into s from public.yt_freeflow_sessions where id=new.session_id for update;
 if not found then raise exception 'freeflow_session_missing';end if;
 select kitchen_batch_id,kitchen_started_at into b,started from public.yt_freeflow_requests where session_id=s.id and status='pending' and kitchen_started_at>clock_timestamp()-interval '1 minute' order by kitchen_started_at desc,id limit 1;
 new.kitchen_batch_id:=coalesce(b,gen_random_uuid());new.kitchen_started_at:=coalesce(started,clock_timestamp());new.table_label:=s.table_label;
 return new;
end$$;
revoke all on function private.yt_ff_request_snapshot() from public,anon,authenticated;
create trigger yt_ff_request_snapshot before insert on public.yt_freeflow_requests for each row execute function private.yt_ff_request_snapshot();

create or replace function private.yt_ff_table_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare conflict boolean;label text:=lower(btrim(new.table_label));confirmed boolean;
begin
 if tg_op='UPDATE' and new.table_label is not distinct from old.table_label then return new;end if;
 if length(label)>32 then raise exception 'invalid_table';end if;
 if label<>'' and new.status<>'closed' then
  perform pg_advisory_xact_lock(hashtextextended('freeflow-table:'||label,0));
  select exists(select 1 from public.yt_freeflow_sessions where lower(btrim(table_label))=label and id<>new.id and ((status<>'closed' and ends_at>clock_timestamp()) or exists(select 1 from public.yt_freeflow_requests r where r.session_id=yt_freeflow_sessions.id and r.status='pending'))) into conflict;
  confirmed:=coalesce(current_setting('yt.ff.allow_duplicate_table',true),'')='on' and (private.yt_work_owner() or private.yt_pos_work_cashier());
  if conflict and not confirmed then raise exception 'freeflow_table_occupied';end if;
 end if;
 return new;
end$$;
revoke all on function private.yt_ff_table_guard() from public,anon,authenticated;
create trigger yt_ff_table_guard before insert or update of table_label on public.yt_freeflow_sessions for each row execute function private.yt_ff_table_guard();
create or replace function private.yt_ff_table_after() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.table_label is distinct from new.table_label then
  update public.yt_freeflow_requests set table_label=new.table_label where session_id=new.id and status='pending';
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'freeflow.table_changed','freeflow_session',new.id,jsonb_build_object('before',old.table_label,'after',new.table_label));
 end if;return new;
end$$;
revoke all on function private.yt_ff_table_after() from public,anon,authenticated;
create trigger yt_ff_table_after after update of table_label on public.yt_freeflow_sessions for each row execute function private.yt_ff_table_after();

-- Snapshot a sold package at item insertion, including on a pending staff order.
-- Customers cannot use it until that order is accepted. Added people are linked
-- explicitly to the existing group and never treated as a new package sale.
create or replace function private.yt_ff_package_item() returns trigger language plpgsql security definer set search_path='' as $$
declare rule public.yt_freeflow_packages%rowtype;m public.yt_freeflow_menus%rowtype;o public.yt_member_orders%rowtype;sid uuid;d date;parent uuid;
begin
 select * into rule from public.yt_freeflow_packages where product_id=new.product_id;
 if not found then return new;end if;
 parent:=nullif(current_setting('yt.ff.add_to_session',true),'')::uuid;
 if parent is not null then
  if not exists(select 1 from public.yt_freeflow_sessions where id=parent and order_id=new.order_id and package_product_id=new.product_id) then raise exception 'freeflow_package_mismatch';end if;
  insert into public.yt_freeflow_sale_lines values(new.id,parent,1);return new;
 end if;
 if exists(select 1 from public.yt_ambassador_pos_sales where order_id=new.order_id) then raise exception 'freeflow_separate_amba_order';end if;
 if not rule.active then raise exception 'freeflow_package_unavailable';end if;
 select * into m from public.yt_freeflow_menus where id=rule.menu_id and active;
 if not found or not exists(select 1 from public.yt_freeflow_menu_items mi join public.yt_shop_products p on p.id=mi.product_id where mi.menu_id=rule.menu_id and p.active and p.is_drink) then raise exception 'freeflow_menu_empty';end if;
 if new.quantity*rule.pax_per_unit not between 1 and 500 then raise exception 'invalid_guest_count';end if;
 select * into o from public.yt_member_orders where id=new.order_id;
 if o.source<>'future_pos' then raise exception 'invalid_order';end if;
 d:=coalesce(o.pos_business_day,private.yt_business_day(o.created_at));
 insert into public.yt_freeflow_sessions(order_id,menu_id,capacity,table_label,business_day,starts_at,ends_at,created_by,package_product_id,package_name,person_price,anchor_item_id)
 values(o.id,m.id,new.quantity*rule.pax_per_unit,coalesce(o.table_label,''),d,(d+m.start_time) at time zone 'Asia/Kuala_Lumpur',
 ((d+case when m.end_time<=m.start_time then 1 else 0 end)+m.end_time) at time zone 'Asia/Kuala_Lumpur',o.created_by,new.product_id,new.item_name,round(new.unit_price_rm/rule.pax_per_unit,2),new.id) returning id into sid;
 insert into public.yt_freeflow_sale_lines values(new.id,sid,rule.pax_per_unit);
 return new;
end$$;
revoke all on function private.yt_ff_package_item() from public,anon,authenticated;
create trigger yt_ff_package_item after insert on public.yt_member_order_items for each row execute function private.yt_ff_package_item();

-- Mark access packages served: only actual requested drinks enter production.
create or replace function private.yt_ff_package_snapshot() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.yt_freeflow_packages where product_id=new.product_id) then new.fulfilled:=true;new.fulfilled_at:=clock_timestamp();new.is_drink_at_order:=false;end if;
 return new;
end$$;
revoke all on function private.yt_ff_package_snapshot() from public,anon,authenticated;
create trigger zz_yt_ff_package_snapshot before insert on public.yt_member_order_items for each row execute function private.yt_ff_package_snapshot();

create or replace function private.yt_ff_sync_order(p_order uuid) returns void language plpgsql set search_path='' as $$
declare s public.yt_freeflow_sessions%rowtype;o public.yt_member_orders%rowtype;n integer;bound integer;waiting integer;
begin
 select * into o from public.yt_member_orders where id=p_order;
 for s in select * from public.yt_freeflow_sessions where order_id=p_order and anchor_item_id is not null order by id for update loop
  select coalesce(sum(i.quantity*l.pax_per_unit),0) into n from public.yt_freeflow_sale_lines l join public.yt_member_order_items i on i.id=l.order_item_id where l.session_id=s.id;
  if n=0 and o.status not in('cancelled','refunded') and o.payment_status<>'refunded' and not o.cancel_after_refund and (exists(select 1 from public.yt_freeflow_members where session_id=s.id) or exists(select 1 from public.yt_freeflow_requests where session_id=s.id and status='pending')) then raise exception 'amba_capacity_in_use';end if;
  if o.status in('cancelled','refunded') or o.payment_status='refunded' or o.cancel_after_refund or n=0 then
   update public.yt_freeflow_sessions set status='closed',bind_token=null,token_expires_at=null where id=s.id;
  else
   select count(*) into bound from public.yt_freeflow_members where session_id=s.id;
   select count(*) into waiting from public.yt_freeflow_requests where session_id=s.id and status='pending';
   if n>500 or (n<s.capacity and n<greatest(bound,waiting)) then raise exception 'amba_capacity_in_use';end if;
   update public.yt_freeflow_sessions set capacity=n,business_day=coalesce(o.pos_business_day,s.business_day) where id=s.id;
  end if;
 end loop;
end$$;
revoke all on function private.yt_ff_sync_order(uuid) from public,anon,authenticated;

-- Group-only ordering for a bound customer/guest or an authorised work account.
create or replace function private.yt_ff_group_order(p_actor uuid,p_guest boolean,p_staff boolean,d jsonb) returns jsonb language plpgsql set search_path='' as $$
declare s public.yt_freeflow_sessions%rowtype;m public.yt_freeflow_members%rowtype;o public.yt_member_orders%rowtype;
 cfg public.yt_play_upgrade_settings%rowtype;product public.yt_shop_products%rowtype;j jsonb;items jsonb:=d->'items';
 req uuid;first public.yt_freeflow_requests%rowtype;payload jsonb;qty integer;total integer:=0;n integer:=0;cup_id uuid;ids jsonb:='[]';owner boolean:=false;lat float8;lng float8;distance_m float8;
begin
 if p_actor is null or p_guest is null or p_staff is null then raise exception 'not_authenticated';end if;
 if p_staff then
  if p_guest or p_actor is distinct from auth.uid() or not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
  owner:=private.yt_work_owner();
  select * into s from public.yt_freeflow_sessions where id=(d->>'session_id')::uuid for update;
 else
  select * into m from public.yt_freeflow_members where id=(d->>'member_id')::uuid and coalesce(customer_id,guest_id)=p_actor;
  if not found then raise exception 'freeflow_member_missing';end if;
  select * into s from public.yt_freeflow_sessions where id=m.session_id for update;
 end if;
 if s.id is null then raise exception 'freeflow_session_missing';end if;
 req:=(d->>'request_id')::uuid;
 if req is null or items is null or jsonb_typeof(items)<>'array' or jsonb_array_length(items) not between 1 and 100 or char_length(coalesce(d->>'note',''))>160 then raise exception 'invalid_freeflow_batch';end if;
 payload:=jsonb_build_object('actor',p_actor,'guest',p_guest,'staff',p_staff,'session',s.id,'items',items,'note',btrim(coalesce(d->>'note','')));
 select * into first from public.yt_freeflow_requests where request_id=md5(req::text||':1')::uuid;
 if found then
  if first.batch_payload is distinct from payload and not (not p_staff and first.session_id=s.id and first.submitted_member_id=m.id and first.batch_payload=jsonb_build_object('member_id',m.id,'items',items,'note',btrim(coalesce(d->>'note','')),'actor',p_actor,'guest',p_guest)) then raise exception 'request_conflict';end if;
  return jsonb_build_object('id',first.id,'idempotent',true);
 end if;
 select * into o from public.yt_member_orders where id=s.order_id;
 if o.status in('pending','cancelled','refunded') or o.payment_status='refunded' or o.cancel_after_refund or o.backdate_approval_status='pending' then raise exception 'freeflow_order_invalid';end if;
 if s.status<>'active' or (not p_staff and m.status<>'active') or (not owner and (clock_timestamp()<s.starts_at or clock_timestamp()>=s.ends_at)) then raise exception 'freeflow_unavailable';end if;
 if not exists(select 1 from public.yt_freeflow_menus where id=s.menu_id and active) then raise exception 'freeflow_unavailable';end if;
 if not p_staff then
  select * into cfg from public.yt_play_upgrade_settings where id;
  if cfg.freeflow_gps_required then
   lat:=(d->>'lat')::float8;lng:=(d->>'lng')::float8;
   if cfg.bell_lat is null or cfg.bell_lng is null then raise exception 'bell_disabled';end if;
   if lat is null or lng is null or lat not between -90 and 90 or lng not between -180 and 180 then raise exception 'location_required';end if;
   distance_m:=6371000*2*asin(least(1,sqrt(power(sin(radians(lat-cfg.bell_lat)/2),2)+cos(radians(cfg.bell_lat))*cos(radians(lat))*power(sin(radians(lng-cfg.bell_lng)/2),2))));
   if distance_m>cfg.bell_radius_m then raise exception 'outside_service_area';end if;
  end if;
 end if;
 for j in select value from jsonb_array_elements(items) loop
  if jsonb_typeof(j)<>'object' or coalesce(j->>'quantity','')!~'^[0-9]{1,3}$' then raise exception 'invalid_freeflow_batch';end if;
  qty:=(j->>'quantity')::integer;
  if qty not between 1 and 500 then raise exception 'invalid_freeflow_batch';end if;total:=total+qty;
 end loop;
 if total>500 or (not owner and total+(select count(*) from public.yt_freeflow_requests where session_id=s.id and status='pending')>s.capacity) then raise exception 'freeflow_group_full';end if;
 for j in select value from jsonb_array_elements(items) loop
  select p.* into product from public.yt_shop_products p join public.yt_freeflow_menu_items mi on mi.product_id=p.id where mi.menu_id=s.menu_id and p.id=(j->>'product_id')::uuid and p.active and p.is_drink;
  if not found then raise exception 'product_unavailable';end if;
  for qty in 1..(j->>'quantity')::integer loop
   n:=n+1;
   insert into public.yt_freeflow_requests(session_id,is_group_order,submitted_member_id,requested_by,owner_override,product_id,item_name,table_label,request_id,note,batch_id,batch_payload)
   values(s.id,true,case when not p_staff then m.id end,case when not p_guest then p_actor end,owner,product.id,product.title,s.table_label,md5(req::text||':'||n::text)::uuid,btrim(coalesce(d->>'note','')),req,case when n=1 then payload end) returning yt_freeflow_requests.id into cup_id;
   ids:=ids||jsonb_build_array(cup_id);
  end loop;
 end loop;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(case when not p_guest then p_actor end,'freeflow.group_order','freeflow_session',s.id,jsonb_build_object('request_id',req,'quantity',total,'owner_override',owner,'staff',p_staff));
 return jsonb_build_object('ids',ids,'quantity',total,'status','pending');
end$$;
revoke all on function private.yt_ff_group_order(uuid,boolean,boolean,jsonb) from public,anon,authenticated;

create or replace function private.yt_ff_package_action(a text,d jsonb) returns jsonb language plpgsql set search_path='' as $$
declare m public.yt_freeflow_menus%rowtype;pid uuid;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if a='packages' then return jsonb_build_object('packages',coalesce((select jsonb_agg(to_jsonb(x) order by x.name) from(select p.id,p.title name,p.price_rm,p.active,r.menu_id,r.pax_per_unit,r.active enabled from public.yt_freeflow_packages r join public.yt_shop_products p on p.id=r.product_id)x),'[]'));
 end if;
 pid:=coalesce(nullif(d->>'id','')::uuid,gen_random_uuid());
 if length(btrim(coalesce(d->>'name',''))) not between 1 and 100 or coalesce(d->>'price_rm','')!~'^[0-9]{1,4}(\.[0-9]{1,2})?$' or (d->>'price_rm')::numeric>5000 or coalesce(d->>'pax_per_unit','')!~'^[0-9]{1,3}$' or (d->>'pax_per_unit')::integer not between 1 and 500 then raise exception 'invalid_freeflow_package';end if;
 select * into m from public.yt_freeflow_menus where id=(d->>'menu_id')::uuid and active;
 if not found or not exists(select 1 from public.yt_freeflow_menu_items i join public.yt_shop_products p on p.id=i.product_id where i.menu_id=m.id and p.active and p.is_drink) then raise exception 'freeflow_menu_empty';end if;
 if exists(select 1 from public.yt_shop_products where yt_shop_products.id=pid) and not exists(select 1 from public.yt_freeflow_packages where product_id=pid) then raise exception 'invalid_freeflow_package';end if;
 insert into public.yt_shop_products(id,title,price_rm,active,category,is_drink) values(pid,btrim(d->>'name'),(d->>'price_rm')::numeric,coalesce((d->>'active')::boolean,true),'FreeFlow',false)
 on conflict on constraint yt_shop_products_pkey do update set title=excluded.title,price_rm=excluded.price_rm,active=excluded.active,category='FreeFlow',is_drink=false,updated_at=clock_timestamp();
 insert into public.yt_freeflow_packages(product_id,menu_id,pax_per_unit,active) values(pid,m.id,(d->>'pax_per_unit')::integer,coalesce((d->>'active')::boolean,true)) on conflict(product_id) do update set menu_id=excluded.menu_id,pax_per_unit=excluded.pax_per_unit,active=excluded.active;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'freeflow.package_save','product',pid,d);
 return jsonb_build_object('id',pid);
end$$;
revoke all on function private.yt_ff_package_action(text,jsonb) from public,anon,authenticated;

create or replace function private.yt_ff_people(a text,d jsonb) returns jsonb language plpgsql set search_path='' as $$
declare s public.yt_freeflow_sessions%rowtype;o public.yt_member_orders%rowtype;qty integer;req uuid;prev jsonb;payload jsonb;price numeric;item uuid;amount numeric;result jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if a='pax_preview' and not(d?'session_id') and (select count(*) from public.yt_freeflow_sessions where order_id=(d->>'order_id')::uuid)>1 then return jsonb_build_object('choose_group',true,'groups',(select jsonb_agg(jsonb_build_object('id',id,'name',coalesce(package_name,'FreeFlow'),'table_label',table_label,'capacity',capacity)) from public.yt_freeflow_sessions where order_id=(d->>'order_id')::uuid));end if;
 select * into s from public.yt_freeflow_sessions where id=nullif(d->>'session_id','')::uuid or (not(d?'session_id') and order_id=(d->>'order_id')::uuid) order by id limit 1 for update;
 if not found then raise exception 'freeflow_session_missing';end if;
 select * into o from public.yt_member_orders where id=s.order_id for update;
 if s.anchor_item_id is null then
  return private.yt_freeflow_pax(auth.uid(),a,d||jsonb_build_object('order_id',s.order_id));
 end if;
 if o.status in('pending','cancelled','refunded') or o.payment_status='refunded' or o.cancel_after_refund or s.status='closed' then raise exception 'freeflow_order_invalid';end if;
 if a='pax_add' then
  qty:=(d->>'people')::integer;req:=(d->>'request_id')::uuid;
  if req is null or qty is null or qty not between 1 and 500 then raise exception 'invalid_guest_count';end if;
  payload:=d||jsonb_build_object('actor',auth.uid(),'session_id',s.id);
  select metadata into prev from public.audit_logs where entity_id=s.id and action='freeflow.people_added' and metadata->>'request_id'=req::text;
  if found then if prev->'payload' is distinct from payload then raise exception 'request_conflict';end if;return prev->'result'||jsonb_build_object('idempotent',true);end if;
  if (d->>'expected_capacity')::integer is distinct from s.capacity then raise exception 'freeflow_pax_changed';end if;
  if s.capacity+qty>500 then raise exception 'invalid_guest_count';end if;
  amount:=round(s.person_price*qty,2);price:=amount/qty;
  if o.amount_rm+amount>100000 then raise exception 'order_too_large';end if;
  perform pg_advisory_xact_lock(781943080);
  perform set_config('yt.ff.add_to_session',s.id::text,true);
  -- Price is stored at full numeric precision so grouped packages divide exactly.
  insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm,fulfilled,is_drink_at_order)
  values(o.id,s.package_product_id,s.package_name||' · 加人数',qty,price,true,false) returning id into item;
  perform set_config('yt.ff.add_to_session','',true);
  update public.yt_member_orders set amount_rm=amount_rm+amount,settlement_due_since=case when payment_status='paid' then coalesce(settlement_due_since,clock_timestamp()) else settlement_due_since end,updated_at=clock_timestamp() where id=o.id;
  update public.yt_freeflow_sessions set capacity=capacity+qty where id=s.id;
  update public.yt_pos_day_closings set state='reopened',reopened_at=clock_timestamp(),reopened_by=auth.uid(),reopen_reason='FreeFlow 加人数：'||o.order_no where business_day=coalesce(o.pos_business_day,s.business_day) and state='closed';
  result:=jsonb_build_object('order_id',o.id,'session_id',s.id,'added',qty,'delta_rm',amount,'effective',true);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'freeflow.people_added','freeflow_session',s.id,jsonb_build_object('request_id',req,'payload',payload,'before_capacity',s.capacity,'people',qty,'amount_rm',amount,'result',result));
  return result;
 elsif a='collect_delta' then
  if not (private.yt_pos_work_cashier() or private.yt_work_owner()) then raise exception 'cashier_only';end if;
  if (d->>'confirmed')::boolean is distinct from true then raise exception 'actual_payment_required';end if;
  return private.yt_pos_adjustment_pay(o.id,(d->>'amount')::numeric,d->>'method',coalesce(nullif(btrim(d->>'note'),''),'FreeFlow 补收差价'),(d->>'request_id')::uuid);
 end if;
 return jsonb_build_object('order_id',o.id,'session_id',s.id,'order_no',o.order_no,'package_name',s.package_name,'price_per_person',s.person_price,'capacity',s.capacity,'payment_status',o.payment_status,'amount_rm',o.amount_rm,'received_rm',private.yt_pos_received(o.id),'balance_rm',case when o.payment_status='paid' then o.amount_rm-private.yt_pos_received(o.id) else o.amount_rm end,'can_add',s.status<>'closed','can_collect',private.yt_pos_work_cashier());
end$$;
revoke all on function private.yt_ff_people(text,jsonb) from public,anon,authenticated;

create or replace function private.yt_ff_table_action(d jsonb) returns jsonb language plpgsql set search_path='' as $$
declare s public.yt_freeflow_sessions%rowtype;label text;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 label:=btrim(coalesce(d->>'table_label',''));
 if length(label)>32 then raise exception 'invalid_table';end if;
 if coalesce((d->>'allow_duplicate_table')::boolean,false) then
  if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
  perform set_config('yt.ff.allow_duplicate_table','on',true);
 end if;
 select * into s from public.yt_freeflow_sessions where id=(d->>'session_id')::uuid for update;
 if not found then raise exception 'freeflow_session_missing';end if;
 if d?'expected_table' and coalesce(d->>'expected_table','')<>s.table_label then raise exception 'order_changed_reload';end if;
 update public.yt_freeflow_sessions set table_label=label where id=s.id;
 -- A multi-group order's header is a summary; do not move its other groups.
 if (select count(*) from public.yt_freeflow_sessions where order_id=s.order_id)=1 then update public.yt_member_orders set table_label=nullif(label,''),updated_at=clock_timestamp() where id=s.order_id;end if;
 perform set_config('yt.ff.allow_duplicate_table','',true);
 return jsonb_build_object('id',s.id,'table_label',label);
end$$;
revoke all on function private.yt_ff_table_action(jsonb) from public,anon,authenticated;

create or replace function private.yt_ff_work_menu(d jsonb) returns jsonb language plpgsql set search_path='' as $$
declare s public.yt_freeflow_sessions%rowtype;o public.yt_member_orders%rowtype;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select * into s from public.yt_freeflow_sessions where id=(d->>'session_id')::uuid;
 if not found then raise exception 'freeflow_session_missing';end if;
 select * into o from public.yt_member_orders where id=s.order_id;
 return jsonb_build_object('session_id',s.id,'order_no',o.order_no,'table_label',s.table_label,'name',coalesce(s.package_name,(select name from public.yt_freeflow_menus where id=s.menu_id)),
 'capacity',s.capacity,'pending',(select count(*) from public.yt_freeflow_requests where session_id=s.id and status='pending'),'owner_override',private.yt_work_owner(),
 'can_order',s.status='active' and exists(select 1 from public.yt_freeflow_menus where id=s.menu_id and active) and (private.yt_work_owner() or clock_timestamp() between s.starts_at and s.ends_at) and o.status not in('pending','cancelled','refunded') and o.payment_status<>'refunded' and not o.cancel_after_refund and o.backdate_approval_status<>'pending',
 'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.title) order by p.sort_order,p.title) from public.yt_freeflow_menu_items mi join public.yt_shop_products p on p.id=mi.product_id where mi.menu_id=s.menu_id and p.active and p.is_drink),'[]'));
end$$;
revoke all on function private.yt_ff_work_menu(jsonb) from public,anon,authenticated;

create or replace function private.yt_ff_checkout_order(d jsonb,p_allow_duplicate_table boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;prior jsonb;payload jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 payload:=jsonb_build_object('data',d-'allow_duplicate_table','allow_duplicate_table',p_allow_duplicate_table,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended('yt-ff-create:'||(d->>'p_request'),0));
 select metadata into prior from public.audit_logs where action='freeflow.order_request' and metadata->>'request_id'=d->>'p_request';
 if found then if prior->'payload' is distinct from payload then raise exception 'request_conflict';end if;return prior->'result'||jsonb_build_object('idempotent',true);end if;
 if p_allow_duplicate_table then
  if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
  perform set_config('yt.ff.allow_duplicate_table','on',true);
 end if;
 result:=private.yt_pos_create_order_with_rewards_v4((d->>'p_request')::uuid,d->>'p_table',d->>'p_note',d->'p_items',d->>'p_channel',(d->>'p_draft')::uuid,d->>'p_checkout_mode',(d->>'p_business_day')::date);
 perform private.yt_ff_sync_order((result->>'id')::uuid);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'freeflow.order_request','pos_order',(result->>'id')::uuid,jsonb_build_object('request_id',d->>'p_request','payload',payload,'result',result));
 perform set_config('yt.ff.allow_duplicate_table','',true);
 if p_allow_duplicate_table then insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'freeflow.duplicate_table_confirmed','pos_order',(result->>'id')::uuid,jsonb_build_object('table',d->>'p_table'));end if;
 return result;
end$$;
revoke all on function private.yt_ff_checkout_order(jsonb,boolean) from public,anon,authenticated;
grant execute on function private.yt_ff_checkout_order(jsonb,boolean) to authenticated;
create or replace function public.yt_ff_checkout_order(p_payload jsonb,p_allow_duplicate_table boolean default false) returns jsonb language sql security invoker set search_path='' as $$select private.yt_ff_checkout_order(p_payload,p_allow_duplicate_table)$$;
revoke all on function public.yt_ff_checkout_order(jsonb,boolean) from public,anon;
grant execute on function public.yt_ff_checkout_order(jsonb,boolean) to authenticated;

-- Split real money, not the order amount: allocations always sum exactly to the
-- original entry. A retry is checked against the sum of its two allocation rows.
alter table public.yt_pos_payment_entries add freeflow_partitioned boolean not null default false;
alter table public.yt_pos_payment_entries drop constraint yt_pos_payment_entries_method_check;
alter table public.yt_pos_payment_entries add constraint yt_pos_payment_entries_method_check check(method in('foodcourt','cash','duitnow','card','bank_transfer','other','AB_DuitNow','AB_Cash','AB_Card','AB_Bank_Transfer','AB_Foodcourt','AB_Other','Freeflow-Cash','Freeflow-DuitNow','Freeflow-Card','Freeflow-Bank_Transfer','Freeflow-Foodcourt','Freeflow-Other'));
create or replace function private.yt_ff_payment_partition() returns trigger language plpgsql security definer set search_path='' as $$
declare target numeric;received numeric;ff numeric;ffmethod text;o public.yt_member_orders%rowtype;
begin
 if tg_op='UPDATE' then
  if old.method like 'Freeflow-%' and new.method not like 'Freeflow-%' then
   new.method:='Freeflow-'||case new.method when 'cash' then 'Cash' when 'duitnow' then 'DuitNow' when 'card' then 'Card' when 'bank_transfer' then 'Bank_Transfer' when 'foodcourt' then 'Foodcourt' else 'Other' end;
  end if;return new;
 end if;
 if new.freeflow_partitioned or new.method like 'AB_%' or not exists(select 1 from public.yt_freeflow_sessions where order_id=new.order_id and anchor_item_id is not null) then return new;end if;
 select * into o from public.yt_member_orders where id=new.order_id for update;
 select least(o.amount_rm,coalesce(sum(greatest(0,i.quantity*i.unit_price_rm-coalesce((select sum(u.reward_discount_rm) from public.yt_pos_item_units u where u.order_item_id=i.id and not u.retired),0))),0)) into target
 from public.yt_freeflow_sale_lines l join public.yt_member_order_items i on i.id=l.order_item_id where i.order_id=new.order_id;
 select coalesce(sum(amount_rm),0) into received from public.yt_pos_payment_entries where order_id=new.order_id and method like 'Freeflow-%';
 ff:=case when new.amount_rm>0 then least(new.amount_rm,greatest(0,target-received)) else -least(-new.amount_rm,greatest(0,received-target)) end;
 ffmethod:='Freeflow-'||case lower(replace(new.method,'Freeflow-','')) when 'cash' then 'Cash' when 'duitnow' then 'DuitNow' when 'card' then 'Card' when 'bank_transfer' then 'Bank_Transfer' when 'foodcourt' then 'Foodcourt' else 'Other' end;
 new.freeflow_partitioned:=true;
 if ff=new.amount_rm then new.method:=ffmethod;
 elsif ff<>0 then
  insert into public.yt_pos_payment_entries(order_id,request_id,method,amount_rm,kind,received_at,business_day,actor_id,note,freeflow_partitioned)
  values(new.order_id,md5(new.request_id::text||':freeflow')::uuid,ffmethod,ff,new.kind,new.received_at,new.business_day,new.actor_id,new.note,true);
  new.amount_rm:=new.amount_rm-ff;
 end if;
 return new;
end$$;
revoke all on function private.yt_ff_payment_partition() from public,anon,authenticated;
create trigger yt_ff_payment_partition before insert or update of method on public.yt_pos_payment_entries for each row execute function private.yt_ff_payment_partition();

create or replace function private.yt_ff_order_after() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.yt_freeflow_sessions where order_id=new.id and anchor_item_id is not null) then
  perform private.yt_ff_sync_order(new.id);
  if new.table_label is distinct from old.table_label then update public.yt_freeflow_sessions set table_label=coalesce(new.table_label,'') where order_id=new.id and anchor_item_id is not null;end if;
 end if;return new;
end$$;
revoke all on function private.yt_ff_order_after() from public,anon,authenticated;
create trigger yt_ff_order_after after update of status,payment_status,pos_business_day,table_label on public.yt_member_orders for each row execute function private.yt_ff_order_after();

create or replace function private.yt_ff_item_method(p_item uuid,p_fallback text) returns text language sql stable set search_path='' as $$
 select coalesce((select e.method from public.yt_pos_payment_entries e join public.yt_member_order_items i on i.order_id=e.order_id where i.id=p_item and e.kind='sale'
  and ((e.method like 'Freeflow-%')=exists(select 1 from public.yt_freeflow_sale_lines l where l.order_item_id=i.id)) order by e.received_at,e.id limit 1),p_fallback)
$$;
revoke all on function private.yt_ff_item_method(uuid,text) from public,anon,authenticated;

create or replace function private.yt_ff_paid_method() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.payment_status='paid' and new.payment_method not like 'Freeflow-%' and exists(select 1 from public.yt_freeflow_sale_lines l join public.yt_member_order_items i on i.id=l.order_item_id where i.order_id=new.id)
 and not exists(select 1 from public.yt_member_order_items i where i.order_id=new.id and i.quantity>0 and not exists(select 1 from public.yt_freeflow_sale_lines l where l.order_item_id=i.id)) then
  new.payment_method:='Freeflow-'||case new.payment_method when 'cash' then 'Cash' when 'duitnow' then 'DuitNow' when 'card' then 'Card' when 'foodcourt' then 'Foodcourt' when 'bank_transfer' then 'Bank_Transfer' else 'Other' end;
 end if;return new;
end$$;
revoke all on function private.yt_ff_paid_method() from public,anon,authenticated;
create trigger yt_pos_y_freeflow_method before update of payment_status,payment_method on public.yt_member_orders for each row execute function private.yt_ff_paid_method();

create or replace function private.yt_ff_access_fulfilled() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.source='future_pos' and new.status='confirmed' and exists(select 1 from public.yt_freeflow_sessions where order_id=new.id and anchor_item_id is not null)
 and not exists(select 1 from public.yt_member_order_items where order_id=new.id and quantity>0 and not fulfilled) then
  new.status:='fulfilled';new.fulfilled_at:=coalesce(new.fulfilled_at,clock_timestamp());new.fulfilled_by:=coalesce(new.fulfilled_by,auth.uid());
 end if;return new;
end$$;
revoke all on function private.yt_ff_access_fulfilled() from public,anon,authenticated;
create trigger yt_ff_access_fulfilled before update of status on public.yt_member_orders for each row execute function private.yt_ff_access_fulfilled();

CREATE OR REPLACE FUNCTION private.yt_freeflow_core(p_actor uuid, p_guest boolean, p_action text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare actor uuid:=p_actor; staff boolean; manager boolean; owner boolean; result jsonb; rows jsonb;
 v_session public.yt_freeflow_sessions%rowtype;v_member public.yt_freeflow_members%rowtype;v_request public.yt_freeflow_requests%rowtype;
 menu public.yt_freeflow_menus%rowtype;v_order public.yt_member_orders%rowtype; sale public.yt_ambassador_pos_sales%rowtype;
 cfg public.yt_play_upgrade_settings%rowtype; product public.yt_shop_products%rowtype;
 v_id uuid;subject uuid; n integer;lat double precision;lng double precision;distance_m double precision;day date;st timestamptz;en timestamptz;
 previous_start timestamptz;previous_end timestamptz;change_reason text;change_request uuid;prior_change jsonb;
begin
 if actor is null or p_guest is null then raise exception 'not_authenticated';end if;
 staff:=not p_guest and private.yt_pos_work_staff();owner:=not p_guest and private.yt_work_owner();manager:=not p_guest and (owner or private.yt_pos_work_cashier());
 if p_action in('packages','package_save') then return private.yt_ff_package_action(p_action,p_data);
 elsif p_action='table_save' then return private.yt_ff_table_action(p_data);
 elsif p_action='work_menu' then return private.yt_ff_work_menu(p_data);
 elsif p_action='staff_order' then return private.yt_ff_group_order(actor,p_guest,true,p_data);
 elsif p_action in('pax_preview','pax_add','collect_delta') then
  if p_guest or actor is distinct from auth.uid() then raise exception 'staff_only';end if;
  return private.yt_ff_people(p_action,p_data);
 end if;
 if p_action in('mine','bind','order') then
  if p_guest then
   if not exists(select 1 from public.yt_freeflow_guests where id=actor and imported_customer_id is null and expires_at>clock_timestamp()) then raise exception 'guest_token_invalid';end if;
  elsif not private.yt_play_customer() then raise exception 'customer_only';end if;
 elsif p_action in('queue','order_binding','token','bind_member','complete_group') then
  if not staff then raise exception 'staff_only';end if;
 elsif p_action='complete' then
  if not staff then raise exception 'staff_only';end if;
 elsif p_action in('menus','menu_save') then
  if not owner then raise exception 'owner_only';end if;
 elsif p_action='manage' then
  if p_guest or not (staff or private.yt_owner_limited()) then raise exception 'staff_only';end if;
 elsif p_action in('session_save','member_status','session_status','guest_recovery','session_time','pax_preview','pax_add','collect_delta') then
  if not manager then raise exception 'cashier_only';end if;
 else raise exception 'invalid_freeflow_action';end if;

 if p_action='complete_group' then return private.yt_freeflow_complete_group(actor,p_data);
 elsif p_action in('pax_preview','pax_add','collect_delta') then return private.yt_freeflow_pax(actor,p_action,p_data);
 elsif p_action='menus' then
  return jsonb_build_object('menus',coalesce((select jsonb_agg(to_jsonb(x)) from (
   select a.*,coalesce((select jsonb_agg(product_id) from public.yt_freeflow_menu_items where menu_id=a.id),'[]') product_ids
   from public.yt_freeflow_menus a order by a.name)x),'[]'),
   'products',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',title,'active',active,'category',category) order by sort_order,title)
   from public.yt_shop_products where is_drink),'[]'));
 elsif p_action='menu_save' then
  v_id:=coalesce(nullif(p_data->>'id','')::uuid,gen_random_uuid());
  insert into public.yt_freeflow_menus(id,name,active,start_time,end_time,valid_from,valid_to)
  values(v_id,btrim(p_data->>'name'),coalesce((p_data->>'active')::boolean,true),(p_data->>'start_time')::time,
   (p_data->>'end_time')::time,nullif(p_data->>'valid_from','')::date,nullif(p_data->>'valid_to','')::date)
  on conflict(id) do update set name=excluded.name,active=excluded.active,start_time=excluded.start_time,end_time=excluded.end_time,
   valid_from=excluded.valid_from,valid_to=excluded.valid_to;
  if not exists(select 1 from jsonb_array_elements_text(p_data->'product_ids')) then raise exception 'freeflow_menu_empty';end if;
  delete from public.yt_freeflow_menu_items where menu_id=v_id;
  insert into public.yt_freeflow_menu_items(menu_id,product_id)
   select distinct v_id,p.id from jsonb_array_elements_text(p_data->'product_ids') a
   join public.yt_shop_products p on p.id=a.value::uuid and p.is_drink;
  if not found then raise exception 'freeflow_menu_empty';end if;
  result:=jsonb_build_object('id',v_id);
 elsif p_action='session_save' then
  perform pg_advisory_xact_lock(hashtextextended('freeflow-session:'||(p_data->>'order_id'),0));
  select * into v_session from public.yt_freeflow_sessions where order_id=(p_data->>'order_id')::uuid for update;
  select * into v_order from public.yt_member_orders where id=(p_data->>'order_id')::uuid for update;
  select * into sale from public.yt_ambassador_pos_sales where order_id=v_order.id;
  if sale.order_id is null or v_order.status in('pending','cancelled') or v_order.payment_status='refunded' or v_order.cancel_after_refund then raise exception 'freeflow_order_invalid';end if;
  if v_session.id is not null then
   -- Once opened, only the table is editable here. Menu is fixed here; time changes use the audited session_time action.
   update public.yt_freeflow_sessions set table_label=coalesce(btrim(p_data->>'table_label'),'') where id=v_session.id;
  else
   select * into menu from public.yt_freeflow_menus where id=(p_data->>'menu_id')::uuid and active;
   if not found then raise exception 'freeflow_menu_missing';end if;
   if not exists(select 1 from public.yt_freeflow_menu_items i join public.yt_shop_products p on p.id=i.product_id where i.menu_id=menu.id and p.active and p.is_drink) then raise exception 'freeflow_menu_empty';end if;
   day:=sale.business_day;
   st:=(day+menu.start_time) at time zone 'Asia/Kuala_Lumpur';
   en:=((day+case when menu.end_time<=menu.start_time then 1 else 0 end)+menu.end_time) at time zone 'Asia/Kuala_Lumpur';
   insert into public.yt_freeflow_sessions(order_id,menu_id,capacity,table_label,business_day,starts_at,ends_at,created_by)
   values(v_order.id,menu.id,sale.male_count+sale.female_count,coalesce(btrim(p_data->>'table_label'),''),day,st,en,actor) returning * into v_session;
  end if;
  update public.yt_member_orders set table_label=coalesce(nullif(btrim(p_data->>'table_label'),''),'Freeflow') where id=v_order.id;
  result:=jsonb_build_object('id',v_session.id);
 elsif p_action='order_binding' then
  if exists(select 1 from public.yt_freeflow_sessions where order_id=(p_data->>'order_id')::uuid and anchor_item_id is not null) then
   return jsonb_build_object('standalone',true,'order_id',p_data->>'order_id','sessions',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'table_label',s.table_label,'name',s.package_name,'capacity',s.capacity,'status',s.status) order by s.created_at,s.id) from public.yt_freeflow_sessions s where s.order_id=(p_data->>'order_id')::uuid),'[]'));
  end if;

  select * into v_order from public.yt_member_orders where id=(p_data->>'order_id')::uuid;
  select * into sale from public.yt_ambassador_pos_sales where order_id=v_order.id;
  if sale.order_id is null or v_order.status in('pending','cancelled','refunded') or v_order.payment_status='refunded' or v_order.cancel_after_refund then raise exception 'freeflow_order_invalid';end if;
  select * into v_session from public.yt_freeflow_sessions where order_id=v_order.id;
  return jsonb_build_object('order_id',v_order.id,'order_no',v_order.order_no,'capacity',sale.male_count+sale.female_count,
   'table_label',v_order.table_label,'can_select_menu',manager,
   'session',case when v_session.id is not null then jsonb_build_object('id',v_session.id,'name',(select name from public.yt_freeflow_menus where id=v_session.menu_id),
    'table_label',v_session.table_label,'status',v_session.status,'starts_at',v_session.starts_at,'ends_at',v_session.ends_at,
    'bound_count',(select count(*) from public.yt_freeflow_members where session_id=v_session.id)) else null end,
   'menus',case when manager and v_session.id is null then coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'start_time',start_time,'end_time',end_time))
    from public.yt_freeflow_menus where active),'[]') else '[]'::jsonb end);
 elsif p_action='token' then
  select * into v_session from public.yt_freeflow_sessions where id=(p_data->>'session_id')::uuid for update;
  if not found or v_session.status<>'active' or v_session.ends_at<=clock_timestamp() then raise exception 'freeflow_unavailable';end if;
  if not exists(select 1 from public.yt_member_orders where id=v_session.order_id and status not in('pending','cancelled') and payment_status<>'refunded' and not cancel_after_refund and backdate_approval_status<>'pending') then raise exception 'freeflow_order_invalid';end if;
  update public.yt_freeflow_sessions set bind_token=gen_random_uuid(),token_expires_at=least(ends_at,clock_timestamp()+interval '5 minutes') where id=v_session.id returning * into v_session;
  return jsonb_build_object('token',v_session.bind_token,'expires_at',v_session.token_expires_at);
 elsif p_action='bind' then
  select * into v_session from public.yt_freeflow_sessions where bind_token=(p_data->>'token')::uuid and token_expires_at>clock_timestamp();
  if not found then raise exception 'freeflow_token_expired';end if;
  result:=private.yt_freeflow_bind_actor(v_session.id,actor,p_guest);
  -- Recheck after the session row lock: a cashier may have rotated the code while binding waited.
  if not exists(select 1 from public.yt_freeflow_sessions where id=v_session.id and bind_token=(p_data->>'token')::uuid and token_expires_at>clock_timestamp()) then raise exception 'freeflow_token_expired';end if;
  return result;
 elsif p_action='bind_member' then
  select customer_id into subject from public.yt_play_member_tokens
   where token_hash=private.yt_play_hash((p_data->>'token')::uuid) and expires_at>clock_timestamp();
  if subject is null then raise exception 'token_invalid';end if;
  return private.yt_freeflow_bind_actor((p_data->>'session_id')::uuid,subject,false);
 elsif p_action='guest_recovery' then
  select * into v_member from public.yt_freeflow_members where id=(p_data->>'member_id')::uuid;
  if not found or v_member.guest_id is null then raise exception 'freeflow_member_missing';end if;
  v_id:=gen_random_uuid();
  update public.yt_freeflow_guests set recovery_hash=private.yt_play_hash(v_id),recovery_expires_at=clock_timestamp()+interval '5 minutes' where id=v_member.guest_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(actor,'freeflow.guest_recovery_issued','freeflow_member',v_member.id,jsonb_build_object('guest_id',v_member.guest_id));
  return jsonb_build_object('token',v_id,'expires_at',clock_timestamp()+interval '5 minutes');
 elsif p_action='member_status' then
  perform pg_advisory_xact_lock(hashtextextended('freeflow-member:'||(select coalesce(customer_id,guest_id)::text from public.yt_freeflow_members where id=(p_data->>'member_id')::uuid),0));
  update public.yt_freeflow_members set status=p_data->>'status' where id=(p_data->>'member_id')::uuid returning id into v_id;
  if not found then raise exception 'freeflow_member_missing';end if;
  result:=jsonb_build_object('id',v_id);
 elsif p_action='session_time' then
  change_reason:=btrim(coalesce(p_data->>'reason',''));
  if char_length(change_reason)<2 or char_length(change_reason)>300 then raise exception 'freeflow_time_reason_required';end if;
  change_request:=nullif(p_data->>'request_id','')::uuid;
  if change_request is null then raise exception 'request_required';end if;
  st:=nullif(p_data->>'starts_at','')::timestamptz;en:=nullif(p_data->>'ends_at','')::timestamptz;
  if st is null or en is null or not isfinite(st) or not isfinite(en) or en<=st then raise exception 'freeflow_time_invalid';end if;
  for subject in select coalesce(customer_id,guest_id) from public.yt_freeflow_members where session_id=(p_data->>'session_id')::uuid and status<>'closed' order by coalesce(customer_id,guest_id) loop
   perform pg_advisory_xact_lock(hashtextextended('freeflow-member:'||subject::text,0));
  end loop;
  select * into v_session from public.yt_freeflow_sessions where id=(p_data->>'session_id')::uuid for update;
  if not found then raise exception 'freeflow_session_missing';end if;
  select metadata into prior_change from public.audit_logs where action='freeflow.session_time' and entity_id=v_session.id and metadata->>'request_id'=change_request::text;
  if found then
   if (prior_change->>'starts_at')::timestamptz is distinct from st or (prior_change->>'ends_at')::timestamptz is distinct from en
    or prior_change->>'reason' is distinct from change_reason or prior_change->>'actor_id' is distinct from actor::text then raise exception 'request_conflict';end if;
   return jsonb_build_object('id',v_session.id,'idempotent',true);
  end if;
  if en<=clock_timestamp() then raise exception 'freeflow_time_invalid';end if;
  if v_session.status='closed' then raise exception 'freeflow_unavailable';end if;
  if not exists(select 1 from public.yt_member_orders where id=v_session.order_id and status not in('pending','cancelled','refunded') and payment_status<>'refunded' and not cancel_after_refund and backdate_approval_status<>'pending') then raise exception 'freeflow_order_invalid';end if;
  if nullif(p_data->>'expected_starts_at','')::timestamptz is distinct from v_session.starts_at
   or nullif(p_data->>'expected_ends_at','')::timestamptz is distinct from v_session.ends_at then raise exception 'freeflow_time_changed';end if;
  if st=v_session.starts_at and en=v_session.ends_at then return jsonb_build_object('id',v_session.id,'unchanged',true);end if;
  if exists(select 1 from public.yt_freeflow_members m join public.yt_freeflow_members other on coalesce(other.customer_id,other.guest_id)=coalesce(m.customer_id,m.guest_id) and other.session_id<>m.session_id join public.yt_freeflow_sessions other_session on other_session.id=other.session_id where m.session_id=v_session.id and m.status<>'closed' and other.status<>'closed' and other_session.status<>'closed' and other_session.ends_at>clock_timestamp()) then raise exception 'freeflow_already_bound';end if;
  previous_start:=v_session.starts_at;previous_end:=v_session.ends_at;
  update public.yt_freeflow_sessions set starts_at=st,ends_at=en,token_expires_at=least(token_expires_at,en) where id=v_session.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(actor,'freeflow.session_time','freeflow',v_session.id,jsonb_build_object('request_id',change_request,'actor_id',actor,
   'actor_name',coalesce((select username from public.work_accounts where auth_user_id=actor),'Cashier'),
   'before_starts_at',previous_start,'before_ends_at',previous_end,'starts_at',st,'ends_at',en,'reason',change_reason));
  return jsonb_build_object('id',v_session.id,'starts_at',st,'ends_at',en);
 elsif p_action='session_status' then
  update public.yt_freeflow_sessions set status=p_data->>'status' where id=(p_data->>'session_id')::uuid returning id into v_id;
  if not found then raise exception 'freeflow_session_missing';end if;
  result:=jsonb_build_object('id',v_id);
 elsif p_action='order' then
  if p_data?'items' then return private.yt_ff_group_order(actor,p_guest,false,p_data);end if;
  if char_length(coalesce(p_data->>'note',''))>160 then raise exception 'invalid_freeflow_note';end if;
  perform pg_advisory_xact_lock(hashtextextended('freeflow-member:'||actor::text,0));
  select * into v_request from public.yt_freeflow_requests where request_id=(p_data->>'request_id')::uuid;
  if found then
   if coalesce(v_request.customer_id,v_request.guest_id)<>actor or v_request.member_id<>(p_data->>'member_id')::uuid or v_request.product_id<>(p_data->>'product_id')::uuid or v_request.note<>btrim(coalesce(p_data->>'note','')) then raise exception 'request_conflict';end if;
   return jsonb_build_object('id',v_request.id,'status',v_request.status,'idempotent',true);
  end if;
  select * into v_member from public.yt_freeflow_members where id=(p_data->>'member_id')::uuid and coalesce(customer_id,guest_id)=actor;
  if not found then raise exception 'freeflow_member_missing';end if;
  select * into v_session from public.yt_freeflow_sessions where id=v_member.session_id for update;
  select * into v_member from public.yt_freeflow_members where id=v_member.id for update;
  if v_member.status<>'active' or v_session.status<>'active' or clock_timestamp()<v_session.starts_at or clock_timestamp()>=v_session.ends_at then raise exception 'freeflow_unavailable';end if;
  if not exists(select 1 from public.yt_member_orders where id=v_session.order_id and status not in('pending','cancelled') and payment_status<>'refunded' and not cancel_after_refund and backdate_approval_status<>'pending') then raise exception 'freeflow_order_invalid';end if;
  if not exists(select 1 from public.yt_freeflow_menus where id=v_session.menu_id and active) then raise exception 'freeflow_unavailable';end if;
  select * into cfg from public.yt_play_upgrade_settings where id;
  if cfg.freeflow_gps_required then
  if cfg.bell_lat is null or cfg.bell_lng is null then raise exception 'bell_disabled';end if;
  lat:=(p_data->>'lat')::double precision;lng:=(p_data->>'lng')::double precision;
  if lat is null or lng is null or lat not between -90 and 90 or lng not between -180 and 180 then raise exception 'location_required';end if;
  distance_m:=6371000*2*asin(least(1,sqrt(power(sin(radians(lat-cfg.bell_lat)/2),2)+cos(radians(cfg.bell_lat))*cos(radians(lat))*power(sin(radians(lng-cfg.bell_lng)/2),2))));
  if distance_m>cfg.bell_radius_m then raise exception 'outside_service_area';end if;
  end if;
  if exists(select 1 from public.yt_freeflow_requests where coalesce(customer_id,guest_id)=actor and session_id=v_session.id and status='pending') then raise exception 'freeflow_wait_for_cup';end if;
  if (select count(*) from public.yt_freeflow_requests r where r.session_id=v_session.id and r.status='pending')>=v_session.capacity then raise exception 'freeflow_group_full';end if;
  select p.* into product from public.yt_shop_products p join public.yt_freeflow_menu_items i on i.product_id=p.id
   where i.menu_id=v_session.menu_id and p.id=(p_data->>'product_id')::uuid and p.active and p.is_drink;
  if not found then raise exception 'product_unavailable';end if;
  insert into public.yt_freeflow_requests(member_id,customer_id,guest_id,product_id,item_name,table_label,request_id,note)
  values(v_member.id,case when not p_guest then actor end,case when p_guest then actor end,product.id,product.title,v_session.table_label,(p_data->>'request_id')::uuid,btrim(coalesce(p_data->>'note',''))) returning id into v_id;
  return jsonb_build_object('id',v_id,'status','pending');
 elsif p_action='complete' then
  if (p_data->>'status') not in('served','cancelled') then raise exception 'invalid_freeflow_action';end if;
  if p_data->>'status'='cancelled' and not manager then raise exception 'cashier_only';end if;
  if p_data->>'status'='cancelled' and length(btrim(coalesce(p_data->>'reason','')))<2 then raise exception 'reason_required';end if;
  select * into v_request from public.yt_freeflow_requests where id=(p_data->>'request_id')::uuid for update;
  if not found then raise exception 'freeflow_request_missing';end if;
  if v_request.status<>'pending' then
   if v_request.status=p_data->>'status' then return jsonb_build_object('id',v_request.id,'idempotent',true);end if;
   raise exception 'freeflow_request_completed';
  end if;
  update public.yt_freeflow_requests set status=p_data->>'status',served_at=case when p_data->>'status'='served' then clock_timestamp() end,
   completed_by=actor,cancel_reason=case when p_data->>'status'='cancelled' then btrim(p_data->>'reason') end where id=v_request.id;
  result:=jsonb_build_object('id',v_request.id);
 elsif p_action='queue' then
  return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'session_id',s.id,'order_id',o.id,'product_id',r.product_id,'name',r.item_name,'note',r.note,'table_label',s.table_label,'requested_at',r.requested_at,
   'kitchen_batch_id',r.kitchen_batch_id,'kitchen_started_at',r.kitchen_started_at,'member_name',case when r.is_group_order then '整组代点' else coalesce(p.display_name,case when m.guest_id is not null then '访客 '||upper(right(m.id::text,4)) else '会员' end) end,
   'order_no',o.order_no,'proxy',r.is_group_order,'owner_override',r.owner_override,'cup_number',case when r.is_group_order then null else 1+(select count(*) from public.yt_freeflow_requests x where x.member_id=r.member_id and not x.is_group_order and x.status in('served','pending') and (x.requested_at,x.id)<(r.requested_at,r.id)) end)
    order by r.kitchen_started_at,r.kitchen_batch_id,r.requested_at,r.id)
   from public.yt_freeflow_requests r join public.yt_freeflow_sessions s on s.id=r.session_id join public.yt_member_orders o on o.id=s.order_id
   left join public.yt_freeflow_members m on m.id=r.member_id left join public.profiles p on p.id=m.customer_id where r.status='pending'),'[]');
 elsif p_action='mine' then
  -- Explicit projection: never return request timestamps or other members to customers.
  return coalesce((select jsonb_agg(jsonb_build_object('member_id',m.id,'session_id',s.id,'name',a.name,'visitor_name',case when m.guest_id is not null then '访客 '||upper(right(m.id::text,4)) end,'table_label',s.table_label,'package_name',s.package_name,
   'status',case when o.status='cancelled' or o.payment_status='refunded' or o.cancel_after_refund or o.status='pending' or o.backdate_approval_status='pending' or s.status='closed' or m.status='closed' then 'closed'
    when s.ends_at<=clock_timestamp() then 'expired' when s.status='paused' or m.status='paused' or not a.active then 'paused'
    when s.starts_at>clock_timestamp() then 'upcoming' else 'active' end,
   'starts_at',s.starts_at,'ends_at',s.ends_at,'group_limit',s.capacity,
   'group_pending',(select count(*) from public.yt_freeflow_requests gr where gr.session_id=s.id and gr.status='pending'),
   'group_cups',(select count(*) from public.yt_freeflow_requests gr where gr.session_id=s.id and gr.status='served'),
   'group_best',coalesce((select max(x.cups) from(select count(*) cups from public.yt_freeflow_requests where status='served' group by session_id)x),0),
   'group_drinks',coalesce((select jsonb_agg(to_jsonb(x)) from(select item_name name,count(*) quantity from public.yt_freeflow_requests where session_id=s.id and status='served' group by item_name order by item_name)x),'[]'),
   'group_orders',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.item_name,'note',r.note,'status',r.status) order by r.requested_at) from public.yt_freeflow_requests r where r.session_id=s.id and r.is_group_order and r.status='pending'),'[]'),
   'pending_requests',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.item_name,'note',r.note,'status',r.status) order by r.requested_at) from public.yt_freeflow_requests r where r.member_id=m.id and r.status='pending'),'[]'),
   'cups',(select count(*) from public.yt_freeflow_requests r where r.member_id=m.id and r.status='served'),
   'drinks',coalesce((select jsonb_agg(to_jsonb(x)) from (select item_name name,note,count(*) quantity from public.yt_freeflow_requests where member_id=m.id and status='served' group by item_name,note order by item_name,note)x),'[]'),
   'pending',(select jsonb_build_object('id',r.id,'name',r.item_name,'note',r.note,'status',r.status) from public.yt_freeflow_requests r where coalesce(r.customer_id,r.guest_id)=actor and r.session_id=s.id and r.status='pending' order by r.requested_at limit 1),
   'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.title) order by p.sort_order,p.title)
     from public.yt_freeflow_menu_items i join public.yt_shop_products p on p.id=i.product_id where i.menu_id=s.menu_id and p.active and p.is_drink),'[]')) order by s.ends_at desc)
   from public.yt_freeflow_members m join public.yt_freeflow_sessions s on s.id=m.session_id
   join public.yt_freeflow_menus a on a.id=s.menu_id join public.yt_member_orders o on o.id=s.order_id
   where coalesce(m.customer_id,m.guest_id)=actor),'[]');
 elsif p_action='manage' then
  day:=coalesce(nullif(p_data->>'day','')::date,private.yt_business_day(now()));
  return jsonb_build_object('can_manage',manager,'can_operate',staff,'can_override',owner,'menus',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'start_time',start_time,'end_time',end_time,'valid_from',valid_from,'valid_to',valid_to)) from public.yt_freeflow_menus where active),'[]'),
   'orders',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'order_no',o.order_no,'capacity',a.male_count+a.female_count,'table_label',o.table_label))
    from public.yt_ambassador_pos_sales a join public.yt_member_orders o on o.id=a.order_id where a.business_day=day and o.status not in('pending','cancelled') and o.payment_status<>'refunded'),'[]'),
   'sessions',coalesce((select jsonb_agg(to_jsonb(x)) from (
    select s.id,s.order_id,o.order_no,s.menu_id,coalesce(s.package_name,a.name) name,s.package_product_id,s.person_price,s.capacity,s.table_label,s.status,s.starts_at,s.ends_at,
     coalesce((select jsonb_agg(to_jsonb(rr) order by rr.requested_at desc) from(select r.id,r.item_name name,r.note,r.status,r.table_label,r.requested_at,r.served_at,r.is_group_order,r.owner_override,coalesce(w.username,case when r.is_group_order then '顾客代点' else '顾客点单' end) operator from public.yt_freeflow_requests r left join public.work_accounts w on w.auth_user_id=r.requested_by where r.session_id=s.id order by r.requested_at desc,r.id limit 100)rr),'[]') group_requests,
     case when owner then coalesce((select jsonb_agg(jsonb_build_object('created_at',log.created_at,'actor_name',coalesce(log.metadata->>'actor_name',w.username,'Cashier'),
      'before_starts_at',log.metadata->'before_starts_at','before_ends_at',log.metadata->'before_ends_at',
      'starts_at',log.metadata->'starts_at','ends_at',log.metadata->'ends_at','reason',log.metadata->>'reason') order by log.created_at desc)
      from public.audit_logs log left join public.work_accounts w on w.auth_user_id=log.actor_id
      where log.action='freeflow.session_time' and log.entity_id=s.id),'[]'::jsonb) else '[]'::jsonb end time_changes,
     (select count(*) from public.yt_freeflow_requests r where r.session_id=s.id and r.status='served') cups,
     coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'guest',b.guest_id is not null,'name',coalesce(p.display_name,case when b.guest_id is not null then '访客 '||upper(right(b.id::text,4)) else '会员' end),'status',b.status,
       'cups',(select count(*) from public.yt_freeflow_requests where member_id=b.id and status='served'),
       'requests',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.item_name,'note',r.note,'status',r.status,'table_label',r.table_label,
        'requested_at',r.requested_at,'served_at',r.served_at,'cancel_reason',r.cancel_reason) order by r.requested_at) from public.yt_freeflow_requests r where r.member_id=b.id),'[]')) order by b.bound_at)
       from public.yt_freeflow_members b left join public.profiles p on p.id=b.customer_id where b.session_id=s.id),'[]') members
    from public.yt_freeflow_sessions s join public.yt_member_orders o on o.id=s.order_id join public.yt_freeflow_menus a on a.id=s.menu_id
    where s.business_day=day order by s.created_at desc)x),'[]'),
   'drinks',coalesce((select jsonb_agg(to_jsonb(x)) from(select r.item_name name,count(*) quantity from public.yt_freeflow_requests r
     join public.yt_freeflow_sessions s on s.id=r.session_id
     where s.business_day=day and r.status='served' group by r.item_name order by r.item_name)x),'[]'));
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(case when not p_guest then actor end,'freeflow.'||p_action,'freeflow',coalesce(v_id,v_session.id,v_request.id),p_data-'token');
 return coalesce(result,'{}');
end$function$;

CREATE OR REPLACE FUNCTION private.yt_freeflow_complete_group(p_actor uuid, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare s public.yt_freeflow_sessions%rowtype;ids uuid[];matched integer;changed integer;
begin
 if p_actor is null or p_actor is distinct from auth.uid() or not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_data->'request_ids' is null or jsonb_typeof(p_data->'request_ids')<>'array' or jsonb_array_length(p_data->'request_ids') not between 1 and 500 then raise exception 'invalid_freeflow_action';end if;
 select array_agg(distinct value::uuid) into ids from jsonb_array_elements_text(p_data->'request_ids');
 if cardinality(ids)<>jsonb_array_length(p_data->'request_ids') then raise exception 'invalid_freeflow_action';end if;
 select * into s from public.yt_freeflow_sessions where id=(p_data->>'session_id')::uuid for update;
 if not found then raise exception 'freeflow_session_missing';end if;
 select count(*) into matched from public.yt_freeflow_requests r where r.id=any(ids) and r.session_id=s.id;
 if (select count(distinct kitchen_batch_id) from public.yt_freeflow_requests where id=any(ids))<>1 then raise exception 'invalid_freeflow_action';end if;
 if matched<>cardinality(ids) then raise exception 'freeflow_request_missing';end if;
 perform 1 from public.yt_freeflow_requests where id=any(ids) order by id for update;
 update public.yt_freeflow_requests set status='served',served_at=clock_timestamp(),completed_by=p_actor where id=any(ids) and status='pending';
 get diagnostics changed=row_count;
 if changed>0 then insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(p_actor,'freeflow.complete_group','freeflow_session',s.id,jsonb_build_object('request_ids',to_jsonb(ids),'served_count',changed,'skipped_count',matched-changed));end if;
 return jsonb_build_object('session_id',s.id,'served_count',changed,'skipped_count',matched-changed);
end$function$;

CREATE OR REPLACE FUNCTION private.yt_freeflow_order_batch(actor uuid, is_guest boolean, data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin return private.yt_ff_group_order(actor,is_guest,false,data);end$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_create_order(p_request uuid, p_table text, p_note text, p_items jsonb, p_channel text DEFAULT 'staff'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_user uuid:=auth.uid();v_name text;v_table text;v_note text;
 v_order uuid;v_no text;v_status text;v_prod uuid;v_qty integer;v_total numeric(12,2):=0;
 v_title text;v_price numeric(12,2);v_line jsonb;v_lines jsonb:='[]'::jsonb;
 v_units integer:=0;v_item_id uuid;v_i integer;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_channel not in ('cashier','staff') then raise exception 'invalid_channel';end if;
 if p_channel='cashier' and not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if p_request is null or p_items is null or jsonb_typeof(p_items)<>'array'
    or (jsonb_array_length(p_items)<1 and coalesce(current_setting('yt.pos.allow_empty_order',true),'')<>'on') or jsonb_array_length(p_items)>30
 then raise exception 'invalid_order';end if;
 v_table:=nullif(btrim(coalesce(p_table,'')),'');
 v_note:=nullif(btrim(coalesce(p_note,'')),'');
 if length(coalesce(v_table,''))>32 or length(coalesce(v_note,''))>600
 then raise exception 'invalid_order';end if;
 -- Retry of the same request must never create another bill or duplicate item units.
 perform pg_advisory_xact_lock(hashtextextended('yt-pos-create:'||p_request::text,0));
 select id,order_no,status into v_order,v_no,v_status
 from public.yt_member_orders where client_request_id=p_request;
 if found then
  if not exists(select 1 from public.yt_member_orders
    where id=v_order and created_by=v_user and source='future_pos')
  then raise exception 'request_conflict';end if;
  return jsonb_build_object('id',v_order,'order_no',v_no,'status',v_status,'idempotent',true);
 end if;
 for v_line in select value from jsonb_array_elements(p_items)
 loop
  if jsonb_typeof(v_line)<>'object'
   or coalesce(v_line->>'product_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
   or coalesce(v_line->>'quantity','') !~ '^[0-9]{1,2}$'
  then raise exception 'invalid_line';end if;
  v_prod:=(v_line->>'product_id')::uuid;v_qty:=(v_line->>'quantity')::integer;
  if v_qty<1 or v_qty>20 then raise exception 'invalid_quantity';end if;
  select title,price_rm into v_title,v_price from public.yt_shop_products
   where id=v_prod and active for share;
  if not found or v_price is null then raise exception 'product_unavailable';end if;
  v_total:=v_total+(v_price*v_qty);
  v_units:=v_units+v_qty;
  if v_total>100000 or v_units>80 then raise exception 'order_too_large';end if;
  v_lines:=v_lines||jsonb_build_array(jsonb_build_object(
    'product_id',v_prod,'name',v_title,'qty',v_qty,'unit_price_rm',v_price));
 end loop;
 v_status:=case when p_channel='cashier' then 'confirmed' else 'pending' end;
 v_no:='YT'||to_char(clock_timestamp() at time zone 'Asia/Kuala_Lumpur','YYMMDD')
   ||'-'||lpad(nextval('public.yt_pos_order_serial'::regclass)::text,6,'0');
 insert into public.yt_member_orders(
    source,status,order_no,table_label,notes,payment_status,
    created_by,created_at,updated_at,client_request_id,amount_rm,accepted_at,accepted_by)
 values('future_pos',v_status,v_no,v_table,v_note,'unpaid',
    v_user,clock_timestamp(),clock_timestamp(),p_request,v_total,
    case when p_channel='cashier' then clock_timestamp() else null end,
    case when p_channel='cashier' then v_user else null end)
 returning id into v_order;
 for v_line in select value from jsonb_array_elements(v_lines)
 loop
  insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
   values(v_order,(v_line->>'product_id')::uuid,v_line->>'name',
   (v_line->>'qty')::integer,(v_line->>'unit_price_rm')::numeric)
   returning id into v_item_id;
  for v_i in 1..(v_line->>'qty')::integer loop
    insert into public.yt_pos_item_units(order_item_id,unit_number)
      values(v_item_id,v_i);
  end loop;
 end loop;
 if exists(select 1 from public.yt_freeflow_sessions where order_id=v_order and anchor_item_id is not null) then update public.yt_member_orders set status=status where id=v_order returning status into v_status;end if;
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note)
  values(v_order,v_user,'created',p_channel,v_note);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(v_user,'pos.order_created','pos_order',v_order,
    jsonb_build_object('channel',p_channel,'amount_rm',v_total,'status',v_status,'units',v_units));
 return jsonb_build_object('id',v_order,'order_no',v_no,'status',v_status,
  'amount_rm',v_total,'items',v_lines,'idempotent',false);
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_revision_lines(p_order uuid, p_items jsonb, p_cancel boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare j jsonb;old_line public.yt_member_order_items%rowtype;p public.yt_shop_products%rowtype;
 item uuid;product uuid;qty integer;price numeric;gross numeric:=0;discount numeric:=0;line_discount numeric;units integer:=0;paid_drinks integer:=0;lines jsonb:='[]';seen uuid[]:='{}';
 sale public.yt_ambassador_pos_sales%rowtype;kind text;name text;amba_seen text[]:='{}';pax integer:=0;cap integer;session uuid;ff_group record;new_capacity integer;
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
  if coalesce(j->>'product_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or coalesce(j->>'quantity','') !~ '^[0-9]{1,3}$' then raise exception 'invalid_order_line';end if;
  product:=(j->>'product_id')::uuid;qty:=(j->>'quantity')::integer;
  if qty<1 or qty>(case when exists(select 1 from public.yt_freeflow_packages where product_id=product) then 500 else 20 end) then raise exception 'invalid_quantity';end if;
  item:=null;old_line:=null;
  if nullif(j->>'item_id','') is not null then
   item:=(j->>'item_id')::uuid;
   select * into old_line from public.yt_member_order_items where id=item and order_id=p_order;
   if not found or item=any(seen) then raise exception 'invalid_order_line';end if;seen:=array_append(seen,item);
  end if;
  if item is not null and product is distinct from old_line.product_id and exists(select 1 from public.yt_freeflow_sale_lines where order_item_id=item) then raise exception 'freeflow_package_locked';end if;
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
  gross:=gross+qty*price;discount:=discount+line_discount;units:=units+case when exists(select 1 from public.yt_freeflow_packages where product_id=product) then 0 else qty end;
  if gross>100000 or units>80 then raise exception 'order_too_large';end if;
  lines:=lines||jsonb_build_array(jsonb_build_object('item_id',item,'product_id',product,'name',case when product=old_line.product_id then old_line.item_name else p.title end,
   'quantity',qty,'unit_price_rm',price,'discount_rm',line_discount,'is_drink',case when product=old_line.product_id then old_line.is_drink_at_order else p.is_drink end,'series_id',case when product=old_line.product_id then old_line.series_id_at_order else p.series_id end));
 end loop;
 if sale.order_id is not null then
  if pax<1 then raise exception 'amba_person_required';end if;
  select id into session from public.yt_freeflow_sessions where order_id=p_order for update;
  if session is not null then
   select greatest((select count(*) from public.yt_freeflow_members where session_id=session),(select count(*) from public.yt_freeflow_requests r where r.session_id=session and r.status='pending')) into cap;
   if pax<cap then raise exception 'amba_capacity_in_use';end if;
  end if;
 end if;
 for ff_group in select id,capacity from public.yt_freeflow_sessions where order_id=p_order and anchor_item_id is not null loop
  select coalesce(sum((l->>'quantity')::integer*x.pax_per_unit),0) into new_capacity from jsonb_array_elements(lines) l join public.yt_freeflow_sale_lines x on x.order_item_id=nullif(l->>'item_id','')::uuid where x.session_id=ff_group.id;
  if new_capacity>500 or (new_capacity<ff_group.capacity and new_capacity<greatest((select count(*) from public.yt_freeflow_members where session_id=ff_group.id),(select count(*) from public.yt_freeflow_requests where session_id=ff_group.id and status='pending'))) then raise exception 'amba_capacity_in_use';end if;
 end loop;
 if discount>0 and not exists(select 1 from jsonb_array_elements(lines) l where (l->>'is_drink')::boolean and (l->>'quantity')::integer*(l->>'unit_price_rm')::numeric>(l->>'discount_rm')::numeric) then raise exception 'minimum_one_paid_drink';end if;
 return jsonb_build_object('lines',lines,'gross',gross,'discount',discount,'net',greatest(0,gross-discount));
end $function$;

CREATE OR REPLACE FUNCTION private.yt_pos_catalog()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select case when private.yt_pos_work_staff() then coalesce((
  select jsonb_agg(jsonb_build_object(
  'id',p.id,'name',p.title,'category',p.category,
  'is_drink',p.is_drink,'price_rm',p.price_rm,'active',p.active,'sort_order',p.sort_order,
  'series_id',p.series_id,'series_name',s.name,'benefit_mode',s.benefit_mode,
  'freeflow_package',exists(select 1 from public.yt_freeflow_packages fp where fp.product_id=p.id),'freeflow_pax',(select pax_per_unit from public.yt_freeflow_packages where product_id=p.id),'series_active',s.active,'game_plays',s.game_plays
  ) order by p.sort_order,p.category,p.title)
  from public.yt_shop_products p left join public.yt_pos_series s on s.id=p.series_id
  where (p.active or private.yt_has_role('owner')) and p.category<>'CUSTOM'
 ),'[]'::jsonb) else null end;
$function$;

CREATE OR REPLACE FUNCTION private.yt_freeflow_pax(actor uuid, p_action text, data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare o public.yt_member_orders%rowtype;s public.yt_ambassador_pos_sales%rowtype;g public.yt_freeflow_sessions%rowtype;
 male integer;female integer;delta numeric;req uuid;prior jsonb;payload jsonb;owed numeric;line_id uuid;business date;
begin
 if actor is null or actor is distinct from auth.uid() or not private.yt_pos_work_staff() then raise exception 'cashier_only';end if;
 if p_action not in('pax_preview','pax_add','collect_delta') then raise exception 'invalid_freeflow_action';end if;
 perform pg_advisory_xact_lock(hashtextextended('freeflow-session:'||(data->>'order_id'),0));
 select * into g from public.yt_freeflow_sessions where order_id=(data->>'order_id')::uuid for update;
 select * into o from public.yt_member_orders where id=(data->>'order_id')::uuid and source='future_pos' for update;
 select * into s from public.yt_ambassador_pos_sales where order_id=o.id for update;
 if s.order_id is null or o.status in('pending','cancelled','refunded') or o.payment_status not in('unpaid','paid') or o.cancel_after_refund then raise exception 'freeflow_order_invalid';end if;
 if p_action='collect_delta' then
  if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
  if o.payment_status<>'paid' or coalesce((data->>'confirmed')::boolean,false) is not true then raise exception 'actual_payment_required';end if;
  return private.yt_pos_adjustment_pay(o.id,(data->>'amount')::numeric,data->>'method',coalesce(nullif(btrim(data->>'note'),''),'FreeFlow 加人数补差价'),(data->>'request_id')::uuid);
 end if;
 if p_action='pax_add' then
  male:=(data->>'male')::integer;female:=(data->>'female')::integer;req:=(data->>'request_id')::uuid;
  if male is null or female is null or male<0 or female<0 or male+female<1 or male+female>500 or req is null then raise exception 'invalid_guest_count';end if;
  payload:=data||jsonb_build_object('actor',actor);
  select metadata into prior from public.audit_logs where action='freeflow.pax_add' and entity_id=o.id and metadata->>'request_id'=req::text;
  if found then
   if prior->'payload' is distinct from payload then raise exception 'request_conflict';end if;
   return jsonb_build_object('order_id',o.id,'idempotent',true);
  end if;
  if g.status='closed' then raise exception 'freeflow_unavailable';end if;
  if s.male_count+s.female_count+male+female>500 then raise exception 'invalid_guest_count';end if;
  if (data->>'expected_male')::integer is distinct from s.male_count or (data->>'expected_female')::integer is distinct from s.female_count then raise exception 'freeflow_pax_changed';end if;
  if o.amount_rm<>round(s.male_count*s.male_price+s.female_count*s.female_price,2)+(select coalesce(sum(quantity*unit_price_rm),0) from public.yt_member_order_items where order_id=o.id and item_name not in('Freeflow Male','Freeflow Female')) then raise exception 'freeflow_order_changed';end if;
  delta:=round(male*s.male_price+female*s.female_price,2);
  if delta<=0 or o.amount_rm+delta>100000 then raise exception 'order_too_large';end if;
  perform pg_advisory_xact_lock(781943080);
  if male>0 then
   select id into line_id from public.yt_member_order_items where order_id=o.id and item_name='Freeflow Male' and unit_price_rm=s.male_price order by id limit 1 for update;
   if found then update public.yt_member_order_items set quantity=quantity+male where id=line_id;
   else insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm,is_drink_at_order) values(o.id,null,'Freeflow Male',male,s.male_price,false);end if;
  end if;
  if female>0 then
   select id into line_id from public.yt_member_order_items where order_id=o.id and item_name='Freeflow Female' and unit_price_rm=s.female_price order by id limit 1 for update;
   if found then update public.yt_member_order_items set quantity=quantity+female where id=line_id;
   else insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm,is_drink_at_order) values(o.id,null,'Freeflow Female',female,s.female_price,false);end if;
  end if;
  update public.yt_ambassador_pos_sales set male_count=male_count+male,female_count=female_count+female where order_id=o.id;
  update public.yt_member_orders set amount_rm=amount_rm+delta,settlement_due_since=case when payment_status='paid' then coalesce(settlement_due_since,clock_timestamp()) else settlement_due_since end,updated_at=clock_timestamp() where id=o.id;
  update public.yt_freeflow_sessions set capacity=s.male_count+s.female_count+male+female where order_id=o.id;
  business:=coalesce(o.pos_business_day,s.business_day);
  update public.yt_pos_day_closings set state='reopened',reopened_at=clock_timestamp(),reopened_by=actor,reopen_reason='FreeFlow 加人数：'||o.order_no where business_day=business and state='closed';
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'freeflow.pax_add','pos_order',o.id,
   jsonb_build_object('request_id',req,'payload',payload,'before_male',s.male_count,'before_female',s.female_count,'male',male,'female',female,'delta_rm',delta,'business_day',business,'effective_immediately',true));
  insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note) values(o.id,actor,'edited','cashier','FreeFlow 加人数：男 +'||male||' / 女 +'||female||'；差价 RM'||delta||' 可稍后支付');
  return jsonb_build_object('order_id',o.id,'added',male+female,'delta_rm',delta,'effective',true);
 end if;
 owed:=case when o.payment_status='paid' then o.amount_rm-private.yt_pos_received(o.id) else o.amount_rm end;
 return jsonb_build_object('order_id',o.id,'order_no',o.order_no,'male',s.male_count,'female',s.female_count,'male_price',s.male_price,'female_price',s.female_price,
 'amount_rm',o.amount_rm,'received_rm',private.yt_pos_received(o.id),'balance_rm',owed,'payment_status',o.payment_status,'capacity',s.male_count+s.female_count,'can_add',coalesce(g.status<>'closed',true));
end$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_adjustment_pay(p_order uuid, p_amount numeric, p_method text, p_note text, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_member_orders%rowtype;e public.yt_pos_payment_entries%rowtype;balance numeric;entry_method text;ff_received numeric;
begin
 if not private.yt_work_owner() and not (private.yt_pos_work_cashier() and p_amount>0 and (exists(select 1 from public.yt_ambassador_pos_sales where order_id=p_order) or exists(select 1 from public.yt_freeflow_sessions where order_id=p_order and anchor_item_id is not null)) and (exists(select 1 from public.audit_logs where action='freeflow.pax_add' and entity_id=p_order) or exists(select 1 from public.yt_pos_order_revisions where order_id=p_order) or exists(select 1 from public.yt_freeflow_sessions where order_id=p_order and anchor_item_id is not null))) then raise exception 'owner_only';end if;
 if p_request is null or p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount=0 or abs(p_amount)>100000 or p_amount<>round(p_amount,2) or p_method is null or p_method not in ('foodcourt','cash','duitnow','card','bank_transfer','other') or length(btrim(coalesce(p_note,''))) not between 2 and 300 then raise exception 'invalid_adjustment_payment';end if;
 perform 1 from public.yt_freeflow_sessions where order_id=p_order for update;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 entry_method:=case when exists(select 1 from public.yt_ambassador_pos_sales where order_id=p_order) then 'AB_'||case p_method when 'cash' then 'Cash' when 'duitnow' then 'DuitNow' when 'card' then 'Card' when 'bank_transfer' then 'Bank_Transfer' when 'foodcourt' then 'Foodcourt' else 'Other' end else p_method end;
 select * into e from public.yt_pos_payment_entries where request_id=p_request;
 if found then if e.order_id<>p_order or (select sum(amount_rm) from public.yt_pos_payment_entries where request_id in(p_request,md5(p_request::text||':freeflow')::uuid))<>p_amount or (e.method<>entry_method and e.method<>p_method and lower(replace(e.method,'Freeflow-',''))<>p_method) or coalesce(e.note,'')<>p_note then raise exception 'request_conflict';end if;return private.yt_pos_owner_order_context(p_order);end if;
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

CREATE OR REPLACE FUNCTION private.yt_pos_day_preview(p_day date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d date:=coalesce(p_day,private.yt_business_day(now())); s jsonb; c jsonb; pending jsonb; items jsonb;
 blockers bigint; n bigint; methods jsonb; fingerprint text;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if d<'2020-01-01' or d>private.yt_business_day(now()) then raise exception 'invalid_business_day';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.method),'[]'::jsonb) into methods from (
  select method,sum(amount_rm) net_rm,sum(greatest(amount_rm,0)) received_rm,-sum(least(amount_rm,0)) refunded_rm,count(distinct order_id) orders
  from public.yt_pos_payment_entries where business_day=d group by method
 )x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.item_name,x.product_id,x.payment_method),'[]'::jsonb) into items from (
  select i.product_id,i.item_name,private.yt_ff_item_method(i.id,sold.method) payment_method,sum(i.quantity)::bigint quantity,sum(i.quantity*i.unit_price_rm)::numeric gross_rm,
   coalesce(sum(u.discount_rm),0)::numeric discount_rm,(sum(i.quantity*i.unit_price_rm)-coalesce(sum(u.discount_rm),0))::numeric net_rm
  from public.yt_member_order_items i join public.yt_member_orders o on o.id=i.order_id and o.source='future_pos'
  join (select distinct on (order_id) order_id,method from public.yt_pos_payment_entries where business_day=d and kind='sale' order by order_id,received_at,id) sold on sold.order_id=o.id
  left join lateral(select coalesce(sum(unit.reward_discount_rm),0) discount_rm from public.yt_pos_item_units unit
   where unit.order_item_id=i.id and not unit.retired and unit.unit_number<=i.quantity)u on true
  where i.quantity>0 group by i.product_id,i.item_name,private.yt_ff_item_method(i.id,sold.method)
 )x;
 select jsonb_build_object('net_rm',coalesce(sum(amount_rm),0),'received_rm',coalesce(sum(greatest(amount_rm,0)),0),
  'refunded_rm',-coalesce(sum(least(amount_rm,0)),0),'cash_rm',coalesce(sum(amount_rm) filter(where method in ('cash','AB_Cash','Freeflow-Cash')),0),
  'orders',count(distinct order_id) filter(where kind='sale'),'payment_orders',count(distinct order_id),'entries',count(*),
  'last_entry',coalesce(max(id),0),'gross_rm',coalesce((select sum((x->>'gross_rm')::numeric) from jsonb_array_elements(items)x),0),
  'discount_rm',coalesce((select sum((x->>'discount_rm')::numeric) from jsonb_array_elements(items)x),0),
  'units',coalesce((select sum((x->>'quantity')::bigint) from jsonb_array_elements(items)x),0),
  'cancelled_orders',(select count(*) from public.yt_member_orders o where o.source='future_pos' and o.status='cancelled'
   and o.updated_at>=private.yt_business_start(d) and o.updated_at<private.yt_business_start(d+1))) into s
 from public.yt_pos_payment_entries where business_day=d;
 select count(*),count(*) filter(where coalesce(settlement_due_since,created_at)<=now()-interval '72 hours') into n,blockers
 from public.yt_member_orders where source='future_pos' and ((status in ('pending','confirmed','fulfilled') and payment_status='unpaid')
  or (payment_status='paid' and settlement_due_since is not null));
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]'::jsonb) into pending from (
  select id,order_no,table_label,status,payment_status,
   case when payment_status='paid' then abs(amount_rm-private.yt_pos_received(id)) else amount_rm end amount_rm,
   coalesce(settlement_due_since,created_at) created_at,coalesce(settlement_due_since,created_at)<=now()-interval '72 hours' overdue
  from public.yt_member_orders where source='future_pos'
  and ((status in ('pending','confirmed','fulfilled') and payment_status='unpaid') or (payment_status='paid' and settlement_due_since is not null))
  order by coalesce(settlement_due_since,created_at) limit 100
 )x;
 select to_jsonb(x) into c from public.yt_pos_day_closings x where business_day=d order by revision desc limit 1;
 fingerprint:=md5(s::text||methods::text||items::text||n::text||blockers::text||coalesce(c->>'id','')||coalesce(c->>'state',''));
 return jsonb_build_object('statement_version',2,'day',d,'context',private.yt_business_context(),
  'start_at',private.yt_business_start(d),'end_at',private.yt_business_start(d+1),'stats',s,'items',items,'methods',methods,
  'pending',pending,'pending_count',n,'blocker_count',blockers,'closing',c,'fingerprint',fingerprint);
end $function$;

CREATE OR REPLACE FUNCTION private.yt_owner_financial_export(p_start date, p_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE result jsonb;
BEGIN
 IF NOT private.yt_work_owner() OR NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'owner_only';END IF;
 IF p_start IS NULL OR p_end IS NULL OR p_start>p_end OR p_start<'2020-01-01' OR p_end-p_start>365 THEN RAISE EXCEPTION 'invalid_report_range';END IF;
 WITH ledger AS MATERIALIZED (
  SELECT e.*,o.order_no,o.table_label,o.amount_rm bill_rm,o.payment_status
  FROM public.yt_pos_payment_entries e JOIN public.yt_member_orders o ON o.id=e.order_id
  WHERE e.business_day BETWEEN p_start AND p_end
 ), sales AS (
  SELECT DISTINCT ON(order_id) order_id,method FROM ledger WHERE kind='sale' ORDER BY order_id,received_at,id
 ), product_rows AS MATERIALIZED (
  SELECT i.product_id,i.item_name,coalesce(nullif(p.category,''),'未分类') category,
   coalesce(s.name,'未设系列') series_name,private.yt_ff_item_method(i.id,sales.method) payment_method,
   sum(i.quantity)::bigint quantity,sum(i.quantity*i.unit_price_rm)::numeric gross_rm,
   coalesce(sum(u.discount_rm),0)::numeric discount_rm,
   (sum(i.quantity*i.unit_price_rm)-coalesce(sum(u.discount_rm),0))::numeric net_rm
  FROM sales JOIN public.yt_member_order_items i ON i.order_id=sales.order_id
  LEFT JOIN public.yt_shop_products p ON p.id=i.product_id
  LEFT JOIN public.yt_pos_series s ON s.id=i.series_id_at_order
  LEFT JOIN LATERAL(SELECT coalesce(sum(x.reward_discount_rm),0) discount_rm FROM public.yt_pos_item_units x
   WHERE x.order_item_id=i.id AND NOT x.retired AND x.unit_number<=i.quantity)u ON true
  WHERE i.quantity>0 GROUP BY i.product_id,i.item_name,p.category,s.name,private.yt_ff_item_method(i.id,sales.method)
 ), order_rows AS (
  SELECT order_id id,order_no,table_label,max(business_day) business_day,
   string_agg(DISTINCT method,', ' ORDER BY method) payment_method,
   max(bill_rm) bill_rm,sum(amount_rm) net_rm,max(bill_rm)-private.yt_pos_received(order_id) balance_rm,
   string_agg(DISTINCT CASE WHEN kind IN('adjustment','refund') THEN '于 '||to_char(received_at AT TIME ZONE 'Asia/Kuala_Lumpur','YYYY-MM-DD HH24:MI')||CASE WHEN kind='refund' THEN ' 修改退款' ELSE ' 修改补收' END||CASE WHEN coalesce(note,'')<>'' THEN '：'||note ELSE '' END END,'；') amendment_note
  FROM ledger GROUP BY order_id,order_no,table_label
 )
 SELECT jsonb_build_object('version',1,'complete',true,'start',p_start,'end',p_end,'generated_at',clock_timestamp(),'timezone','Asia/Kuala_Lumpur',
  'summary',(SELECT jsonb_build_object('sales_rm',coalesce(sum(amount_rm) FILTER(WHERE kind='sale'),0),'adjustments_rm',coalesce(sum(amount_rm) FILTER(WHERE kind='adjustment'),0),
   'refunds_rm',-coalesce(sum(amount_rm) FILTER(WHERE kind='refund'),0),'net_rm',coalesce(sum(amount_rm),0),'orders',count(DISTINCT order_id) FILTER(WHERE kind='sale'),'ledger_entries',count(*)) FROM ledger),
  'item_summary',(SELECT jsonb_build_object('quantity',coalesce(sum(quantity),0),'gross_rm',coalesce(sum(gross_rm),0),'discount_rm',coalesce(sum(discount_rm),0),'net_rm',coalesce(sum(net_rm),0),'products',count(DISTINCT product_id)) FROM product_rows),
  'days',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.day) FROM(SELECT business_day AS day,count(DISTINCT order_id) FILTER(WHERE kind='sale') orders,
   coalesce(sum(amount_rm) FILTER(WHERE kind='sale'),0) sales_rm,coalesce(sum(amount_rm) FILTER(WHERE kind='adjustment'),0) adjustments_rm,
   -coalesce(sum(amount_rm) FILTER(WHERE kind='refund'),0) refunds_rm,sum(amount_rm) net_rm FROM ledger GROUP BY business_day)x),'[]'::jsonb),
  'payments',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.method) FROM(SELECT method,count(DISTINCT order_id) orders,
   coalesce(sum(amount_rm) FILTER(WHERE kind='sale'),0) sales_rm,coalesce(sum(amount_rm) FILTER(WHERE kind='adjustment'),0) adjustments_rm,
   -coalesce(sum(amount_rm) FILTER(WHERE kind='refund'),0) refunds_rm,sum(amount_rm) net_rm FROM ledger GROUP BY method)x),'[]'::jsonb),
  'categories',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.category,x.series_name) FROM(SELECT category,series_name,sum(quantity) quantity,sum(gross_rm) gross_rm,sum(discount_rm) discount_rm,sum(net_rm) net_rm FROM product_rows GROUP BY category,series_name)x),'[]'::jsonb),
  'products',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.category,x.item_name,x.payment_method) FROM product_rows x),'[]'::jsonb),
  'orders',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.business_day,x.order_no,x.id) FROM order_rows x),'[]'::jsonb),
  'adjustments',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'order_no',order_no,'business_day',business_day,'kind',kind,'method',method,'amount_rm',amount_rm,'modified_at',received_at,'note',note) ORDER BY business_day,order_no,id) FROM ledger WHERE kind IN('adjustment','refund')),'[]'::jsonb),
  'counts',jsonb_build_object('orders',(SELECT count(*) FROM order_rows),'product_method_rows',(SELECT count(*) FROM product_rows),'adjustments',(SELECT count(*) FROM ledger WHERE kind IN('adjustment','refund')))
 ) INTO result;
 RETURN result;
END $function$;

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
   exists(select 1 from public.yt_freeflow_sessions fs where fs.order_id=x.id) has_freeflow_group,exists(select 1 from public.yt_freeflow_sessions fs where fs.order_id=x.id and fs.anchor_item_id is not null) freeflow_order,x.created_at,x.updated_at,x.created_by,wa.username created_by_name,x.accepted_at,x.fulfilled_at,x.paid_at,x.payment_method,
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
   (p_scope='active' and ((x.status in ('pending','confirmed') and x.payment_status in ('unpaid','paid')) or (x.status='fulfilled' and (x.payment_status='unpaid' or (x.payment_status='paid' and x.amount_rm>private.yt_pos_received(x.id) and (exists(select 1 from public.yt_ambassador_pos_sales ff where ff.order_id=x.id) or exists(select 1 from public.yt_freeflow_sessions fs where fs.order_id=x.id and fs.anchor_item_id is not null)))))))
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
   exists(select 1 from public.yt_freeflow_sessions fs where fs.order_id=x.id) has_freeflow_group,exists(select 1 from public.yt_freeflow_sessions fs where fs.order_id=x.id and fs.anchor_item_id is not null) freeflow_order,x.created_at,x.updated_at,x.created_by,wa.username created_by_name,x.accepted_at,x.fulfilled_at,x.paid_at,x.payment_method,
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
$function$;

CREATE OR REPLACE FUNCTION freeflow_api.import_guest(p_credential uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid:=auth.uid();g public.yt_freeflow_guests%rowtype;m public.yt_freeflow_members%rowtype;e public.yt_freeflow_members%rowtype;k uuid;n integer;cups integer;v_hash text;
begin
 if actor is null or not private.yt_play_customer() then raise exception 'customer_only';end if;
 if p_credential is null then raise exception 'guest_token_invalid';end if;
 v_hash:=private.yt_play_hash(p_credential);
 perform pg_advisory_xact_lock(hashtextextended('freeflow-guest-token:'||v_hash,0));
 select * into g from public.yt_freeflow_guests where token_hash=v_hash for update;
 if not found then raise exception 'guest_token_invalid';end if;
 if g.imported_customer_id=actor then return jsonb_build_object('imported',true,'idempotent',true);end if;
 if g.imported_customer_id is not null or g.expires_at<=clock_timestamp() then raise exception 'guest_token_invalid';end if;
 for k in select x from unnest(array[actor,g.id]) x order by x loop
  perform pg_advisory_xact_lock(hashtextextended('freeflow-member:'||k::text,0));
 end loop;
 for k in select distinct session_id from public.yt_freeflow_members where guest_id=g.id order by session_id loop
  perform 1 from public.yt_freeflow_sessions where id=k for update;
 end loop;
 if exists(select 1 from public.yt_freeflow_requests where guest_id=g.id and status='pending')
  and exists(select 1 from public.yt_freeflow_requests where customer_id=actor and status='pending') then raise exception 'freeflow_import_pending_conflict';end if;
 if exists(select 1 from public.yt_freeflow_members gm join public.yt_freeflow_sessions gs on gs.id=gm.session_id join public.yt_member_orders go on go.id=gs.order_id
  join public.yt_freeflow_members cm on cm.customer_id=actor join public.yt_freeflow_sessions cs on cs.id=cm.session_id join public.yt_member_orders co on co.id=cs.order_id
  where gm.guest_id=g.id and gm.status<>'closed' and gs.status<>'closed' and gs.ends_at>clock_timestamp()
   and cm.status<>'closed' and cs.status<>'closed' and cs.ends_at>clock_timestamp() and gs.id<>cs.id
   and go.status not in('pending','cancelled') and go.payment_status<>'refunded' and not go.cancel_after_refund
   and co.status not in('pending','cancelled') and co.payment_status<>'refunded' and not co.cancel_after_refund)
 then raise exception 'freeflow_import_active_conflict';end if;
 select count(*) into n from public.yt_freeflow_members where guest_id=g.id;
 select count(*) into cups from public.yt_freeflow_requests where guest_id=g.id and status='served';
 for m in select * from public.yt_freeflow_members where guest_id=g.id order by session_id for update loop
  select * into e from public.yt_freeflow_members where session_id=m.session_id and customer_id=actor for update;
  if found then
   update public.yt_freeflow_requests set member_id=e.id,customer_id=actor,guest_id=null where member_id=m.id;
   update public.yt_freeflow_members set status=case when e.status='closed' or m.status='closed' then 'closed' when e.status='paused' or m.status='paused' then 'paused' else 'active' end where id=e.id;
   update public.yt_freeflow_requests set submitted_member_id=e.id where submitted_member_id=m.id;
   delete from public.yt_freeflow_members where id=m.id;
  else
   update public.yt_freeflow_members set customer_id=actor,guest_id=null where id=m.id;
   update public.yt_freeflow_requests set customer_id=actor,guest_id=null where member_id=m.id;
  end if;
 end loop;
 update public.yt_freeflow_guests set imported_customer_id=actor,imported_at=clock_timestamp(),recovery_hash=null,recovery_expires_at=null,last_recovery_hash=null where id=g.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'freeflow.guest_imported','freeflow_guest',g.id,jsonb_build_object('sessions',n,'cups',cups));
 return jsonb_build_object('imported',true,'sessions',n,'cups',cups);
end$function$;

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
   truncate table public.yt_store_box_events,public.yt_store_box_requests,public.yt_store_box_reopen_requests,public.yt_store_box_claims,public.yt_store_boxes restart identity;
  end if;
  if 'records'=any(s) then
   UPDATE public.yt_moon_guest_codes SET status='available',reserved_order_id=NULL,reserved_item_id=NULL WHERE status='reserved';
   update public.yt_store_boxes b
   set source_order_snapshot=coalesce(b.source_order_snapshot,jsonb_build_object('id',o.id,'order_no',o.order_no,'created_at',o.created_at,'table_label',o.table_label,'amount_rm',o.amount_rm)),
       source_item_snapshot=coalesce(b.source_item_snapshot,jsonb_build_object('id',i.id,'item_name',i.item_name,'quantity',i.quantity,'unit_price_rm',i.unit_price_rm))
   from public.yt_member_orders o join public.yt_member_order_items i on i.order_id=o.id
   where b.source_order_id=o.id and b.source_order_item_id=i.id;
  -- Fixed transaction tables; configuration and account tables are retained.
  truncate table public.yt_freeflow_sale_lines, public.yt_freeflow_requests, public.yt_freeflow_members, public.yt_freeflow_guests, public.yt_freeflow_sessions, private.yt_offer_code_attempts,private.yt_offer_short_codes,private.yt_pos_draft_submissions,
   private.yt_redeem_code_attempts,private.yt_redeem_short_codes,
   public.audit_logs,public.game_passes,public.game_sessions,public.idempotency_keys,
   public.pin_auth_limits,public.pin_lookup_limits,public.pin_reset_tokens,public.redeem_tokens,public.redemptions,
   public.reward_offer_claims,public.reward_offers,public.user_rewards,public.work_auth_limits,
   public.yt_game_best_records,public.yt_game_leaderboard_preferences,public.yt_integration_events,
   public.yt_member_enrollments,public.yt_lucky_day_reservations,public.yt_moon_preorder_holds,public.yt_member_order_items,public.yt_pos_order_backdate_requests,public.yt_member_orders,public.yt_pos_custom_drink_versions,private.yt_pos_custom_order_members,public.yt_pos_custom_drink_members,public.yt_pos_custom_drinks,public.yt_point_shop_exchanges,public.yt_point_entries,public.yt_point_wallets,
   public.yt_ambassador_ledger,public.yt_ambassador_checkins,public.yt_ambassador_pos_sales,public.yt_ambassador_passes,public.yt_pos_owner_revision_requests,public.yt_pos_order_revisions,public.yt_pos_payment_entries,public.yt_pos_day_closings,public.yt_pos_item_units,public.yt_pos_order_chits,public.yt_pos_order_events,public.yt_pos_duitnow_proofs,public.yt_pos_pass_bundle_items,public.yt_pos_pass_bundles,
   public.yt_pos_preorder_holds,public.yt_pos_reward_holds,private.yt_store_box_prep_intents,public.yt_promo_grants,public.yt_referral_links,public.yt_play_order_tokens,public.yt_play_consumption_bindings,public.yt_play_first_purchases,public.yt_play_referral_events,public.yt_play_member_tokens,public.yt_play_invite_tokens,public.yt_play_bell_requests,public.yt_play_bell_guests restart identity;
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
end;$function$;

create or replace function private.yt_owner_freeflow_report(p_start date,p_end date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not ((private.yt_has_role('owner') and private.yt_pos_work_staff()) or private.yt_owner_limited()) then raise exception 'owner_only';end if;
 if p_start is null or p_end is null or p_start>p_end or p_end-p_start>365 then raise exception 'invalid_report_range';end if;
 return (with served as materialized(select r.item_name,s.id session_id,s.table_label,s.business_day,o.order_no from public.yt_freeflow_requests r join public.yt_freeflow_sessions s on s.id=r.session_id join public.yt_member_orders o on o.id=s.order_id where s.business_day between p_start and p_end and r.status='served'),leaders as(select session_id,min(table_label) table_label,min(business_day) business_day,min(order_no) order_no,count(*) cups from served group by session_id order by count(*) desc,session_id limit 5)
 select jsonb_build_object('cups',(select count(*) from served),'ranking','groups','top5',coalesce((select jsonb_agg(jsonb_build_object('name',coalesce(nullif(table_label,''),'待填桌号')||' · #'||order_no,'cups',cups,'business_day',business_day) order by cups desc,session_id) from leaders),'[]'),'drinks',coalesce((select jsonb_agg(to_jsonb(x) order by cups desc,name) from(select item_name name,count(*) cups from served group by item_name)x),'[]')));
end$$;

commit;
