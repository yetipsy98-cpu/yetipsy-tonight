-- A FreeFlow session can open and bind before Cashier assigns a table.
alter table public.yt_freeflow_sessions drop constraint yt_freeflow_sessions_table_label_check;
alter table public.yt_freeflow_sessions add constraint yt_freeflow_sessions_table_label_check check(length(btrim(table_label)) between 0 and 32);
alter table public.yt_freeflow_sessions alter column table_label set default '';
create or replace function private.yt_freeflow(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); staff boolean; manager boolean; owner boolean; result jsonb; rows jsonb;
 v_session public.yt_freeflow_sessions%rowtype;v_member public.yt_freeflow_members%rowtype;v_request public.yt_freeflow_requests%rowtype;
 menu public.yt_freeflow_menus%rowtype;v_order public.yt_member_orders%rowtype; sale public.yt_ambassador_pos_sales%rowtype;
 cfg public.yt_play_upgrade_settings%rowtype; product public.yt_shop_products%rowtype;
 v_id uuid;subject uuid; n integer;lat double precision;lng double precision;distance_m double precision;day date;st timestamptz;en timestamptz;
begin
 if actor is null then raise exception 'not_authenticated';end if;
 staff:=private.yt_pos_work_staff();owner:=private.yt_work_owner();manager:=owner or private.yt_pos_work_cashier();
 if p_action in('mine','bind','order') then
  if not private.yt_play_customer() then raise exception 'customer_only';end if;
 elsif p_action in('queue','order_binding','token','bind_member') then
  if not staff then raise exception 'staff_only';end if;
 elsif p_action='complete' then
  if not staff then raise exception 'staff_only';end if;
 elsif p_action in('menus','menu_save') then
  if not owner then raise exception 'owner_only';end if;
 elsif p_action in('manage','session_save','member_status','session_status') then
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
  result:=private.yt_freeflow_bind(v_session.id,actor);
  -- Recheck after the session row lock: a cashier may have rotated the code while binding waited.
  if not exists(select 1 from public.yt_freeflow_sessions where id=v_session.id and bind_token=(p_data->>'token')::uuid and token_expires_at>clock_timestamp()) then raise exception 'freeflow_token_expired';end if;
  return result;
 elsif p_action='bind_member' then
  select customer_id into subject from public.yt_play_member_tokens
   where token_hash=private.yt_play_hash((p_data->>'token')::uuid) and expires_at>clock_timestamp();
  if subject is null then raise exception 'token_invalid';end if;
  return private.yt_freeflow_bind((p_data->>'session_id')::uuid,subject);
 elsif p_action='member_status' then
  perform pg_advisory_xact_lock(hashtextextended('freeflow-member:'||(select customer_id::text from public.yt_freeflow_members where id=(p_data->>'member_id')::uuid),0));
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
   if v_request.customer_id<>actor or v_request.member_id<>(p_data->>'member_id')::uuid or v_request.product_id<>(p_data->>'product_id')::uuid then raise exception 'request_conflict';end if;
   return jsonb_build_object('id',v_request.id,'status',v_request.status,'idempotent',true);
  end if;
  select * into v_member from public.yt_freeflow_members where id=(p_data->>'member_id')::uuid and customer_id=actor;
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
  if exists(select 1 from public.yt_freeflow_requests where customer_id=actor and status='pending') then raise exception 'freeflow_wait_for_cup';end if;
  select p.* into product from public.yt_shop_products p join public.yt_freeflow_menu_items i on i.product_id=p.id
   where i.menu_id=v_session.menu_id and p.id=(p_data->>'product_id')::uuid and p.active and p.is_drink;
  if not found then raise exception 'product_unavailable';end if;
  insert into public.yt_freeflow_requests(member_id,customer_id,product_id,item_name,table_label,request_id)
  values(v_member.id,actor,product.id,product.title,v_session.table_label,(p_data->>'request_id')::uuid) returning id into v_id;
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
   'member_name',coalesce(p.display_name,'会员'),'order_no',o.order_no,
   'cup_number',1+(select count(*) from public.yt_freeflow_requests x where x.member_id=r.member_id and x.status='served')) order by r.requested_at)
  from public.yt_freeflow_requests r join public.yt_freeflow_members m on m.id=r.member_id
  join public.yt_freeflow_sessions s on s.id=m.session_id join public.yt_member_orders o on o.id=s.order_id
  left join public.profiles p on p.id=m.customer_id where r.status='pending'),'[]');
 elsif p_action='mine' then
  -- Explicit projection: never return request timestamps or other members to customers.
  return coalesce((select jsonb_agg(jsonb_build_object('member_id',m.id,'session_id',s.id,'name',a.name,'table_label',s.table_label,
   'status',case when o.status='cancelled' or o.payment_status='refunded' or o.cancel_after_refund or s.status='closed' or m.status='closed' then 'closed'
    when s.ends_at<=clock_timestamp() then 'expired' when s.status='paused' or m.status='paused' or not a.active then 'paused'
    when s.starts_at>clock_timestamp() then 'upcoming' else 'active' end,
   'starts_at',s.starts_at,'ends_at',s.ends_at,
   'cups',(select count(*) from public.yt_freeflow_requests r where r.member_id=m.id and r.status='served'),
   'drinks',coalesce((select jsonb_agg(to_jsonb(x)) from (select item_name name,count(*) quantity from public.yt_freeflow_requests where member_id=m.id and status='served' group by item_name order by item_name)x),'[]'),
   'pending',(select jsonb_build_object('id',r.id,'name',r.item_name,'status',r.status) from public.yt_freeflow_requests r where r.customer_id=actor and r.status='pending'),
   'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.title) order by p.sort_order,p.title)
     from public.yt_freeflow_menu_items i join public.yt_shop_products p on p.id=i.product_id where i.menu_id=s.menu_id and p.active and p.is_drink),'[]')) order by s.ends_at desc)
   from public.yt_freeflow_members m join public.yt_freeflow_sessions s on s.id=m.session_id
   join public.yt_freeflow_menus a on a.id=s.menu_id join public.yt_member_orders o on o.id=s.order_id
   where m.customer_id=actor),'[]');
 elsif p_action='manage' then
  day:=coalesce(nullif(p_data->>'day','')::date,private.yt_business_day(now()));
  return jsonb_build_object('menus',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'start_time',start_time,'end_time',end_time,'valid_from',valid_from,'valid_to',valid_to)) from public.yt_freeflow_menus where active),'[]'),
   'orders',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'order_no',o.order_no,'capacity',a.male_count+a.female_count,'table_label',o.table_label))
    from public.yt_ambassador_pos_sales a join public.yt_member_orders o on o.id=a.order_id where a.business_day=day and o.status not in('pending','cancelled') and o.payment_status<>'refunded'),'[]'),
   'sessions',coalesce((select jsonb_agg(to_jsonb(x)) from (
    select s.id,s.order_id,o.order_no,s.menu_id,a.name,s.capacity,s.table_label,s.status,s.starts_at,s.ends_at,
     (select count(*) from public.yt_freeflow_requests r join public.yt_freeflow_members b on b.id=r.member_id where b.session_id=s.id and r.status='served') cups,
     coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'name',coalesce(p.display_name,'会员'),'status',b.status,
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
 values(actor,'freeflow.'||p_action,'freeflow',coalesce(v_id,v_session.id,v_request.id),p_data-'token');
 return coalesce(result,'{}');
end$$;
