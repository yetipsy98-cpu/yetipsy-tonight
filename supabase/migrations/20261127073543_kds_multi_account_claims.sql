create table private.yt_kds_mode(id boolean primary key default true check(id),enabled boolean not null default false,version bigint not null default 0,changed_by uuid,changed_at timestamptz);
insert into private.yt_kds_mode(id) values(true);
create table private.yt_kds_units(kind text not null check(kind in('order','freeflow','storebox')),target uuid not null,cup integer not null check(cup>0),detail jsonb not null,state text not null default 'pending' check(state in('pending','claimed','served')),claimed_by uuid,claimed_at timestamptz,served_by uuid,served_at timestamptz,primary key(kind,target,cup));
create index yt_kds_claim_owner on private.yt_kds_units(claimed_by) where state='claimed';
create table private.yt_kds_operations(id uuid primary key,actor uuid not null,payload jsonb not null,result jsonb);
alter table private.yt_kds_mode enable row level security;alter table private.yt_kds_units enable row level security;alter table private.yt_kds_operations enable row level security;
revoke all on private.yt_kds_mode,private.yt_kds_units,private.yt_kds_operations from public,anon,authenticated;
alter table public.yt_store_box_requests add column kds_original_quantity integer,add column kds_original_selections jsonb;

create function private.yt_kds_sources() returns table(kind text,target uuid,parent text,order_id uuid,name text,table_label text,order_no text,note text,created_at timestamptz,quantity integer,details jsonb)
language sql stable set search_path='' as $$
 select 'order',i.id,o.id::text,o.id,i.item_name,o.table_label,o.order_no,o.notes,o.created_at,
 case when rule.product_id is null then i.quantity else coalesce((select sum((s->>'quantity')::integer)::integer from jsonb_array_elements(prep.value->'selections') s),0) end,
 case when rule.product_id is null then jsonb_build_array(jsonb_build_object('name',i.item_name,'quantity',i.quantity)) else prep.value->'selections' end
 from public.yt_member_order_items i join public.yt_member_orders o on o.id=i.order_id
 left join public.yt_store_box_product_rules rule on rule.product_id=i.product_id and rule.active
 left join private.yt_store_box_prep_intents intent on intent.order_id=o.id
 left join lateral (select value from jsonb_array_elements(coalesce(intent.preps,'[]')) where value->>'item_id'=i.id::text limit 1) prep on true
 where o.source='future_pos' and o.status='confirmed' and o.payment_status in('unpaid','paid') and coalesce(o.backdate_approval_status,'none') not in('pending','approved') and not i.fulfilled and i.quantity>0
 and i.item_name not in('Freeflow Male','Freeflow Female') and not exists(select 1 from public.yt_freeflow_packages fp where fp.product_id=i.product_id)
 and (rule.product_id is null or jsonb_array_length(coalesce(prep.value->'selections','[]'))>0)
 union all
 select 'freeflow',r.id,coalesce(r.kitchen_batch_id::text,r.id::text),s.order_id,r.item_name,s.table_label,o.order_no,r.note,r.requested_at,1,jsonb_build_array(jsonb_build_object('name',r.item_name,'quantity',1))
 from public.yt_freeflow_requests r join public.yt_freeflow_sessions s on s.id=r.session_id join public.yt_member_orders o on o.id=s.order_id where r.status='pending'
 union all
 select 'storebox',r.id,r.id::text,b.source_order_id,b.name,r.table_label,o.order_no,'',r.requested_at,coalesce(r.kds_original_quantity,r.quantity),
 case when jsonb_array_length(coalesce(r.selections,'[]'))>0 then r.selections else jsonb_build_array(jsonb_build_object('key',r.component_key,'name',coalesce(r.component_name,b.name),'quantity',r.quantity)) end
 from public.yt_store_box_requests r join public.yt_store_boxes b on b.id=r.box_id left join public.yt_member_orders o on o.id=b.source_order_id
 where r.status in('pending','accepted','preparing') and (r.status<>'pending' or r.expires_at>clock_timestamp())
