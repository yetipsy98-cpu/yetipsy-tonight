-- Credential-scoped guest FreeFlow. No Auth accounts or membership access are created.
create table public.yt_freeflow_guests (
 id uuid primary key default gen_random_uuid(), token_hash text not null unique,
 created_at timestamptz not null default clock_timestamp(), recovery_hash text unique,
 recovery_expires_at timestamptz, last_recovery_hash text
);
alter table public.yt_freeflow_guests enable row level security;
revoke all on public.yt_freeflow_guests from public,anon,authenticated;
alter table public.yt_freeflow_members alter column customer_id drop not null;
alter table public.yt_freeflow_members add column guest_id uuid references public.yt_freeflow_guests(id);
alter table public.yt_freeflow_members add constraint yt_freeflow_member_identity check(num_nonnulls(customer_id,guest_id)=1);
create unique index yt_freeflow_guest_seat on public.yt_freeflow_members(session_id,guest_id) where guest_id is not null;
create index yt_freeflow_members_principal on public.yt_freeflow_members((coalesce(customer_id,guest_id)));
create index yt_freeflow_members_guest on public.yt_freeflow_members(guest_id);
alter table public.yt_freeflow_requests alter column customer_id drop not null;
alter table public.yt_freeflow_requests add column guest_id uuid references public.yt_freeflow_guests(id);
alter table public.yt_freeflow_requests add constraint yt_freeflow_request_identity check(num_nonnulls(customer_id,guest_id)=1);
create unique index yt_freeflow_guest_pending_cup on public.yt_freeflow_requests(guest_id) where status='pending' and guest_id is not null;
create index yt_freeflow_requests_guest on public.yt_freeflow_requests(guest_id);
create index yt_freeflow_requests_principal on public.yt_freeflow_requests((coalesce(customer_id,guest_id)));

create function private.yt_freeflow_bind_actor(p_session uuid,p_customer uuid,p_guest boolean) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare s public.yt_freeflow_sessions%rowtype;o public.yt_member_orders%rowtype;b uuid;
begin
 if p_guest then
  if not exists(select 1 from public.yt_freeflow_guests where id=p_customer) then raise exception 'guest_token_invalid';end if;
 elsif auth.uid() is null or not exists(select 1 from public.pin_accounts where auth_user_id=p_customer)
  or exists(select 1 from public.work_accounts where auth_user_id=p_customer) then raise exception 'customer_only';end if;
 perform pg_advisory_xact_lock(hashtextextended('freeflow-member:'||p_customer::text,0));
 select * into s from public.yt_freeflow_sessions where id=p_session for update;
 if not found then raise exception 'freeflow_session_missing';end if;
 select * into o from public.yt_member_orders where id=s.order_id for share;
 if o.status in('cancelled','pending','refunded') or o.payment_status='refunded' or o.cancel_after_refund then raise exception 'freeflow_order_invalid';end if;
 if s.status<>'active' or clock_timestamp()>=s.ends_at then raise exception 'freeflow_unavailable';end if;
 select id into b from public.yt_freeflow_members where session_id=s.id and coalesce(customer_id,guest_id)=p_customer;
 if b is not null then return jsonb_build_object('member_id',b,'already_bound',true);end if;
 if exists(select 1 from public.yt_freeflow_members m join public.yt_freeflow_sessions x on x.id=m.session_id
 where coalesce(m.customer_id,m.guest_id)=p_customer and m.status<>'closed' and x.status<>'closed' and x.ends_at>clock_timestamp()) then raise exception 'freeflow_already_bound';end if;
 if (select count(*) from public.yt_freeflow_members where session_id=s.id)>=s.capacity then raise exception 'freeflow_full';end if;
 insert into public.yt_freeflow_members(session_id,customer_id,guest_id)
 values(s.id,case when not p_guest then p_customer end,case when p_guest then p_customer end) returning id into b;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(case when not p_guest then auth.uid() end,'freeflow.bind','freeflow_member',b,
 jsonb_build_object('session_id',s.id,'customer_id',case when not p_guest then p_customer end,'guest_id',case when p_guest then p_customer end));
 return jsonb_build_object('member_id',b);
