-- Immutable physical production history, independent of order settlement and mode.
create table private.yt_kds_production_events(
 id bigint generated always as identity primary key,kind text not null,target uuid not null,cup integer not null,
 status text not null check(status in('served','cancelled')),batch_id text not null,order_id uuid,order_no text,
 table_label text,name text not null,note text,reason text,actor_id uuid,actor_name text not null,completed_at timestamptz not null,business_day date not null,
 unique(kind,target,cup,status)
);
create index yt_kds_production_day on private.yt_kds_production_events(business_day,status,completed_at desc,id desc);
alter table private.yt_kds_production_events enable row level security;
revoke all on private.yt_kds_production_events from public,anon,authenticated;

create function private.yt_kds_event_context(p_kind text,p_target uuid) returns jsonb language sql stable set search_path='' as $$
 select case p_kind
 when 'order' then (select jsonb_build_object('order_id',o.id,'order_no',o.order_no,'table_label',o.table_label,'name',i.item_name,'note',o.notes) from public.yt_member_order_items i join public.yt_member_orders o on o.id=i.order_id where i.id=p_target)
 when 'freeflow' then (select jsonb_build_object('order_id',o.id,'order_no',o.order_no,'table_label',s.table_label,'name',r.item_name,'note',r.note,'cancel_reason',r.cancel_reason) from public.yt_freeflow_requests r join public.yt_freeflow_sessions s on s.id=r.session_id join public.yt_member_orders o on o.id=s.order_id where r.id=p_target)
 when 'storebox' then (select jsonb_build_object('order_id',b.source_order_id,'order_no',o.order_no,'table_label',r.table_label,'name',coalesce(r.component_name,b.name),'note','','cancel_reason',r.cancel_reason) from public.yt_store_box_requests r join public.yt_store_boxes b on b.id=r.box_id left join public.yt_member_orders o on o.id=b.source_order_id where r.id=p_target) end
$$;
revoke all on function private.yt_kds_event_context(text,uuid) from public,anon,authenticated;

create function private.yt_kds_record_cup(p_kind text,p_target uuid,p_cup integer,p_status text,p_detail jsonb,p_context jsonb,p_actor uuid,p_at timestamptz,p_batch text default null) returns void language plpgsql set search_path='' as $$
begin
 if p_context is null or p_cup<1 then return;end if;
 if p_status='cancelled' and exists(select 1 from private.yt_kds_production_events where kind=p_kind and target=p_target and cup=p_cup and status='served') then return;end if;
 insert into private.yt_kds_production_events(kind,target,cup,status,batch_id,order_id,order_no,table_label,name,note,reason,actor_id,actor_name,completed_at,business_day)
 values(p_kind,p_target,p_cup,p_status,coalesce(p_batch,'tx:'||txid_current()::text),(p_context->>'order_id')::uuid,p_context->>'order_no',p_context->>'table_label',coalesce(nullif(p_detail->>'option',''),nullif(p_detail->>'name',''),p_context->>'name','酒款'),p_context->>'note',case when p_status='cancelled' then coalesce(p_context->>'cancel_reason','取消未出品数量') end,p_actor,coalesce((select username from public.work_accounts where auth_user_id=p_actor),'未记录'),coalesce(p_at,clock_timestamp()),private.yt_business_day(coalesce(p_at,clock_timestamp())))
 on conflict(kind,target,cup,status) do nothing;
end $$;
revoke all on function private.yt_kds_record_cup(text,uuid,integer,text,jsonb,jsonb,uuid,timestamptz,text) from public,anon,authenticated;

create function private.yt_kds_log_unit() returns trigger language plpgsql set search_path='' as $$
begin
 if new.state='served' and old.state is distinct from 'served' then perform private.yt_kds_record_cup(new.kind,new.target,new.cup,'served',new.detail,private.yt_kds_event_context(new.kind,new.target),new.served_by,new.served_at);end if;
 return null;
end $$;
revoke all on function private.yt_kds_log_unit() from public,anon,authenticated;
create trigger yt_kds_log_unit after update of state on private.yt_kds_units for each row execute function private.yt_kds_log_unit();