$$;
revoke all on function private.yt_kds_sources() from public,anon,authenticated;

create function private.yt_kds_seed(p_kind text,p_target uuid) returns void language plpgsql set search_path='' as $$
declare s record;
begin
 select * into s from private.yt_kds_sources() where kind=p_kind and target=p_target;
 if not found or s.quantity<1 then raise exception 'kds_target_unavailable';end if;
 if p_kind='storebox' and exists(select 1 from private.yt_kds_units where kind=p_kind and target=p_target) then return;end if;
 insert into private.yt_kds_units(kind,target,cup,detail)
 select p_kind,p_target,row_number() over(order by j.ord,n)::integer,j.value-'quantity'
 from jsonb_array_elements(s.details) with ordinality j(value,ord) cross join lateral generate_series(1,(j.value->>'quantity')::integer) n
 on conflict(kind,target,cup) do update set detail=excluded.detail where yt_kds_units.state='pending';
 if p_kind='order' then delete from private.yt_kds_units where kind=p_kind and target=p_target and cup>s.quantity and state='pending';end if;
end $$;
revoke all on function private.yt_kds_seed(text,uuid) from public,anon,authenticated;

create function private.yt_kds_snapshot() returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('enabled',m.enabled,'version',m.version,'actor',auth.uid(),'can_manage',private.yt_work_owner() or private.yt_pos_work_cashier(),
 'targets',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('units',
 case when exists(select 1 from private.yt_kds_units u where u.kind=s.kind and u.target=s.target) then
 coalesce((select jsonb_agg(jsonb_build_object('cup',u.cup,'detail',u.detail,'state',u.state,'owner',u.claimed_by,'username',coalesce(w.username,'工作账号'),'claimed_at',u.claimed_at) order by u.cup) from (select a.* from private.yt_kds_units a where a.kind=s.kind and a.target=s.target union all select s.kind,s.target,t.cup,t.detail,'pending',null::uuid,null::timestamptz,null::uuid,null::timestamptz from (select row_number() over(order by j.ord,n)::integer cup,j.value-'quantity' detail from jsonb_array_elements(s.details) with ordinality j(value,ord) cross join lateral generate_series(1,(j.value->>'quantity')::integer) n)t where s.kind='order' and not exists(select 1 from private.yt_kds_units z where z.kind=s.kind and z.target=s.target and z.cup=t.cup)) u left join public.work_accounts w on w.auth_user_id=u.claimed_by where u.kind=s.kind and u.target=s.target and (s.kind='storebox' or u.cup<=s.quantity)),'[]')
 else coalesce((select jsonb_agg(jsonb_build_object('cup',t.cup,'detail',t.detail,'state','pending') order by t.cup) from(select row_number() over(order by j.ord,n)::integer cup,j.value-'quantity' detail from jsonb_array_elements(s.details) with ordinality j(value,ord) cross join lateral generate_series(1,(j.value->>'quantity')::integer) n)t),'[]') end) order by s.created_at,s.target) from private.yt_kds_sources() s),'[]'),
 'active_claims',(select count(*) from private.yt_kds_units u where state='claimed' and exists(select 1 from private.yt_kds_sources() s where s.kind=u.kind and s.target=u.target)))
 from private.yt_kds_mode m where id
$$;
revoke all on function private.yt_kds_snapshot() from public,anon,authenticated;

