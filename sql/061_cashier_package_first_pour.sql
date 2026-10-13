-- Cashier-first Package / Challenge service; no customer QR required for cashier-managed prep.
-- Package initial quantity is chosen by cashier; Challenge is exactly one initial cup.
-- Remaining units stay auditable in a staff-managed box and may be called later.
alter table public.yt_store_boxes add column if not exists cashier_managed boolean not null default false;

create or replace function private.yt_store_box_checkout_prep_quote(p_order uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare o public.yt_member_orders%rowtype;rows jsonb;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 select * into o from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.name,x.item_id),'[]'::jsonb) into rows from (
 select i.id item_id,i.item_name name,i.quantity,r.mode,r.total_units*i.quantity capacity,
    r.selection_mode,r.request_limit,r.components,r.unit_label,
    case when jsonb_array_length(r.components)>0 then (
     select coalesce(jsonb_agg(jsonb_build_object('key',e->>'key','name',e->>'name','quantity',(e->>'quantity')::int*i.quantity) order by n),'[]'::jsonb)
       from jsonb_array_elements(r.components) with ordinality j(e,n))
     else jsonb_build_array(jsonb_build_object('key','default','name',i.item_name,'quantity',r.total_units*i.quantity))
    end available
 from public.yt_member_order_items i join public.yt_store_box_product_rules r on r.product_id=i.product_id
 where i.order_id=p_order and i.quantity>0 and r.active
 )x;
 return jsonb_build_object('order_id',p_order,'can_prepare',o.payment_status='unpaid' and o.status in('confirmed','fulfilled'),
 'items',rows);
end $$;

create or replace function private.yt_store_box_cashier_request(p_box uuid,p_selections jsonb,p_request uuid,p_initial boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();b public.yt_store_boxes%rowtype;sel jsonb:='[]'::jsonb;
 entry jsonb;candidate jsonb;total_qty int:=0;v_qty int;v_key text;v_name text;
 r public.yt_store_box_requests%rowtype;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if p_box is null or p_request is null or p_selections is null or jsonb_typeof(p_selections)<>'array'
  or jsonb_array_length(p_selections)<1 or jsonb_array_length(p_selections)>20 then raise exception 'invalid_store_box_selection';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into r from public.yt_store_box_requests where client_request_id=p_request for update;
 if found then
  if r.box_id<>p_box or r.selections<>p_selections then raise exception 'request_conflict';end if;
  return jsonb_build_object('request_id',r.id,'quantity',r.quantity,'idempotent',true);
 end if;
 select * into b from public.yt_store_boxes where id=p_box for update;
 if not found or not b.cashier_managed or b.customer_id is not null
 or b.status not in('unclaimed','active') or b.storage_expires_at<=clock_timestamp()
 then raise exception 'store_box_not_available';end if;
 if exists(select 1 from public.yt_store_box_requests
    where box_id=p_box and status in('pending','accepted','preparing')) then raise exception 'store_box_request_already_active';end if;
 for entry in select value from jsonb_array_elements(p_selections) loop
  v_key:=nullif(btrim(entry->>'key'),'');
  if v_key is null or coalesce(entry->>'quantity','')!~'^[0-9]{1,2}$' then raise exception 'invalid_store_box_selection';end if;
  v_qty:=(entry->>'quantity')::integer;
  if v_qty<1 then raise exception 'invalid_store_box_selection';end if;
  if exists(select 1 from jsonb_array_elements(sel) x where x->>'key'=v_key) then raise exception 'duplicate_store_box_component';end if;
  select value into candidate from jsonb_array_elements(b.components) where value->>'key'=v_key;
  if candidate is null or (candidate->>'total_units')::integer-(candidate->>'served_units')::integer<v_qty then
   raise exception 'store_box_component_unavailable';end if;
  v_name:=candidate->>'name';
  sel:=sel||jsonb_build_array(jsonb_build_object('key',v_key,'name',v_name,'quantity',v_qty));
  total_qty:=total_qty+v_qty;
 end loop;
 if total_qty<1 or total_qty>99 or total_qty>b.total_units-b.served_units then raise exception 'store_box_quantity_unavailable';end if;
 if b.mode='challenge' and total_qty<>1 then raise exception 'challenge_one_cup_only';end if;
 insert into public.yt_store_box_requests(box_id,customer_id,quantity,component_key,component_name,
  selections,client_request_id,table_label,expires_at)
 values(b.id,null,total_qty,sel->0->>'key',sel->0->>'name',sel,p_request,b.table_label,clock_timestamp()+interval '8 hours')
 returning * into r;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,actor_id,metadata)
 values(b.id,r.id,'drink_requested',total_qty,actor,jsonb_build_object('source',case when p_initial then 'cashier_checkout' else 'cashier_direct' end,'selections',sel));
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(actor,'store_box.cashier_prep','store_box',b.id,jsonb_build_object('request_id',r.id,'quantity',total_qty,'initial',p_initial));
 return jsonb_build_object('request_id',r.id,'quantity',total_qty,'selections',sel,'idempotent',false);