create function private.yt_kds_log_source() returns trigger language plpgsql set search_path='' as $$
declare k text;target_id uuid;details jsonb;ctx jsonb;at_time timestamptz;who uuid;outcome text;entry record;
begin
 target_id:=new.id;
 if tg_table_name='yt_member_order_items' then
  if new.fulfilled is not true or old.fulfilled then return null;end if;
  k:='order';outcome:='served';at_time:=new.fulfilled_at;who:=new.fulfilled_by;
  if new.item_name in('Freeflow Male','Freeflow Female') or exists(select 1 from public.yt_freeflow_packages where product_id=new.product_id) then return null;end if;
  if exists(select 1 from public.yt_store_box_product_rules where product_id=new.product_id and active) then
   select x->'selections' into details from private.yt_store_box_prep_intents p cross join lateral jsonb_array_elements(p.preps) x where p.order_id=new.order_id and x->>'item_id'=new.id::text limit 1;
   if details is null then return null;end if;
  else details:=jsonb_build_array(jsonb_build_object('name',new.item_name,'quantity',new.quantity));end if;
 elsif tg_table_name='yt_freeflow_requests' then
  if new.status not in('served','cancelled') or new.status=old.status then return null;end if;
  k:='freeflow';outcome:=new.status;at_time:=case when new.status='served' then new.served_at else clock_timestamp() end;who:=new.completed_by;
  details:=jsonb_build_array(jsonb_build_object('name',new.item_name,'quantity',1));
 else
  if new.status not in('served','cancelled') or new.status=old.status then return null;end if;
  k:='storebox';outcome:=new.status;at_time:=case when new.status='served' then new.served_at else new.cancelled_at end;who:=case when new.status='served' then new.served_by else new.cancelled_by end;
  details:=case when jsonb_array_length(coalesce(new.kds_original_selections,new.selections,'[]'))>0 then coalesce(new.kds_original_selections,new.selections) else jsonb_build_array(jsonb_build_object('name',new.component_name,'quantity',coalesce(new.kds_original_quantity,new.quantity))) end;
 end if;
 ctx:=private.yt_kds_event_context(k,target_id);
 for entry in select row_number() over(order by j.ord,n)::integer cup,j.value detail from jsonb_array_elements(coalesce(details,'[]')) with ordinality j(value,ord) cross join lateral generate_series(1,(j.value->>'quantity')::integer) n loop
  perform private.yt_kds_record_cup(k,target_id,entry.cup,outcome,entry.detail,ctx,coalesce(who,auth.uid()),at_time);
 end loop;
 return null;
end $$;
revoke all on function private.yt_kds_log_source() from public,anon,authenticated;
create trigger yt_kds_log_item after update of fulfilled on public.yt_member_order_items for each row execute function private.yt_kds_log_source();
create trigger yt_kds_log_freeflow after update of status on public.yt_freeflow_requests for each row execute function private.yt_kds_log_source();
create trigger yt_kds_log_storebox after update of status on public.yt_store_box_requests for each row execute function private.yt_kds_log_source();

-- Removed ordinary items are cancelled production, not served production.
create function private.yt_kds_log_item_cancel() returns trigger language plpgsql set search_path='' as $$
declare n integer;ctx jsonb;
begin
 if old.fulfilled or old.quantity<=0 then return case when tg_op='DELETE' then old else new end;end if;
 if tg_op='UPDATE' and new.quantity>=old.quantity then return case when tg_op='DELETE' then old else new end;end if;
 if old.item_name in('Freeflow Male','Freeflow Female') or exists(select 1 from public.yt_freeflow_packages where product_id=old.product_id) or exists(select 1 from public.yt_store_box_product_rules where product_id=old.product_id and active) then return case when tg_op='DELETE' then old else new end;end if;
 ctx:=private.yt_kds_event_context('order',old.id);
 for n in (case when tg_op='DELETE' then 1 else greatest(1,new.quantity+1) end)..old.quantity loop
  perform private.yt_kds_record_cup('order',old.id,n,'cancelled',jsonb_build_object('name',old.item_name),ctx,auth.uid(),clock_timestamp());
 end loop;return case when tg_op='DELETE' then old else new end;
end $$;
revoke all on function private.yt_kds_log_item_cancel() from public,anon,authenticated;
create trigger yt_kds_log_item_cancel before update of quantity or delete on public.yt_member_order_items for each row execute function private.yt_kds_log_item_cancel();