-- Old clients must not be able to confirm another account's production.
create function private.yt_kds_completion_guard() returns trigger language plpgsql set search_path='' as $$
declare k text;v_target uuid;total integer;mode boolean;
begin
 if tg_table_name='yt_member_order_items' then
  if new.fulfilled is not true or old.fulfilled then return new;end if;k:='order';v_target:=old.id;
  if not exists(select 1 from private.yt_kds_sources() s where s.kind='order' and s.target=old.id) and not exists(select 1 from private.yt_kds_units where kind='order' and target=old.id) then return new;end if;
  if old.item_name in('Freeflow Male','Freeflow Female') or exists(select 1 from public.yt_freeflow_packages p where p.product_id=old.product_id) then return new;end if;
  if exists(select 1 from public.yt_store_box_product_rules r where r.product_id=old.product_id and r.active) and not exists(select 1 from private.yt_store_box_prep_intents p cross join lateral jsonb_array_elements(p.preps) x where p.order_id=old.order_id and x->>'item_id'=old.id::text and jsonb_array_length(coalesce(x->'selections','[]'))>0) then return new;end if;
 elsif tg_table_name='yt_freeflow_requests' then
  if new.status<>'served' or old.status='served' then return new;end if;k:='freeflow';v_target:=old.id;
 else
  if new.status<>'served' or old.status='served' then return new;end if;k:='storebox';v_target:=old.id;
 end if;
 perform pg_advisory_xact_lock_shared(hashtextextended('yt.kds.mode',0));
 select m.enabled into mode from private.yt_kds_mode m where m.id;
 if mode then
  if k='order' then if (select count(*) from private.yt_kds_units where kind=k and target=v_target)<coalesce((select s.quantity from private.yt_kds_sources() s where s.kind=k and s.target=v_target),old.quantity) then raise exception 'kds_claim_required';end if;end if;
  if not exists(select 1 from private.yt_kds_units where kind=k and target=v_target) or exists(select 1 from private.yt_kds_units where kind=k and target=v_target and state<>'served') then raise exception 'kds_claim_required';end if;
 else
  update private.yt_kds_units set state='served',served_by=auth.uid(),served_at=clock_timestamp() where kind=k and target=v_target and state<>'served';
 end if;
 return new;
end $$;
revoke all on function private.yt_kds_completion_guard() from public,anon,authenticated;
create trigger yt_kds_item_guard before update of fulfilled on public.yt_member_order_items for each row execute function private.yt_kds_completion_guard();
create trigger yt_kds_freeflow_guard before update of status on public.yt_freeflow_requests for each row execute function private.yt_kds_completion_guard();
create trigger yt_kds_store_guard before update of status on public.yt_store_box_requests for each row execute function private.yt_kds_completion_guard();

-- Partial Store Box production deducts the exact chosen components immediately.
-- Remaining reservations retain their original request id and cup identities.
create function private.yt_kds_order_guard() returns trigger language plpgsql set search_path='' as $$
begin
 if old.status='confirmed' and new.status='fulfilled' then
  perform pg_advisory_xact_lock_shared(hashtextextended('yt.kds.mode',0));
  if (select enabled from private.yt_kds_mode where id) and exists(select 1 from private.yt_kds_sources() s where s.kind='order' and s.order_id=old.id and (select count(*) from private.yt_kds_units u where u.kind=s.kind and u.target=s.target and u.state='served')<s.quantity) then raise exception 'kds_claim_required';end if;
 end if;return new;
end $$;
revoke all on function private.yt_kds_order_guard() from public,anon,authenticated;
create trigger yt_kds_order_guard before update of status on public.yt_member_orders for each row execute function private.yt_kds_order_guard();

create function private.yt_kds_item_edit_guard() returns trigger language plpgsql set search_path='' as $$
begin
 if (new.quantity,new.product_id,new.item_name) is distinct from (old.quantity,old.product_id,old.item_name) and (select enabled from private.yt_kds_mode where id) then
  if exists(select 1 from private.yt_kds_units where kind='order' and target=old.id and state='claimed') or (not old.fulfilled and new.quantity>0 and new.quantity<coalesce((select max(cup) from private.yt_kds_units where kind='order' and target=old.id and state='served'),0)) then raise exception 'kds_item_in_progress';end if;
 end if;return new;
end $$;
revoke all on function private.yt_kds_item_edit_guard() from public,anon,authenticated;
create trigger yt_kds_item_edit_guard before update of quantity,product_id,item_name on public.yt_member_order_items for each row execute function private.yt_kds_item_edit_guard();
create function private.yt_kds_refresh_line() returns trigger language plpgsql set search_path='' as $$
begin
 if exists(select 1 from private.yt_kds_units where kind='order' and target=new.id) and exists(select 1 from private.yt_kds_sources() s where s.kind='order' and s.target=new.id) then perform private.yt_kds_seed('order',new.id);end if;
 return null;