end$$;
revoke all on function private.yt_freeflow_bind_actor(uuid,uuid,boolean) from public,anon,authenticated;

create or replace function private.yt_freeflow_core(p_actor uuid,p_guest boolean,p_action text,p_data jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare actor uuid:=p_actor; staff boolean; manager boolean; owner boolean; result jsonb; rows jsonb;
 v_session public.yt_freeflow_sessions%rowtype;v_member public.yt_freeflow_members%rowtype;v_request public.yt_freeflow_requests%rowtype;
 menu public.yt_freeflow_menus%rowtype;v_order public.yt_member_orders%rowtype; sale public.yt_ambassador_pos_sales%rowtype;
 cfg public.yt_play_upgrade_settings%rowtype; product public.yt_shop_products%rowtype;
 v_id uuid;subject uuid; n integer;lat double precision;lng double precision;distance_m double precision;day date;st timestamptz;en timestamptz;
begin
 if actor is null or p_guest is null then raise exception 'not_authenticated';end if;
 staff:=not p_guest and private.yt_pos_work_staff();owner:=not p_guest and private.yt_work_owner();manager:=not p_guest and (owner or private.yt_pos_work_cashier());
 if p_action in('mine','bind','order') then
  if p_guest then
   if not exists(select 1 from public.yt_freeflow_guests where id=actor) then raise exception 'guest_token_invalid';end if;
  elsif not private.yt_play_customer() then raise exception 'customer_only';end if;
 elsif p_action in('queue','order_binding','token','bind_member') then
  if not staff then raise exception 'staff_only';end if;
 elsif p_action='complete' then
  if not staff then raise exception 'staff_only';end if;
 elsif p_action in('menus','menu_save') then
  if not owner then raise exception 'owner_only';end if;
 elsif p_action in('manage','session_save','member_status','session_status','guest_recovery') then
  if not manager then raise exception 'cashier_only';end if;
 else raise exception 'invalid_freeflow_action';end if;

 if p_action='menus' then
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
   -- Once opened, only the table is editable here. Menu and validity remain Owner-controlled.
   update public.yt_freeflow_sessions set table_label=coalesce(btrim(p_data->>'table_label'),'') where id=v_session.id;
  else
   select * into menu from public.yt_freeflow_menus where id=(p_data->>'menu_id')::uuid and active;
   if not found then raise exception 'freeflow_menu_missing';end if;
   if not exists(select 1 from public.yt_freeflow_menu_items i join public.yt_shop_products p on p.id=i.product_id where i.menu_id=menu.id and p.active and p.is_drink) then raise exception 'freeflow_menu_empty';end if;
   day:=sale.business_day;
   if (menu.valid_from is not null and day<menu.valid_from) or (menu.valid_to is not null and day>menu.valid_to) then raise exception 'freeflow_unavailable';end if;
   st:=(day+menu.start_time) at time zone 'Asia/Kuala_Lumpur';
   en:=((day+case when menu.end_time<=menu.start_time then 1 else 0 end)+menu.end_time) at time zone 'Asia/Kuala_Lumpur';
   if en<=clock_timestamp() then raise exception 'freeflow_unavailable';end if;
   insert into public.yt_freeflow_sessions(order_id,menu_id,capacity,table_label,business_day,starts_at,ends_at,created_by)
   values(v_order.id,menu.id,sale.male_count+sale.female_count,coalesce(btrim(p_data->>'table_label'),''),day,st,en,actor) returning * into v_session;
  end if;
  update public.yt_member_orders set table_label=coalesce(nullif(btrim(p_data->>'table_label'),''),'Freeflow') where id=v_order.id;
  result:=jsonb_build_object('id',v_session.id);
 elsif p_action='order_binding' then
  select * into v_order from public.yt_member_orders where id=(p_data->>'order_id')::uuid;
  select * into sale from public.yt_ambassador_pos_sales where order_id=v_order.id;
  if sale.order_id is null or v_order.status in('pending','cancelled','refunded') or v_order.payment_status='refunded' or v_order.cancel_after_refund then raise exception 'freeflow_order_invalid';end if;
  select * into v_session from public.yt_freeflow_sessions where order_id=v_order.id;
  return jsonb_build_object('order_id',v_order.id,'order_no',v_order.order_no,'capacity',sale.male_count+sale.female_count,
   'table_label',v_order.table_label,'can_select_menu',manager,
   'session',case when v_session.id is not null then jsonb_build_object('id',v_session.id,'name',(select name from public.yt_freeflow_menus where id=v_session.menu_id),
    'table_label',v_session.table_label,'status',v_session.status,'ends_at',v_session.ends_at,
    'bound_count',(select count(*) from public.yt_freeflow_members where session_id=v_session.id)) else null end,
   'menus',case when manager and v_session.id is null then coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'start_time',start_time,'end_time',end_time))
    from public.yt_freeflow_menus where active and (valid_from is null or valid_from<=sale.business_day) and (valid_to is null or valid_to>=sale.business_day)),'[]') else '[]'::jsonb end);
 elsif p_action='token' then
  select * into v_session from public.yt_freeflow_sessions where id=(p_data->>'session_id')::uuid for update;
  if not found or v_session.status<>'active' or v_session.ends_at<=clock_timestamp() then raise exception 'freeflow_unavailable';end if;
  if not exists(select 1 from public.yt_member_orders where id=v_session.order_id and status not in('pending','cancelled') and payment_status<>'refunded' and not cancel_after_refund) then raise exception 'freeflow_order_invalid';end if;
  update public.yt_freeflow_sessions set bind_token=gen_random_uuid(),token_expires_at=least(ends_at,clock_timestamp()+interval '2 minutes') where id=v_session.id returning * into v_session;
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
  update public.yt_freeflow_guests set recovery_hash=private.yt_play_hash(v_id),recovery_expires_at=clock_timestamp()+interval '2 minutes' where id=v_member.guest_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(actor,'freeflow.guest_recovery_issued','freeflow_member',v_member.id,jsonb_build_object('guest_id',v_member.guest_id));
  return jsonb_build_object('token',v_id,'expires_at',clock_timestamp()+interval '2 minutes');
 elsif p_action='member_status' then
  perform pg_advisory_xact_lock(hashtextextended('freeflow-member:'||(select coalesce(customer_id,guest_id)::text from public.yt_freeflow_members where id=(p_data->>'member_id')::uuid),0));
  update public.yt_freeflow_members set status=p_data->>'status' where id=(p_data->>'member_id')::uuid returning id into v_id;
  if not found then raise exception 'freeflow_member_missing';end if;
  result:=jsonb_build_object('id',v_id);
 elsif p_action='session_status' then
  update public.yt_freeflow_sessions set status=p_data->>'status' where id=(p_data->>'session_id')::uuid returning id into v_id;
  if not found then raise exception 'freeflow_session_missing';end if;
  result:=jsonb_build_object('id',v_id);
 elsif p_action='order' then
  perform pg_advisory_xact_lock(hashtextextended('freeflow-member:'||actor::text,0));
  select * into v_request from public.yt_freeflow_requests where request_id=(p_data->>'request_id')::uuid;
  if found then
   if coalesce(v_request.customer_id,v_request.guest_id)<>actor or v_request.member_id<>(p_data->>'member_id')::uuid or v_request.product_id<>(p_data->>'product_id')::uuid then raise exception 'request_conflict';end if;
   return jsonb_build_object('id',v_request.id,'status',v_request.status,'idempotent',true);
  end if;
  select * into v_member from public.yt_freeflow_members where id=(p_data->>'member_id')::uuid and coalesce(customer_id,guest_id)=actor;
  if not found then raise exception 'freeflow_member_missing';end if;
  select * into v_session from public.yt_freeflow_sessions where id=v_member.session_id for update;
  select * into v_member from public.yt_freeflow_members where id=v_member.id for update;
  if v_member.status<>'active' or v_session.status<>'active' or clock_timestamp()<v_session.starts_at or clock_timestamp()>=v_session.ends_at then raise exception 'freeflow_unavailable';end if;
  if not exists(select 1 from public.yt_member_orders where id=v_session.order_id and status not in('pending','cancelled') and payment_status<>'refunded' and not cancel_after_refund) then raise exception 'freeflow_order_invalid';end if;
  if not exists(select 1 from public.yt_freeflow_menus where id=v_session.menu_id and active) then raise exception 'freeflow_unavailable';end if;
  select * into cfg from public.yt_play_upgrade_settings where id;
  if cfg.bell_lat is null or cfg.bell_lng is null then raise exception 'bell_disabled';end if;
  lat:=(p_data->>'lat')::double precision;lng:=(p_data->>'lng')::double precision;
  if lat is null or lng is null or lat not between -90 and 90 or lng not between -180 and 180 then raise exception 'location_required';end if;
  distance_m:=6371000*2*asin(least(1,sqrt(power(sin(radians(lat-cfg.bell_lat)/2),2)+cos(radians(cfg.bell_lat))*cos(radians(lat))*power(sin(radians(lng-cfg.bell_lng)/2),2))));
  if distance_m>cfg.bell_radius_m then raise exception 'outside_service_area';end if;
  if exists(select 1 from public.yt_freeflow_requests where coalesce(customer_id,guest_id)=actor and status='pending') then raise exception 'freeflow_wait_for_cup';end if;
  select p.* into product from public.yt_shop_products p join public.yt_freeflow_menu_items i on i.product_id=p.id
   where i.menu_id=v_session.menu_id and p.id=(p_data->>'product_id')::uuid and p.active and p.is_drink;
  if not found then raise exception 'product_unavailable';end if;
  insert into public.yt_freeflow_requests(member_id,customer_id,guest_id,product_id,item_name,table_label,request_id)
  values(v_member.id,case when not p_guest then actor end,case when p_guest then actor end,product.id,product.title,v_session.table_label,(p_data->>'request_id')::uuid) returning id into v_id;
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
  return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.item_name,'table_label',r.table_label,'requested_at',r.requested_at,
   'member_name',coalesce(p.display_name,case when m.guest_id is not null then '访客 '||upper(right(m.id::text,4)) else '会员' end),'order_no',o.order_no,
   'cup_number',1+(select count(*) from public.yt_freeflow_requests x where x.member_id=r.member_id and x.status='served')) order by r.requested_at)
  from public.yt_freeflow_requests r join public.yt_freeflow_members m on m.id=r.member_id
  join public.yt_freeflow_sessions s on s.id=m.session_id join public.yt_member_orders o on o.id=s.order_id
  left join public.profiles p on p.id=m.customer_id where r.status='pending'),'[]');
 elsif p_action='mine' then
  -- Explicit projection: never return request timestamps or other members to customers.
  return coalesce((select jsonb_agg(jsonb_build_object('member_id',m.id,'session_id',s.id,'name',a.name,'visitor_name',case when m.guest_id is not null then '访客 '||upper(right(m.id::text,4)) end,'table_label',s.table_label,
   'status',case when o.status='cancelled' or o.payment_status='refunded' or o.cancel_after_refund or s.status='closed' or m.status='closed' then 'closed'
    when s.ends_at<=clock_timestamp() then 'expired' when s.status='paused' or m.status='paused' or not a.active then 'paused'
    when s.starts_at>clock_timestamp() then 'upcoming' else 'active' end,
   'starts_at',s.starts_at,'ends_at',s.ends_at,
   'cups',(select count(*) from public.yt_freeflow_requests r where r.member_id=m.id and r.status='served'),
   'drinks',coalesce((select jsonb_agg(to_jsonb(x)) from (select item_name name,count(*) quantity from public.yt_freeflow_requests where member_id=m.id and status='served' group by item_name order by item_name)x),'[]'),
   'pending',(select jsonb_build_object('id',r.id,'name',r.item_name,'status',r.status) from public.yt_freeflow_requests r where coalesce(r.customer_id,r.guest_id)=actor and r.status='pending'),
   'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.title) order by p.sort_order,p.title)
     from public.yt_freeflow_menu_items i join public.yt_shop_products p on p.id=i.product_id where i.menu_id=s.menu_id and p.active and p.is_drink),'[]')) order by s.ends_at desc)
   from public.yt_freeflow_members m join public.yt_freeflow_sessions s on s.id=m.session_id
   join public.yt_freeflow_menus a on a.id=s.menu_id join public.yt_member_orders o on o.id=s.order_id
   where coalesce(m.customer_id,m.guest_id)=actor),'[]');
 elsif p_action='manage' then
  day:=coalesce(nullif(p_data->>'day','')::date,private.yt_business_day(now()));
  return jsonb_build_object('menus',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'start_time',start_time,'end_time',end_time,'valid_from',valid_from,'valid_to',valid_to)) from public.yt_freeflow_menus where active),'[]'),
   'orders',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'order_no',o.order_no,'capacity',a.male_count+a.female_count,'table_label',o.table_label))
    from public.yt_ambassador_pos_sales a join public.yt_member_orders o on o.id=a.order_id where a.business_day=day and o.status not in('pending','cancelled') and o.payment_status<>'refunded'),'[]'),
   'sessions',coalesce((select jsonb_agg(to_jsonb(x)) from (
    select s.id,s.order_id,o.order_no,s.menu_id,a.name,s.capacity,s.table_label,s.status,s.starts_at,s.ends_at,
     (select count(*) from public.yt_freeflow_requests r join public.yt_freeflow_members b on b.id=r.member_id where b.session_id=s.id and r.status='served') cups,
     coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'guest',b.guest_id is not null,'name',coalesce(p.display_name,case when b.guest_id is not null then '访客 '||upper(right(b.id::text,4)) else '会员' end),'status',b.status,
       'cups',(select count(*) from public.yt_freeflow_requests where member_id=b.id and status='served'),
       'requests',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.item_name,'status',r.status,'table_label',r.table_label,
        'requested_at',r.requested_at,'served_at',r.served_at,'cancel_reason',r.cancel_reason) order by r.requested_at) from public.yt_freeflow_requests r where r.member_id=b.id),'[]')) order by b.bound_at)
       from public.yt_freeflow_members b left join public.profiles p on p.id=b.customer_id where b.session_id=s.id),'[]') members
    from public.yt_freeflow_sessions s join public.yt_member_orders o on o.id=s.order_id join public.yt_freeflow_menus a on a.id=s.menu_id
    where s.business_day=day order by s.created_at desc)x),'[]'),
   'drinks',coalesce((select jsonb_agg(to_jsonb(x)) from(select r.item_name name,count(*) quantity from public.yt_freeflow_requests r
     join public.yt_freeflow_members b on b.id=r.member_id join public.yt_freeflow_sessions s on s.id=b.session_id
     where s.business_day=day and r.status='served' group by r.item_name order by r.item_name)x),'[]'));
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(case when not p_guest then actor end,'freeflow.'||p_action,'freeflow',coalesce(v_id,v_session.id,v_request.id),p_data-'token');
 return coalesce(result,'{}');