create function private.yt_kds_log_order_cancel() returns trigger language plpgsql set search_path='' as $$
declare i record;n integer;
begin
 if old.status='confirmed' and ((new.status='cancelled' and old.status is distinct from new.status) or (new.cancel_after_refund and not old.cancel_after_refund)) then
  for i in select * from public.yt_member_order_items where order_id=old.id and quantity>0 and not fulfilled and item_name not in('Freeflow Male','Freeflow Female') and not exists(select 1 from public.yt_freeflow_packages fp where fp.product_id=yt_member_order_items.product_id) and not exists(select 1 from public.yt_store_box_product_rules b where b.product_id=yt_member_order_items.product_id and b.active) loop
   for n in 1..i.quantity loop perform private.yt_kds_record_cup('order',i.id,n,'cancelled',jsonb_build_object('name',i.item_name),private.yt_kds_event_context('order',i.id),auth.uid(),clock_timestamp());end loop;
  end loop;
 end if;return case when tg_op='DELETE' then old else new end;
end $$;
revoke all on function private.yt_kds_log_order_cancel() from public,anon,authenticated;
create trigger yt_kds_log_order_cancel before update of status,cancel_after_refund on public.yt_member_orders for each row execute function private.yt_kds_log_order_cancel();

-- Import prior real production. Multi-KDS rows take precedence over later whole-item timestamps.
do $$
declare u record;s record;j record;ctx jsonb;details jsonb;
begin
 for u in select * from private.yt_kds_units where state='served' and served_at is not null loop
  select l.metadata->'context' into ctx from public.audit_logs l where l.action='kds.serve' and l.entity_id=u.target and l.metadata->>'kind'=u.kind and l.metadata->'cups' @> jsonb_build_array(u.cup) order by l.created_at desc limit 1;
  perform private.yt_kds_record_cup(u.kind,u.target,u.cup,'served',u.detail,coalesce(ctx,private.yt_kds_event_context(u.kind,u.target)),u.served_by,u.served_at,'legacy-multi:'||coalesce((select l.metadata->>'request_id' from public.audit_logs l where l.action='kds.serve' and l.entity_id=u.target and l.metadata->'cups' @> jsonb_build_array(u.cup) order by l.created_at desc limit 1),u.target::text||':'||u.served_at::text));
 end loop;
 for s in select 'order'::text kind,i.id target,i.fulfilled_by actor,i.fulfilled_at at_time,jsonb_build_array(jsonb_build_object('name',i.item_name,'quantity',i.quantity)) details from public.yt_member_order_items i join public.yt_member_orders o on o.id=i.order_id where i.fulfilled and i.fulfilled_at is not null and i.quantity>0 and o.source='future_pos' and i.item_name not in('Freeflow Male','Freeflow Female') and not exists(select 1 from public.yt_freeflow_packages fp where fp.product_id=i.product_id) and not exists(select 1 from public.yt_store_box_product_rules b where b.product_id=i.product_id)
 union all select 'freeflow',r.id,r.completed_by,r.served_at,jsonb_build_array(jsonb_build_object('name',r.item_name,'quantity',1)) from public.yt_freeflow_requests r where r.status='served' and r.served_at is not null
 union all select 'storebox',r.id,r.served_by,r.served_at,case when jsonb_array_length(coalesce(r.kds_original_selections,r.selections,'[]'))>0 then coalesce(r.kds_original_selections,r.selections) else jsonb_build_array(jsonb_build_object('name',r.component_name,'quantity',coalesce(r.kds_original_quantity,r.quantity))) end from public.yt_store_box_requests r where r.status='served' and r.served_at is not null loop
  for j in select row_number() over(order by a.ord,n)::integer cup,a.value detail from jsonb_array_elements(s.details) with ordinality a(value,ord) cross join lateral generate_series(1,(a.value->>'quantity')::integer) n loop
   perform private.yt_kds_record_cup(s.kind,s.target,j.cup,'served',j.detail,private.yt_kds_event_context(s.kind,s.target),s.actor,s.at_time,'legacy:'||s.kind||':'||s.target::text||':'||s.at_time::text);
  end loop;
 end loop;
end $$;