end $$;
revoke all on function private.yt_kds_refresh_line() from public,anon,authenticated;
create trigger yt_kds_refresh_line after update of quantity,product_id,item_name on public.yt_member_order_items for each row execute function private.yt_kds_refresh_line();


create function private.yt_kds_store_partial(p_target uuid,p_cups integer[]) returns jsonb language plpgsql set search_path='' as $$
declare r public.yt_store_box_requests%rowtype;b public.yt_store_boxes%rowtype;sel jsonb;parts jsonb;rest jsonb;n integer:=cardinality(p_cups);result jsonb;
begin
 select * into r from public.yt_store_box_requests where id=p_target for update;
 if n=r.quantity then
  result:=private.yt_store_box_request_action(r.id,'serve',0,'');
  if r.kds_original_quantity is not null then update public.yt_store_box_requests set quantity=r.kds_original_quantity where id=r.id;end if;
  return result;
 end if;
 select * into b from public.yt_store_boxes where id=r.box_id for update;
 if r.status not in('pending','accepted','preparing') or n<1 or n>r.quantity then raise exception 'kds_target_unavailable';end if;
 if not(b.status='active' or b.status='unclaimed' and (b.cashier_managed and r.customer_id is null or (private.yt_pos_work_cashier() or private.yt_work_owner()) and r.customer_id is not distinct from b.customer_id)) or b.storage_expires_at is null or b.storage_expires_at<=clock_timestamp() then raise exception 'store_box_not_available';end if;
 select jsonb_agg(x.detail||jsonb_build_object('quantity',x.n)) into sel from(select detail,count(*)::integer n from private.yt_kds_units where kind='storebox' and target=p_target and cup=any(p_cups) group by detail)x;
 if exists(select 1 from jsonb_array_elements(sel) s where not exists(select 1 from jsonb_array_elements(b.components) c where c->>'key'=s->>'key' and (c->>'total_units')::integer-(c->>'served_units')::integer>=(s->>'quantity')::integer)) then raise exception 'store_box_component_unavailable';end if;
 select jsonb_agg(jsonb_set(c,'{served_units}',to_jsonb((c->>'served_units')::integer+coalesce((select sum((s->>'quantity')::integer) from jsonb_array_elements(sel) s where s->>'key'=c->>'key'),0))) order by ord) into parts from jsonb_array_elements(b.components) with ordinality e(c,ord);
 select jsonb_agg(x.detail||jsonb_build_object('quantity',x.n)) into rest from(select detail,count(*)::integer n from private.yt_kds_units where kind='storebox' and target=p_target and state<>'served' group by detail)x;
 update public.yt_store_box_requests set quantity=quantity-n,selections=rest,kds_original_quantity=coalesce(kds_original_quantity,quantity),kds_original_selections=coalesce(kds_original_selections,selections) where id=r.id;
 update public.yt_store_boxes set served_units=served_units+n,components=parts,updated_at=clock_timestamp() where id=b.id returning * into b;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,completed_delta,actor_id,metadata) values(b.id,r.id,'drink_served',n,0,auth.uid(),jsonb_build_object('selections',sel,'multi_kds',true));
 return jsonb_build_object('partial',true,'box',to_jsonb(b));
end $$;
revoke all on function private.yt_kds_store_partial(uuid,integer[]) from public,anon,authenticated;

