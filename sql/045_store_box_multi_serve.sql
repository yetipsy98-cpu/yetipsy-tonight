-- V16.9 Complete Store Box combination serving in one customer request.

alter table public.yt_store_box_requests add column if not exists selections jsonb not null default '[]'::jsonb;

do $$begin
 if not exists(select 1 from pg_constraint where conname='yt_store_box_requests_selections_check') then
  alter table public.yt_store_box_requests add constraint yt_store_box_requests_selections_check check(jsonb_typeof(selections)='array');
 end if;
end$$;

update public.yt_store_box_requests
set selections=jsonb_build_array(jsonb_build_object('key',component_key,'name',coalesce(component_name,component_key),'quantity',quantity))
where jsonb_array_length(selections)=0 and component_key is not null;

create or replace function private.yt_store_box_request_v3(
 p_box uuid,p_quantity integer,p_selections jsonb,p_request uuid,p_table_label text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 actor uuid:=auth.uid();b public.yt_store_boxes%rowtype;r public.yt_store_box_requests%rowtype;
 component jsonb;normalized jsonb:='[]'::jsonb;requested integer:=0;needed integer;available integer;take_qty integer;choice_qty integer;
 summary text;single_key text;single_name text;
begin
 if not private.yt_store_box_customer() then raise exception 'customer_only';end if;
 if p_box is null or p_request is null or p_quantity is null or p_quantity<1 or p_quantity>99 or length(coalesce(p_table_label,''))>40 then raise exception 'invalid_store_box_request';end if;
 if jsonb_typeof(coalesce(p_selections,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_selections,'[]'::jsonb))>20 then raise exception 'invalid_store_box_selection';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into r from public.yt_store_box_requests where client_request_id=p_request;
 if found then
  if r.box_id<>p_box or r.quantity<>p_quantity or r.customer_id<>actor then raise exception 'request_conflict';end if;
  return to_jsonb(r);
 end if;
 select * into b from public.yt_store_boxes where id=p_box and customer_id=actor for update;
 if not found then raise exception 'store_box_not_found';end if;
 update public.yt_store_box_requests set status='expired' where box_id=b.id and status='pending' and expires_at<=clock_timestamp();
 if b.storage_expires_at<=clock_timestamp() then raise exception 'store_box_expired';end if;
 if b.status<>'active' or b.served_units>=b.total_units then raise exception 'store_box_not_available';end if;

 if b.selection_mode='customer' then
  if jsonb_array_length(coalesce(p_selections,'[]'::jsonb))=0 or exists(
   select 1 from jsonb_array_elements(p_selections) s
   where jsonb_typeof(s)<>'object' or nullif(btrim(coalesce(s->>'key','')),'') is null
    or coalesce(s->>'quantity','')!~'^[0-9]+$' or (s->>'quantity')::integer not between 1 and 99
  ) then raise exception 'invalid_store_box_selection';end if;
  if exists(
   select 1 from jsonb_array_elements(p_selections) s
   where not exists(select 1 from jsonb_array_elements(b.components) c where c->>'key'=s->>'key')
  ) then raise exception 'store_box_component_unavailable';end if;
  for component in select x from jsonb_array_elements(b.components) with ordinality e(x,n) order by n loop
   select coalesce(sum((s->>'quantity')::integer),0) into choice_qty from jsonb_array_elements(p_selections) s where s->>'key'=component->>'key';
   if choice_qty>0 then
    available:=(component->>'total_units')::integer-(component->>'served_units')::integer;
    if choice_qty>available then raise exception 'store_box_component_unavailable';end if;
    normalized:=normalized||jsonb_build_array(jsonb_build_object('key',component->>'key','name',component->>'name','quantity',choice_qty));
    requested:=requested+choice_qty;
   end if;
  end loop;
 else
  needed:=p_quantity;
  for component in select x from jsonb_array_elements(b.components) with ordinality e(x,n) order by n loop
   available:=greatest(0,(component->>'total_units')::integer-(component->>'served_units')::integer);
   take_qty:=least(available,needed);
   if take_qty>0 then
    normalized:=normalized||jsonb_build_array(jsonb_build_object('key',component->>'key','name',component->>'name','quantity',take_qty));
    requested:=requested+take_qty;needed:=needed-take_qty;
   end if;
   exit when needed=0;
  end loop;
  if needed>0 then raise exception 'store_box_quantity_unavailable';end if;
 end if;
 if requested<>p_quantity or requested>b.request_limit or requested>b.total_units-b.served_units then raise exception 'store_box_quantity_unavailable';end if;

 if exists(select 1 from public.yt_store_box_requests where box_id=b.id and status in ('pending','accepted','preparing')) then raise exception 'store_box_request_already_active';end if;
 select string_agg(s->>'name'||'×'||(s->>'quantity'),' · ' order by n) into summary from jsonb_array_elements(normalized) with ordinality e(s,n);
 if jsonb_array_length(normalized)=1 then single_key:=normalized->0->>'key';single_name:=normalized->0->>'name';end if;
 insert into public.yt_store_box_requests(box_id,customer_id,quantity,component_key,component_name,selections,client_request_id,table_label)
 values(b.id,actor,requested,single_key,coalesce(single_name,summary),normalized,p_request,nullif(btrim(p_table_label),'')) returning * into r;
 update public.yt_store_boxes set table_label=coalesce(nullif(btrim(p_table_label),''),table_label),updated_at=clock_timestamp() where id=b.id;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,customer_id,metadata)
 values(b.id,r.id,'drink_requested',requested,actor,jsonb_build_object('selections',normalized));
 return to_jsonb(r);
end $$;