do $$
declare r record;j record;
begin
 for r in select 'freeflow'::text kind,f.id target,f.completed_by actor,l.created_at at_time,jsonb_build_array(jsonb_build_object('name',f.item_name,'quantity',1)) details from public.yt_freeflow_requests f join lateral(select created_at from public.audit_logs a where a.action='freeflow.complete' and a.metadata->>'status'='cancelled' and (a.entity_id=f.id or a.metadata->>'request_id'=f.id::text) order by created_at limit 1)l on true where f.status='cancelled'
 union all select 'storebox',b.id,b.cancelled_by,b.cancelled_at,case when jsonb_array_length(coalesce(b.kds_original_selections,b.selections,'[]'))>0 then coalesce(b.kds_original_selections,b.selections) else jsonb_build_array(jsonb_build_object('name',b.component_name,'quantity',coalesce(b.kds_original_quantity,b.quantity))) end from public.yt_store_box_requests b where b.status='cancelled' and b.cancelled_at is not null loop
  for j in select row_number() over(order by a.ord,n)::integer cup,a.value detail from jsonb_array_elements(r.details) with ordinality a(value,ord) cross join lateral generate_series(1,(a.value->>'quantity')::integer)n loop
   perform private.yt_kds_record_cup(r.kind,r.target,j.cup,'cancelled',j.detail,private.yt_kds_event_context(r.kind,r.target),r.actor,r.at_time,'legacy-cancel:'||r.target::text);
  end loop;
 end loop;
end $$;

create function private.yt_kds_production_history(p_day date,p_status text default 'served',p_source text default 'all',p_search text default '',p_offset integer default 0,p_limit integer default 80) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not coalesce(private.yt_pos_work_staff(),false) then raise exception 'staff_only';end if;
 if p_day is null or p_status not in('served','cancelled') or p_source not in('all','order','freeflow','storebox') or p_offset<0 or p_limit not between 1 and 500 or length(coalesce(p_search,''))>120 then raise exception 'invalid_filter';end if;
 with grouped as (
  select max(id) id,max(completed_at) completed_at,kind,status,order_id,order_no,table_label,name,note,reason,actor_id,actor_name,count(*)::integer quantity
  from private.yt_kds_production_events where business_day=p_day and status=p_status and (p_source='all' or kind=p_source) and (coalesce(p_search,'')='' or concat_ws(' ',table_label,order_no,name,actor_name) ilike '%'||btrim(p_search)||'%')
  group by batch_id,kind,status,order_id,order_no,table_label,name,note,reason,actor_id,actor_name
 ),page as(select * from grouped order by completed_at desc,id desc offset p_offset limit p_limit)
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(p) order by completed_at desc,id desc) from page p),'[]'),'total',(select count(*) from grouped),'offset',p_offset,'limit',p_limit) into result;
 return result;
end $$;
create function public.yt_kds_production_history(p_day date,p_status text default 'served',p_source text default 'all',p_search text default '',p_offset integer default 0,p_limit integer default 80) returns jsonb language sql stable security invoker set search_path='' as $$select private.yt_kds_production_history(p_day,p_status,p_source,p_search,p_offset,p_limit)$$;
revoke all on function private.yt_kds_production_history(date,text,text,text,integer,integer) from public,anon,authenticated;
revoke all on function public.yt_kds_production_history(date,text,text,text,integer,integer) from public,anon,authenticated;
grant execute on function private.yt_kds_production_history(date,text,text,text,integer,integer) to authenticated;
grant execute on function public.yt_kds_production_history(date,text,text,text,integer,integer) to authenticated;
create trigger yt_kds_production_signal after insert on private.yt_kds_production_events for each statement execute function private.yt_work_refresh_signal('orders');

-- Existing Owner record resets also clear the matching production ledger.
create function private.yt_kds_history_reset() returns trigger language plpgsql set search_path='' as $$
begin
 delete from private.yt_kds_production_events where kind=case tg_table_name when 'yt_member_order_items' then 'order' when 'yt_freeflow_requests' then 'freeflow' else 'storebox' end;
 return null;
end $$;
revoke all on function private.yt_kds_history_reset() from public,anon,authenticated;
create trigger yt_kds_history_reset after truncate on public.yt_member_order_items for each statement execute function private.yt_kds_history_reset();
create trigger yt_kds_history_reset after truncate on public.yt_freeflow_requests for each statement execute function private.yt_kds_history_reset();
create trigger yt_kds_history_reset after truncate on public.yt_store_box_requests for each statement execute function private.yt_kds_history_reset();
