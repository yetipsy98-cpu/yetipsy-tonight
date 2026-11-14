-- Group capacity, same-order additional people, and atomic multi-cup ordering.
alter table public.yt_freeflow_requests add column if not exists batch_payload jsonb;
alter table public.yt_freeflow_requests add column if not exists batch_id uuid;
drop index if exists public.yt_freeflow_one_pending_cup;
drop index if exists public.yt_freeflow_guest_pending_cup;
create index if not exists yt_freeflow_pending_member on public.yt_freeflow_requests(member_id) where status='pending';
create index if not exists yt_freeflow_pax_audit on public.audit_logs(entity_id,created_at desc) where action='freeflow.pax_add';

create or replace function private.yt_freeflow_pax(actor uuid,p_action text,data jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare o public.yt_member_orders%rowtype;s public.yt_ambassador_pos_sales%rowtype;g public.yt_freeflow_sessions%rowtype;
 male integer;female integer;delta numeric;req uuid;prior jsonb;payload jsonb;owed numeric;line_id uuid;business date;
begin
 if actor is null or actor is distinct from auth.uid() or not (private.yt_pos_work_cashier() or private.yt_work_owner()) then raise exception 'cashier_only';end if;
 if p_action not in('pax_preview','pax_add','collect_delta') then raise exception 'invalid_freeflow_action';end if;
 perform pg_advisory_xact_lock(hashtextextended('freeflow-session:'||(data->>'order_id'),0));
 select * into g from public.yt_freeflow_sessions where order_id=(data->>'order_id')::uuid for update;
 select * into o from public.yt_member_orders where id=(data->>'order_id')::uuid and source='future_pos' for update;
 select * into s from public.yt_ambassador_pos_sales where order_id=o.id for update;
 if s.order_id is null or o.status in('pending','cancelled','refunded') or o.payment_status not in('unpaid','paid') or o.cancel_after_refund then raise exception 'freeflow_order_invalid';end if;
 if p_action='collect_delta' then
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
  if o.amount_rm<>round(s.male_count*s.male_price+s.female_count*s.female_price,2) then raise exception 'freeflow_order_changed';end if;
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
end$$;
revoke all on function private.yt_freeflow_pax(uuid,text,jsonb) from public,anon,authenticated;

create or replace function private.yt_freeflow_order_batch(actor uuid,is_guest boolean,data jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare member public.yt_freeflow_members%rowtype;s public.yt_freeflow_sessions%rowtype;first_row public.yt_freeflow_requests%rowtype;
 item jsonb;items jsonb:=data->'items';payload jsonb;batch uuid;child uuid;result jsonb;ids jsonb:='[]';total integer:=0;n integer:=0;i integer;
begin
 if items is null or jsonb_typeof(items)<>'array' or jsonb_array_length(items) not between 1 and 500 then raise exception 'invalid_freeflow_batch';end if;
 batch:=(data->>'request_id')::uuid;if batch is null then raise exception 'invalid_freeflow_batch';end if;
 payload:=jsonb_build_object('member_id',data->>'member_id','items',items,'note',btrim(coalesce(data->>'note','')),'actor',actor,'guest',is_guest);
 perform pg_advisory_xact_lock(hashtextextended('freeflow-member:'||actor::text,0));
 select * into member from public.yt_freeflow_members where id=(data->>'member_id')::uuid and coalesce(customer_id,guest_id)=actor;
 if not found then raise exception 'freeflow_member_missing';end if;
 select * into s from public.yt_freeflow_sessions where id=member.session_id for update;
 child:=md5(batch::text||':1')::uuid;
 select * into first_row from public.yt_freeflow_requests where request_id=child;
 if found then
  if first_row.batch_payload is distinct from payload then raise exception 'request_conflict';end if;
  return jsonb_build_object('id',first_row.id,'idempotent',true);
 end if;
 for item in select value from jsonb_array_elements(items) loop
  if jsonb_typeof(item)<>'object' or coalesce(item->>'quantity','')!~'^[0-9]+$' then raise exception 'invalid_freeflow_batch';end if;
  i:=(item->>'quantity')::integer;if i<1 or i>500 then raise exception 'invalid_freeflow_batch';end if;total:=total+i;
 end loop;
 if total<1 or total>s.capacity then raise exception 'freeflow_group_full';end if;
 if (select count(*) from public.yt_freeflow_requests r join public.yt_freeflow_members m on m.id=r.member_id where m.session_id=s.id and r.status='pending')+total>s.capacity then raise exception 'freeflow_group_full';end if;
 for item in select value from jsonb_array_elements(items) loop
  for i in 1..(item->>'quantity')::integer loop
   n:=n+1;child:=md5(batch::text||':'||n::text)::uuid;
   result:=private.yt_freeflow_core(actor,is_guest,'order',jsonb_build_object('member_id',member.id,'product_id',item->>'product_id','request_id',child,'note',btrim(coalesce(data->>'note','')),'lat',data->'lat','lng',data->'lng','proxy',true));
   update public.yt_freeflow_requests set batch_id=batch,batch_payload=case when n=1 then payload end where id=(result->>'id')::uuid;
   ids:=ids||jsonb_build_array(result->>'id');
  end loop;
 end loop;
 return jsonb_build_object('ids',ids,'quantity',total,'status','pending');
end$$;
revoke all on function private.yt_freeflow_order_batch(uuid,boolean,jsonb) from public,anon,authenticated;

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
 elsif p_action in('queue','order_binding','token','bind_member') then
  if not staff then raise exception 'staff_only';end if;
 elsif p_action='complete' then
  if not staff then raise exception 'staff_only';end if;
 elsif p_action in('menus','menu_save') then
  if not owner then raise exception 'owner_only';end if;
 elsif p_action in('manage','session_save','member_status','session_status','guest_recovery','session_time','pax_preview','pax_add','collect_delta') then
  if not manager then raise exception 'cashier_only';end if;
 else raise exception 'invalid_freeflow_action';end if;

 if p_action in('pax_preview','pax_add','collect_delta') then return private.yt_freeflow_pax(actor,p_action,p_data);
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
  return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.item_name,'note',r.note,'table_label',r.table_label,'requested_at',r.requested_at,
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
CREATE OR REPLACE FUNCTION private.yt_pos_adjustment_pay(p_order uuid, p_amount numeric, p_method text, p_note text, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_member_orders%rowtype;e public.yt_pos_payment_entries%rowtype;balance numeric;entry_method text;
begin
 if not private.yt_work_owner() and not (private.yt_pos_work_cashier() and p_amount>0 and exists(select 1 from public.yt_ambassador_pos_sales where order_id=p_order) and exists(select 1 from public.audit_logs where action='freeflow.pax_add' and entity_id=p_order)) then raise exception 'owner_only';end if;
 if p_request is null or p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount=0 or abs(p_amount)>100000 or p_amount<>round(p_amount,2) or p_method is null or p_method not in ('foodcourt','cash','duitnow','card','bank_transfer','other') or length(btrim(coalesce(p_note,''))) not between 2 and 300 then raise exception 'invalid_adjustment_payment';end if;
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
 if p_amount>0 and exists(select 1 from public.yt_ambassador_pos_sales where order_id=p_order) then
  update public.yt_ambassador_checkins c set male_count=s.male_count,female_count=s.female_count,
   sales=least(v.amount_rm,private.yt_pos_received(p_order)),commission_amount=round(least(v.amount_rm,private.yt_pos_received(p_order))*s.commission_rate/100,2)
   from public.yt_ambassador_pos_sales s where s.order_id=p_order and c.request_id=p_order;
  insert into public.yt_ambassador_ledger(ambassador_id,checkin_id,entry_type,amount,created_by,business_day,note)
   select c.ambassador_id,c.id,'commission',c.commission_amount,auth.uid(),c.business_day,'FreeFlow 加人数已收款佣金' from public.yt_ambassador_checkins c
   where c.request_id=p_order and c.commission_amount>0 on conflict(checkin_id) do update set amount=excluded.amount;
 end if;
 return private.yt_pos_owner_order_context(p_order);
end $function$;
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
   (p_scope='active' and ((x.status in ('pending','confirmed') and x.payment_status in ('unpaid','paid')) or (x.status='fulfilled' and (x.payment_status='unpaid' or (x.payment_status='paid' and x.amount_rm>private.yt_pos_received(x.id) and exists(select 1 from public.yt_ambassador_pos_sales ff where ff.order_id=x.id))))))
   or (p_scope='pending' and x.status='pending') or (p_scope='paid' and x.payment_status in ('paid','refunded'))
   or p_scope='all' or (p_scope='mine' and x.created_by=auth.uid())
  ) order by x.created_at desc limit p_limit
 ) o;
 return v_result;
end;
$function$;