end $$;

create or replace function private.yt_pos_checkout_with_prep(p_order uuid,p_method text,p_preps jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.yt_member_orders%rowtype;quote jsonb;line jsonb;rows jsonb;plan jsonb:='[]'::jsonb; v_item record;
 sel jsonb;v_total int;v_capacity int;prepared jsonb:='[]'::jsonb;result jsonb;box public.yt_store_boxes%rowtype;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if p_order is null or p_preps is null or jsonb_typeof(p_preps)<>'array' or jsonb_array_length(p_preps)>50 then raise exception 'invalid_store_box_selection';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into o from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found or o.payment_status<>'unpaid' then raise exception 'order_not_ready_for_checkout';end if;
 quote:=private.yt_store_box_checkout_prep_quote(p_order);
 if not (quote->>'can_prepare')::boolean then raise exception 'order_not_served';end if;
 rows:=quote->'items';
 if exists(select 1 from jsonb_array_elements(p_preps) z
   where not exists(select 1 from jsonb_array_elements(rows) x where x->>'item_id'=z->>'item_id'))
 then raise exception 'store_box_item_not_in_order';end if;
 if exists(select 1 from jsonb_array_elements(p_preps) z
    group by z->>'item_id' having count(*)>1) then raise exception 'duplicate_store_box_item';end if;
 for v_item in select value item from jsonb_array_elements(rows) loop
  select value into line from jsonb_array_elements(p_preps) where value->>'item_id'=v_item.item->>'item_id';
  if line is null then
   -- Challenge must always get exactly one first cup, even if a stale frontend omits this item.
   sel:=case when v_item.item->>'mode'='challenge'
     then jsonb_build_array(jsonb_build_object('key',v_item.item->'available'->0->>'key','quantity',1))
     else '[]'::jsonb end;
  else
   sel:=coalesce(line->'selections','[]'::jsonb);
  end if;
  if jsonb_typeof(sel)<>'array' or jsonb_array_length(sel)>20 then raise exception 'invalid_store_box_selection';end if;
  select coalesce(sum((x->>'quantity')::integer),0) into v_total from jsonb_array_elements(sel) x;
  if v_item.item->>'mode'='challenge' and v_total<>1 then raise exception 'challenge_one_cup_only';end if;
  if v_total<0 or v_total>99 or v_total>(v_item.item->>'capacity')::int then raise exception 'store_box_quantity_unavailable';end if;
  plan:=plan||jsonb_build_array(jsonb_build_object('item_id',v_item.item->>'item_id','quantity',v_total,'selections',sel));
 end loop;
 -- Original payment and existing reward/Moon redemption triggers remain authoritative.
 result:=private.yt_pos_action(p_order,'paid',null,p_method);
 for v_item in select value item from jsonb_array_elements(plan) loop
  select * into box from public.yt_store_boxes where source_order_item_id=(v_item.item->>'item_id')::uuid for update;
  if not found then raise exception 'store_box_not_created';end if;
  if box.customer_id is not null or box.served_units>0 then raise exception 'store_box_already_claimed';end if;
  update public.yt_store_boxes set cashier_managed=true,
    storage_expires_at=coalesce(storage_expires_at,clock_timestamp()+make_interval(days=>expiry_days)),
    updated_at=clock_timestamp()
  where id=box.id;
  -- Cashier controls initial cups and remaining balance; no forced guest QR.
  update public.yt_store_box_claims set status='cancelled',claim_token=null,cancelled_by=auth.uid(),
   cancelled_at=clock_timestamp(),cancel_reason='Cashier-managed prep; customer QR not required'
  where box_id=box.id and status='issued';
  if (v_item.item->>'quantity')::int>0 then
   prepared:=prepared||jsonb_build_array(private.yt_store_box_cashier_request(
    box.id,v_item.item->'selections',gen_random_uuid(),true));
  end if;
 end loop;
 return result||jsonb_build_object('store_box_claims','[]'::jsonb,'cashier_prepared',prepared,
  'cashier_managed_packages',jsonb_array_length(plan));
end $$;

-- Allow POS-prepared, unclaimed boxes to serve KDS requests before customer registration.
create or replace function private.yt_store_box_request_action(p_request uuid,p_action text,p_completed_delta integer default 0,p_reason text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
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
  if not (b.status='active' or (b.status='unclaimed' and b.cashier_managed and r.customer_id is null))
   or b.storage_expires_at is null or b.storage_expires_at<=clock_timestamp() then raise exception 'store_box_not_available';end if;
  request_selections:=case when jsonb_array_length(r.selections)>0 then r.selections else jsonb_build_array(jsonb_build_object('key',r.component_key,'name',r.component_name,'quantity',r.quantity)) end;
  if exists(select 1 from jsonb_array_elements(request_selections) s
   where not exists(select 1 from jsonb_array_elements(b.components) c where c->>'key'=s->>'key'
    and (s->>'quantity')::integer<=(c->>'total_units')::integer-(c->>'served_units')::integer))
  then raise exception 'store_box_component_unavailable';end if;
  select jsonb_agg(
   jsonb_set(c,'{served_units}',to_jsonb((c->>'served_units')::integer+coalesce((select sum((s->>'quantity')::integer) from jsonb_array_elements(request_selections) s where s->>'key'=c->>'key'),0)))
   order by n) into new_components from jsonb_array_elements(b.components) with ordinality e(c,n);
  update public.yt_store_box_requests set status='served',served_by=actor,served_at=clock_timestamp(),completed_delta=0 where id=r.id returning * into r;
  update public.yt_store_boxes set served_units=served_units+r.quantity,components=new_components,
   status=case when served_units+r.quantity=total_units then 'exhausted'
      when status='unclaimed' then 'unclaimed' else 'active' end,updated_at=clock_timestamp()
  where id=b.id returning * into b;
  next_status:='drink_served';
 else
  if r.status not in ('pending','accepted','preparing') then raise exception 'store_box_request_not_active';end if;
  if r.status in('accepted','preparing') and length(btrim(coalesce(p_reason,'')))<2 then raise exception 'cancel_reason_required';end if;
  update public.yt_store_box_requests set status='cancelled',cancelled_by=actor,cancelled_at=clock_timestamp(),cancel_reason=nullif(btrim(p_reason),'') where id=r.id returning * into r;
  next_status:='drink_request_cancelled';
 end if;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,completed_delta,actor_id,note,metadata)
 values(b.id,r.id,next_status,r.quantity,0,actor,nullif(btrim(p_reason),''),jsonb_build_object('selections',r.selections));
 return jsonb_build_object('request',to_jsonb(r),'box',to_jsonb(b));
end $$;

create or replace function private.yt_store_box_staff_boxes() returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_boxes set status='expired',updated_at=clock_timestamp()
  where storage_expires_at<=clock_timestamp() and status in ('active','paused','exhausted','unclaimed') and (customer_id is not null or cashier_managed);
 select coalesce(jsonb_agg(to_jsonb(x) order by x.storage_expires_at desc,x.updated_at desc),'[]'::jsonb) into rows from(
  select b.id,b.name,b.mode,b.status,b.unit_label,b.total_units,b.served_units,b.components,b.selection_mode,
   b.cashier_managed,b.total_units-b.served_units remaining_units,b.request_limit,b.table_label,b.customer_id,
   coalesce(pr.display_name,p.phone,case when b.cashier_managed then 'Cashier 管理' else null end) customer_name,
   p.phone customer_phone,b.claimed_at,b.storage_expires_at,b.updated_at,
   r.id active_request_id,r.status active_request_status,r.quantity active_request_quantity,r.component_name active_request_component_name
  from public.yt_store_boxes b left join public.pin_accounts p on p.auth_user_id=b.customer_id
  left join public.profiles pr on pr.id=b.customer_id
  left join public.yt_store_box_requests r on r.box_id=b.id and r.status in('pending','accepted','preparing')
  where (b.customer_id is not null or b.cashier_managed) and b.status in('unclaimed','active','paused','exhausted','completed','expired','cancelled')
  order by b.storage_expires_at desc,b.updated_at desc limit 200
 )x;
 return rows;
end $$;
create or replace function public.yt_store_box_checkout_prep_quote(p_order uuid) returns jsonb
language sql security invoker set search_path='' as $$select private.yt_store_box_checkout_prep_quote(p_order)$$;
create or replace function public.yt_pos_checkout_with_prep(p_order uuid,p_method text,p_preps jsonb default '[]'::jsonb)
returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_checkout_with_prep(p_order,p_method,p_preps)$$;
create or replace function public.yt_store_box_cashier_request(p_box uuid,p_selections jsonb,p_request uuid,p_initial boolean default false)
returns jsonb language sql security invoker set search_path='' as $$
select private.yt_store_box_cashier_request(p_box,p_selections,p_request,p_initial)$$;
revoke all on function private.yt_store_box_checkout_prep_quote(uuid),
 private.yt_pos_checkout_with_prep(uuid,text,jsonb),private.yt_store_box_cashier_request(uuid,jsonb,uuid,boolean),
 public.yt_store_box_checkout_prep_quote(uuid),public.yt_pos_checkout_with_prep(uuid,text,jsonb),
 public.yt_store_box_cashier_request(uuid,jsonb,uuid,boolean) from public,anon,authenticated;
grant execute on function private.yt_store_box_checkout_prep_quote(uuid),
 private.yt_pos_checkout_with_prep(uuid,text,jsonb),private.yt_store_box_cashier_request(uuid,jsonb,uuid,boolean),
 public.yt_store_box_checkout_prep_quote(uuid),public.yt_pos_checkout_with_prep(uuid,text,jsonb),
 public.yt_store_box_cashier_request(uuid,jsonb,uuid,boolean) to authenticated;