end$$;

revoke all on function private.yt_freeflow_core(uuid,boolean,text,jsonb) from public,anon,authenticated;
create or replace function private.yt_freeflow(p_action text,p_data jsonb default '{}') returns jsonb
language sql security definer set search_path='' as $$select private.yt_freeflow_core(auth.uid(),false,p_action,p_data)$$;
create or replace function private.yt_freeflow_bind(p_session uuid,p_customer uuid) returns jsonb
language sql security definer set search_path='' as $$select private.yt_freeflow_bind_actor(p_session,p_customer,false)$$;

-- Keep the existing private schema inaccessible to anon. Only this dedicated API bridge is reachable.
create schema freeflow_api;
revoke all on schema freeflow_api from public,anon,authenticated;
grant usage on schema freeflow_api to anon,authenticated;
create function freeflow_api.guest(p_action text,p_credential uuid,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare g public.yt_freeflow_guests%rowtype;s public.yt_freeflow_sessions%rowtype;v_hash text;code_hash text;
begin
 if p_credential is null then raise exception 'guest_token_invalid';end if;
 if p_action not in('bind','mine','order','restore') then raise exception 'invalid_freeflow_action';end if;
 v_hash:=private.yt_play_hash(p_credential);
 perform pg_advisory_xact_lock(hashtextextended('freeflow-guest-token:'||v_hash,0));
 if p_action='restore' then
  code_hash:=private.yt_play_hash((p_data->>'token')::uuid);
  select * into g from public.yt_freeflow_guests where token_hash=v_hash for update;
  if found then
   if g.last_recovery_hash=code_hash then return private.yt_freeflow_core(g.id,true,'mine','{}');end if;
   raise exception 'guest_restore_invalid';
  end if;
  select * into g from public.yt_freeflow_guests where recovery_hash=code_hash and recovery_expires_at>clock_timestamp() for update;
  if not found then raise exception 'guest_restore_invalid';end if;
  update public.yt_freeflow_guests set token_hash=v_hash,last_recovery_hash=code_hash,recovery_hash=null,recovery_expires_at=null where id=g.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
   values(null,'freeflow.guest_restored','freeflow_guest',g.id,'{}');
  return private.yt_freeflow_core(g.id,true,'mine','{}');
 end if;
 if p_action='bind' then
  -- Validate the short-lived purchased-order code before creating any guest record.
  select * into s from public.yt_freeflow_sessions where bind_token=(p_data->>'token')::uuid and token_expires_at>clock_timestamp();
  if not found then raise exception 'freeflow_token_expired';end if;
  select * into g from public.yt_freeflow_guests where token_hash=v_hash for update;
  if not found then
   insert into public.yt_freeflow_guests(token_hash) values(v_hash) returning * into g;
  end if;
  return private.yt_freeflow_core(g.id,true,'bind',p_data);
 end if;
 select * into g from public.yt_freeflow_guests where token_hash=v_hash for share;
 if not found then raise exception 'guest_token_invalid';end if;
 return private.yt_freeflow_core(g.id,true,p_action,p_data);
end$$;
revoke all on function freeflow_api.guest(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function freeflow_api.guest(text,uuid,jsonb) to anon,authenticated;
create function public.yt_freeflow_guest(p_action text,p_credential uuid,p_data jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$select freeflow_api.guest(p_action,p_credential,p_data)$$;
revoke all on function public.yt_freeflow_guest(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.yt_freeflow_guest(text,uuid,jsonb) to anon,authenticated;

do $$declare def text;needle text:='public.yt_freeflow_requests, public.yt_freeflow_members, public.yt_freeflow_sessions, private.yt_offer_code_attempts';begin
 select pg_get_functiondef('private.yt_owner_reset_v9(uuid,text,text,uuid,uuid,bigint[],text[])'::regprocedure) into def;
 if strpos(def,needle)=0 then raise exception 'freeflow_guest_reset_integration_missing';end if;
 execute replace(def,needle,'public.yt_freeflow_requests, public.yt_freeflow_members, public.yt_freeflow_guests, public.yt_freeflow_sessions, private.yt_offer_code_attempts');
end$$;
