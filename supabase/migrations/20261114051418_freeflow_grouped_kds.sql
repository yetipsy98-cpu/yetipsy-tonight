-- Mark only the request IDs actually shown when the operator confirmed this group.
create or replace function private.yt_freeflow_complete_group(p_actor uuid,p_data jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare s public.yt_freeflow_sessions%rowtype;ids uuid[];matched integer;changed integer;
begin
 if p_actor is null or p_actor is distinct from auth.uid() or not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_data->'request_ids' is null or jsonb_typeof(p_data->'request_ids')<>'array' or jsonb_array_length(p_data->'request_ids') not between 1 and 500 then raise exception 'invalid_freeflow_action';end if;
 select array_agg(distinct value::uuid) into ids from jsonb_array_elements_text(p_data->'request_ids');
 if cardinality(ids)<>jsonb_array_length(p_data->'request_ids') then raise exception 'invalid_freeflow_action';end if;
 select * into s from public.yt_freeflow_sessions where id=(p_data->>'session_id')::uuid for update;
 if not found then raise exception 'freeflow_session_missing';end if;
 select count(*) into matched from public.yt_freeflow_requests r join public.yt_freeflow_members m on m.id=r.member_id where r.id=any(ids) and m.session_id=s.id;
 if matched<>cardinality(ids) then raise exception 'freeflow_request_missing';end if;
 perform 1 from public.yt_freeflow_requests where id=any(ids) order by id for update;
 update public.yt_freeflow_requests set status='served',served_at=clock_timestamp(),completed_by=p_actor where id=any(ids) and status='pending';
 get diagnostics changed=row_count;
 if changed>0 then insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(p_actor,'freeflow.complete_group','freeflow_session',s.id,jsonb_build_object('request_ids',to_jsonb(ids),'served_count',changed,'skipped_count',matched-changed));end if;
 return jsonb_build_object('session_id',s.id,'served_count',changed,'skipped_count',matched-changed);
end$$;
revoke all on function private.yt_freeflow_complete_group(uuid,jsonb) from public,anon,authenticated;

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
 elsif p_action in('manage','session_save','member_status','session_status','guest_recovery','session_time','pax_preview','pax_add','collect_delta') then
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
  if not exists(select 1 from public.yt_member_orders where id=v_session.order_id and status not in('pending','cancelled') and payment_status<>'refunded' and not cancel_after_refund) then raise exception 'freeflow_order_invalid';end if;
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
  if not exists(select 1 from public.yt_member_orders where id=v_session.order_id and status not in('pending','cancelled','refunded') and payment_status<>'refunded' and not cancel_after_refund) then raise exception 'freeflow_order_invalid';end if;
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
  if p_data?'items' then return private.yt_freeflow_order_batch(actor,p_guest,p_data);end if;
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
  if not exists(select 1 from public.yt_member_orders where id=v_session.order_id and status not in('pending','cancelled') and payment_status<>'refunded' and not cancel_after_refund) then raise exception 'freeflow_order_invalid';end if;
  if not exists(select 1 from public.yt_freeflow_menus where id=v_session.menu_id and active) then raise exception 'freeflow_unavailable';end if;
  select * into cfg from public.yt_play_upgrade_settings where id;
  if cfg.freeflow_gps_required then
  if cfg.bell_lat is null or cfg.bell_lng is null then raise exception 'bell_disabled';end if;
  lat:=(p_data->>'lat')::double precision;lng:=(p_data->>'lng')::double precision;
  if lat is null or lng is null or lat not between -90 and 90 or lng not between -180 and 180 then raise exception 'location_required';end if;
  distance_m:=6371000*2*asin(least(1,sqrt(power(sin(radians(lat-cfg.bell_lat)/2),2)+cos(radians(cfg.bell_lat))*cos(radians(lat))*power(sin(radians(lng-cfg.bell_lng)/2),2))));
  if distance_m>cfg.bell_radius_m then raise exception 'outside_service_area';end if;
  end if;
  if coalesce((p_data->>'proxy')::boolean,false) is not true and exists(select 1 from public.yt_freeflow_requests where coalesce(customer_id,guest_id)=actor and status='pending') then raise exception 'freeflow_wait_for_cup';end if;
  if (select count(*) from public.yt_freeflow_requests r join public.yt_freeflow_members m on m.id=r.member_id where m.session_id=v_session.id and r.status='pending')>=v_session.capacity then raise exception 'freeflow_group_full';end if;
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
  return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'session_id',s.id,'order_id',o.id,'product_id',r.product_id,'name',r.item_name,'note',r.note,'table_label',r.table_label,'requested_at',r.requested_at,
   'member_name',coalesce(p.display_name,case when m.guest_id is not null then '访客 '||upper(right(m.id::text,4)) else '会员' end),'order_no',o.order_no,
   'proxy',r.batch_id is not null,'cup_number',1+(select count(*) from public.yt_freeflow_requests x where x.member_id=r.member_id and x.status in('served','pending') and (x.requested_at,x.id)<(r.requested_at,r.id))) order by r.requested_at)
  from public.yt_freeflow_requests r join public.yt_freeflow_members m on m.id=r.member_id
  join public.yt_freeflow_sessions s on s.id=m.session_id join public.yt_member_orders o on o.id=s.order_id
  left join public.profiles p on p.id=m.customer_id where r.status='pending'),'[]');
 elsif p_action='mine' then
  -- Explicit projection: never return request timestamps or other members to customers.
  return coalesce((select jsonb_agg(jsonb_build_object('member_id',m.id,'session_id',s.id,'name',a.name,'visitor_name',case when m.guest_id is not null then '访客 '||upper(right(m.id::text,4)) end,'table_label',s.table_label,
   'status',case when o.status='cancelled' or o.payment_status='refunded' or o.cancel_after_refund or s.status='closed' or m.status='closed' then 'closed'
    when s.ends_at<=clock_timestamp() then 'expired' when s.status='paused' or m.status='paused' or not a.active then 'paused'
    when s.starts_at>clock_timestamp() then 'upcoming' else 'active' end,
   'starts_at',s.starts_at,'ends_at',s.ends_at,'group_limit',s.capacity,
   'group_pending',(select count(*) from public.yt_freeflow_requests gr join public.yt_freeflow_members gm on gm.id=gr.member_id where gm.session_id=s.id and gr.status='pending'),
   'pending_requests',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.item_name,'note',r.note,'status',r.status) order by r.requested_at) from public.yt_freeflow_requests r where r.member_id=m.id and r.status='pending'),'[]'),
   'cups',(select count(*) from public.yt_freeflow_requests r where r.member_id=m.id and r.status='served'),
   'drinks',coalesce((select jsonb_agg(to_jsonb(x)) from (select item_name name,note,count(*) quantity from public.yt_freeflow_requests where member_id=m.id and status='served' group by item_name,note order by item_name,note)x),'[]'),
   'pending',(select jsonb_build_object('id',r.id,'name',r.item_name,'note',r.note,'status',r.status) from public.yt_freeflow_requests r where coalesce(r.customer_id,r.guest_id)=actor and r.status='pending' order by r.requested_at limit 1),
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
     case when owner then coalesce((select jsonb_agg(jsonb_build_object('created_at',log.created_at,'actor_name',coalesce(log.metadata->>'actor_name',w.username,'Cashier'),
      'before_starts_at',log.metadata->'before_starts_at','before_ends_at',log.metadata->'before_ends_at',
      'starts_at',log.metadata->'starts_at','ends_at',log.metadata->'ends_at','reason',log.metadata->>'reason') order by log.created_at desc)
      from public.audit_logs log left join public.work_accounts w on w.auth_user_id=log.actor_id
      where log.action='freeflow.session_time' and log.entity_id=s.id),'[]'::jsonb) else '[]'::jsonb end time_changes,
     (select count(*) from public.yt_freeflow_requests r join public.yt_freeflow_members b on b.id=r.member_id where b.session_id=s.id and r.status='served') cups,
     coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'guest',b.guest_id is not null,'name',coalesce(p.display_name,case when b.guest_id is not null then '访客 '||upper(right(b.id::text,4)) else '会员' end),'status',b.status,
       'cups',(select count(*) from public.yt_freeflow_requests where member_id=b.id and status='served'),
       'requests',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.item_name,'note',r.note,'status',r.status,'table_label',r.table_label,
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
end$function$;