create or replace function private.yt_store_box_request_v2(p_box uuid,p_quantity integer,p_component text,p_request uuid,p_table_label text default null) returns jsonb language sql security definer set search_path='' as $$
 select private.yt_store_box_request_v3(p_box,p_quantity,
  case when nullif(btrim(coalesce(p_component,'')),'') is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('key',p_component,'quantity',p_quantity)) end,
  p_request,p_table_label)
$$;

create or replace function private.yt_store_box_request(p_box uuid,p_quantity integer,p_request uuid,p_table_label text default null) returns jsonb language sql security definer set search_path='' as $$
 select private.yt_store_box_request_v3(p_box,p_quantity,'[]'::jsonb,p_request,p_table_label)
$$;

create or replace function private.yt_store_box_request_action(p_request uuid,p_action text,p_completed_delta integer default 0,p_reason text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();r public.yt_store_box_requests%rowtype;b public.yt_store_boxes%rowtype;next_status text;
 request_selections jsonb;new_components jsonb;
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
  request_selections:=case when jsonb_array_length(r.selections)>0 then r.selections else jsonb_build_array(jsonb_build_object('key',r.component_key,'name',r.component_name,'quantity',r.quantity)) end;
  if exists(
   select 1 from jsonb_array_elements(request_selections) s
   where not exists(
    select 1 from jsonb_array_elements(b.components) c where c->>'key'=s->>'key'
     and (s->>'quantity')::integer<=(c->>'total_units')::integer-(c->>'served_units')::integer
   )
  ) then raise exception 'store_box_component_unavailable';end if;
  select jsonb_agg(
   jsonb_set(c,'{served_units}',to_jsonb((c->>'served_units')::integer+coalesce((select sum((s->>'quantity')::integer) from jsonb_array_elements(request_selections) s where s->>'key'=c->>'key'),0)))
   order by n) into new_components from jsonb_array_elements(b.components) with ordinality e(c,n);
  update public.yt_store_box_requests set status='served',served_by=actor,served_at=clock_timestamp(),completed_delta=0 where id=r.id returning * into r;
  update public.yt_store_boxes set served_units=served_units+r.quantity,components=new_components,
   status=case when served_units+r.quantity=total_units then 'exhausted' else 'active' end,updated_at=clock_timestamp()
  where id=b.id returning * into b;
  next_status:='drink_served';
 else
  if r.status not in ('pending','accepted','preparing') then raise exception 'store_box_request_not_active';end if;
  if r.status in ('accepted','preparing') and length(btrim(coalesce(p_reason,'')))<2 then raise exception 'cancel_reason_required';end if;
  update public.yt_store_box_requests set status='cancelled',cancelled_by=actor,cancelled_at=clock_timestamp(),cancel_reason=nullif(btrim(p_reason),'') where id=r.id returning * into r;
  next_status:='drink_request_cancelled';
 end if;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,completed_delta,actor_id,note,metadata)
 values(b.id,r.id,next_status,r.quantity,0,actor,nullif(btrim(p_reason),''),jsonb_build_object('selections',r.selections));
 return jsonb_build_object('request',to_jsonb(r),'box',to_jsonb(b));
end $$;

create or replace function private.yt_store_box_claim_preview(p_token uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.yt_store_box_claims%rowtype;b public.yt_store_boxes%rowtype;h text;
begin
 if not private.yt_store_box_customer() then raise exception 'customer_only';end if;
 if p_token is null then raise exception 'store_box_claim_invalid';end if;
 h:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 select * into c from public.yt_store_box_claims where token_hash=h;
 if not found or c.status<>'issued' or c.expires_at<=clock_timestamp() then raise exception 'store_box_claim_invalid';end if;
 select * into b from public.yt_store_boxes where id=c.box_id;
 if b.customer_id is not null and b.customer_id<>auth.uid() then raise exception 'store_box_claim_invalid';end if;
 return jsonb_build_object('claim_id',c.id,'name',b.name,'mode',b.mode,'total_units',b.total_units,'unit_label',b.unit_label,
  'selection_mode',b.selection_mode,'components',b.components,'expires_at',c.expires_at);
end $$;

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
   r.component_name active_request_component_name,r.selections active_request_selections,r.status active_request_status,r.requested_at
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
  select r.id request_id,r.status,r.quantity,r.component_key,r.component_name,r.selections,r.table_label,r.requested_at,r.expires_at,r.accepted_by,wa.username accepted_by_name,
   b.id box_id,b.name,b.mode,b.unit_label,b.total_units,b.served_units,b.components,b.selection_mode,b.total_units-b.served_units remaining_units,
   b.customer_id,p.phone customer_phone,coalesce(pr.display_name,p.phone) customer_name,o.order_no
  from public.yt_store_box_requests r join public.yt_store_boxes b on b.id=r.box_id
  join public.yt_member_orders o on o.id=b.source_order_id
  left join public.pin_accounts p on p.auth_user_id=b.customer_id left join public.profiles pr on pr.id=b.customer_id
  left join public.work_accounts wa on wa.auth_user_id=r.accepted_by where r.status in ('pending','accepted','preparing')
 )x;
 return rows;
end $$;

create or replace function public.yt_store_box_request_v3(
 p_box uuid,p_quantity integer,p_selections jsonb,p_request uuid,p_table_label text
) returns jsonb language sql security invoker set search_path='' as
$$select private.yt_store_box_request_v3(p_box,p_quantity,p_selections,p_request,p_table_label)$$;

revoke all on function private.yt_store_box_request_v3(uuid,integer,jsonb,uuid,text) from public,anon;
revoke all on function public.yt_store_box_request_v3(uuid,integer,jsonb,uuid,text) from public,anon;
grant execute on function private.yt_store_box_request_v3(uuid,integer,jsonb,uuid,text) to authenticated;
grant execute on function public.yt_store_box_request_v3(uuid,integer,jsonb,uuid,text) to authenticated;