-- A later direct serve with the mode switched off also completes only the remaining cups.
alter function private.yt_store_box_request_action(uuid,text,integer,text) rename to yt_store_box_request_action_before_multi;
create function private.yt_store_box_request_action(p_request uuid,p_action text,p_completed_delta integer default 0,p_reason text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;original integer;
begin
 if auth.uid() is null or not coalesce(private.yt_pos_work_staff(),false) then raise exception 'staff_only';end if;
 result:=private.yt_store_box_request_action_before_multi(p_request,p_action,p_completed_delta,p_reason);
 if p_action='serve' then select kds_original_quantity into original from public.yt_store_box_requests where id=p_request;
  if original is not null then update public.yt_store_box_requests set quantity=original,selections=coalesce(kds_original_selections,selections) where id=p_request;result:=result||jsonb_build_object('request',(select to_jsonb(r) from public.yt_store_box_requests r where r.id=p_request));end if;
 end if;
 return result;
end $$;
revoke all on function private.yt_store_box_request_action(uuid,text,integer,text) from public,anon,authenticated;
grant execute on function private.yt_store_box_request_action(uuid,text,integer,text) to authenticated;
create or replace function public.yt_store_box_request_action(p_request uuid,p_action text,p_completed_delta integer,p_reason text) returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_request_action(p_request,p_action,p_completed_delta,p_reason)$$;
revoke all on function public.yt_store_box_request_action(uuid,text,integer,text) from public,anon;
grant execute on function public.yt_store_box_request_action(uuid,text,integer,text) to authenticated;

create function private.yt_kds_multi(p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();manager boolean;v_enabled boolean;v bigint;op uuid;payload jsonb;prior private.yt_kds_operations%rowtype;j jsonb;k text;v_target uuid;oid uuid;cups integer[];n integer;matched integer;v_result jsonb;context jsonb;ownership jsonb;events jsonb:='[]';boxes jsonb:='[]';claimed_count integer;
begin
 if actor is null or not coalesce(private.yt_pos_work_staff(),false) then raise exception 'staff_only';end if;
 manager:=coalesce(private.yt_work_owner() or private.yt_pos_work_cashier(),false);
 if p_action='snapshot' then return private.yt_kds_snapshot();end if;
 if p_action='history' then return coalesce((select jsonb_agg(to_jsonb(x)) from(select l.created_at,l.action,l.entity_id,l.metadata,coalesce(w.username,'工作账号') username from public.audit_logs l left join public.work_accounts w on w.auth_user_id=l.actor_id where l.action in('kds.claim','kds.release','kds.serve','kds.cancel','kds.mode') and (not(p_data?'day') or private.yt_business_day(l.created_at)=(p_data->>'day')::date) order by l.created_at desc limit 150)x),'[]');end if;
 op:=(p_data->>'request_id')::uuid;if op is null then raise exception 'invalid_kds_request';end if;
 payload:=jsonb_build_object('action',p_action,'data',p_data-'request_id');
 insert into private.yt_kds_operations(id,actor,payload) values(op,actor,payload) on conflict do nothing;
 select * into prior from private.yt_kds_operations where yt_kds_operations.id=op for update;
 if prior.actor<>actor or prior.payload<>payload then raise exception 'request_conflict';end if;
 if prior.result is not null then return prior.result;end if;
 if p_action='mode' then
  if not manager then raise exception 'cashier_only';end if;
  perform pg_advisory_xact_lock(hashtextextended('yt.kds.mode',0));
  select version into v from private.yt_kds_mode where yt_kds_mode.id;
  if (p_data->>'expected_version')::bigint is distinct from v then raise exception 'kds_mode_changed';end if;
  v_enabled:=(p_data->>'enabled')::boolean;if v_enabled is null then raise exception 'invalid_kds_request';end if;
  if not v_enabled and not coalesce((p_data->>'confirmed')::boolean,false) and exists(select 1 from private.yt_kds_units u where state='claimed' and exists(select 1 from private.yt_kds_sources() s where s.kind=u.kind and s.target=u.target)) then raise exception 'kds_active_claims';end if;
  if not v_enabled then
   insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) select actor,'kds.release','kds_target',target,jsonb_build_object('kind',kind,'cup',cup,'previous_owner',claimed_by,'reason','关闭多人接单模式') from private.yt_kds_units where state='claimed';
   update private.yt_kds_units set state='pending',claimed_by=null,claimed_at=null where state='claimed';
  end if;
  update private.yt_kds_mode set enabled=v_enabled,version=version+1,changed_by=actor,changed_at=clock_timestamp();
  insert into public.audit_logs(actor_id,action,entity_type,metadata) values(actor,'kds.mode','kds',jsonb_build_object('enabled',v_enabled));
 else
  if p_action not in('claim','release','serve','cancel') or jsonb_typeof(p_data->'items') is distinct from 'array' or jsonb_array_length(p_data->'items') not between 1 and 500 then raise exception 'invalid_kds_request';end if;
  if (select count(distinct x->>'kind') from jsonb_array_elements(p_data->'items') x)<>1 then raise exception 'invalid_kds_request';end if;
  -- The old Store Box mutation uses this lock before request and box row locks.
  if exists(select 1 from jsonb_array_elements(p_data->'items') x where x->>'kind'='storebox') then perform pg_advisory_xact_lock(781943084);end if;
  -- Lock ordinary order headers before their line rows, matching existing fulfillment.
  perform 1 from public.yt_member_orders o where o.id in(select i.order_id from public.yt_member_order_items i join jsonb_array_elements(p_data->'items') x on x->>'kind'='order' and i.id=(x->>'target')::uuid) order by o.id for update;
  for j in select value from jsonb_array_elements(p_data->'items') order by value->>'kind',value->>'target' loop
   k:=j->>'kind';v_target:=(j->>'target')::uuid;
   if k='order' then perform 1 from public.yt_member_order_items where yt_member_order_items.id=v_target for update;
   elsif k='freeflow' then perform 1 from public.yt_freeflow_requests where yt_freeflow_requests.id=v_target for update;
   elsif k='storebox' then perform 1 from public.yt_store_box_requests where yt_store_box_requests.id=v_target for update;
   else raise exception 'invalid_kds_request';end if;
  end loop;
  perform pg_advisory_xact_lock_shared(hashtextextended('yt.kds.mode',0));
  if not(select m.enabled from private.yt_kds_mode m where m.id) then raise exception 'kds_mode_disabled';end if;
  for j in select value from jsonb_array_elements(p_data->'items') order by value->>'kind',value->>'target' loop
   k:=j->>'kind';v_target:=(j->>'target')::uuid;
   if jsonb_typeof(j->'cups') is distinct from 'array' or jsonb_array_length(j->'cups') not between 1 and 500 then raise exception 'invalid_kds_request';end if;
   select array_agg(value::integer order by value::integer) into cups from jsonb_array_elements_text(j->'cups');n:=cardinality(cups);
   if n<>(select count(distinct x) from unnest(cups) x) then raise exception 'invalid_kds_request';end if;
   perform private.yt_kds_seed(k,v_target);
   select to_jsonb(s)-'details' into context from private.yt_kds_sources() s where s.kind=k and s.target=v_target;
   select jsonb_agg(jsonb_build_object('cup',u.cup,'name',u.detail->>'name','owner',u.claimed_by,'state',u.state)) into ownership from private.yt_kds_units u where u.kind=k and u.target=v_target and u.cup=any(cups);
   if p_action='cancel' then
    if (select count(*) from private.yt_kds_units where kind=k and target=v_target and cup=any(cups) and state<>'served')<>n then raise exception 'kds_claim_changed';end if;
    if length(btrim(coalesce(p_data->>'reason',''))) not between 2 and 200 then raise exception 'reason_required';end if;
    if k='freeflow' and manager then perform private.yt_freeflow('complete',jsonb_build_object('request_id',v_target,'status','cancelled','reason',p_data->>'reason'));
    elsif k='storebox' and n=(select count(*) from private.yt_kds_units where kind=k and target=v_target and state<>'served') then perform private.yt_store_box_request_action(v_target,'cancel',0,p_data->>'reason');
    else raise exception 'kds_cancel_not_allowed';end if;
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'kds.cancel','kds_target',v_target,jsonb_build_object('context',context,'before',ownership,'kind',k,'cups',cups,'reason',p_data->>'reason','request_id',op));
    continue;
   end if;
   if p_action='claim' then
    update private.yt_kds_units set state='claimed',claimed_by=actor,claimed_at=clock_timestamp() where kind=k and target=v_target and cup=any(cups) and state='pending';
   elsif p_action='release' then
    update private.yt_kds_units set state='pending',claimed_by=null,claimed_at=null where kind=k and target=v_target and cup=any(cups) and state='claimed' and (claimed_by=actor or manager);
   else
    update private.yt_kds_units set state='served',served_by=actor,served_at=clock_timestamp() where kind=k and target=v_target and cup=any(cups) and state='claimed' and claimed_by=actor;
   end if;
   get diagnostics matched=row_count;
   if matched<>n then raise exception 'kds_claim_changed';end if;
   if p_action='claim' and k='storebox' then
    update public.yt_store_box_requests set status='accepted',accepted_by=actor,accepted_at=clock_timestamp() where yt_store_box_requests.id=v_target and status='pending';
   elsif p_action='serve' then
    if k='order' then
     if not exists(select 1 from private.yt_kds_units where kind=k and target=v_target and state<>'served') then
      select order_id into oid from public.yt_member_order_items where yt_member_order_items.id=v_target;
      perform public.yt_pos_item_fulfill(oid,v_target,false);
     end if;
    elsif k='freeflow' then perform private.yt_freeflow('complete',jsonb_build_object('request_id',v_target,'status','served'));
    else
     v_result:=private.yt_kds_store_partial(v_target,cups);
     if not coalesce((v_result->>'partial')::boolean,false) then boxes:=boxes||jsonb_build_array(v_result->'box');end if;
    end if;
   end if;
   insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'kds.'||p_action,'kds_target',v_target,jsonb_build_object('context',context,'before',ownership,'kind',k,'cups',cups,'request_id',op));
  end loop;
 end if;
 v_result:=jsonb_build_object('ok',true,'boxes',boxes);
 update private.yt_kds_operations set result=v_result where yt_kds_operations.id=op;
 return v_result;
end $$;
create function public.yt_kds_multi(p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select private.yt_kds_multi(p_action,p_data)$$;
revoke all on function private.yt_kds_multi(text,jsonb) from public,anon,authenticated;
revoke all on function public.yt_kds_multi(text,jsonb) from public,anon,authenticated;
grant execute on function private.yt_kds_multi(text,jsonb) to authenticated;
grant execute on function public.yt_kds_multi(text,jsonb) to authenticated;

-- Reuse authorised, coalesced invalidation topics; payloads contain no order data.
create trigger yt_kds_live_units after insert or update or delete on private.yt_kds_units for each statement execute function private.yt_work_refresh_signal('orders');
create trigger yt_kds_live_mode after update on private.yt_kds_mode for each statement execute function private.yt_work_refresh_signal('orders');

-- Existing customer and cashier creation retries compare against the immutable
-- original request, even after some of its cups have already been served.
do $$
declare fn record;def text;anchor integer;branch integer;alias text;injection text;
begin
 for fn in select p.oid,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' and p.proname in('yt_store_box_cashier_direct_issue','yt_store_box_cashier_request','yt_store_box_request_v3','yt_store_box_request_v3_legacy') loop
  def:=pg_get_functiondef(fn.oid);anchor:=strpos(def,'client_request_id=p_request');
  if anchor=0 then raise exception 'kds_replay_guard_missing_%',fn.proname;end if;
  branch:=strpos(substr(def,anchor),'if found then');if branch=0 then raise exception 'kds_replay_branch_missing_%',fn.proname;end if;
  branch:=anchor+branch-1+length('if found then');
  alias:=case when fn.proname='yt_store_box_cashier_direct_issue' then 'existing_request' else 'r' end;
  injection:=format(' %1$s.quantity:=coalesce(%1$s.kds_original_quantity,%1$s.quantity); %1$s.selections:=coalesce(%1$s.kds_original_selections,%1$s.selections); ',alias);
  def:=substr(def,1,branch-1)||injection||substr(def,branch);execute def;
 end loop;
end $$;
