-- Store Box numbering, Cashier serving for customer-owned balances, Owner reopening approvals and customer history.
create sequence if not exists public.yt_store_box_number_seq;
alter table public.yt_store_boxes add column if not exists box_number text;
update public.yt_store_boxes
 set box_number='SB-'||lpad(nextval('public.yt_store_box_number_seq')::text,8,'0')
 where box_number is null;
alter table public.yt_store_boxes alter column box_number
 set default ('SB-'||lpad(nextval('public.yt_store_box_number_seq')::text,8,'0'));
alter table public.yt_store_boxes alter column box_number set not null;
create unique index if not exists yt_store_boxes_box_number_uidx on public.yt_store_boxes(box_number);

create table if not exists public.yt_store_box_reopen_requests(
 id uuid primary key default gen_random_uuid(),
 box_id uuid not null references public.yt_store_boxes(id) on delete cascade,
 customer_id uuid not null references auth.users(id) on delete cascade,
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 requested_at timestamptz not null default clock_timestamp(),
 reviewed_at timestamptz,
 reviewed_by uuid references auth.users(id) on delete set null,
 review_note text,
 expires_at timestamptz,
 constraint yt_store_box_reopen_review_consistency check (
  (status='pending' and reviewed_at is null and reviewed_by is null and expires_at is null)
  or (status in ('approved','rejected') and reviewed_at is not null and reviewed_by is not null)
 )
);
create index if not exists yt_store_box_reopen_owner_queue_idx
 on public.yt_store_box_reopen_requests(requested_at) where status='pending';
create unique index if not exists yt_store_box_reopen_one_pending_uidx
 on public.yt_store_box_reopen_requests(box_id) where status='pending';
alter table public.yt_store_box_reopen_requests enable row level security;
revoke all on public.yt_store_box_reopen_requests from public,anon,authenticated;

create or replace function private.yt_store_box_reopen_request(p_box uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();b public.yt_store_boxes%rowtype;r public.yt_store_box_reopen_requests%rowtype;
begin
 if not private.yt_store_box_customer() or actor is null then raise exception 'customer_only';end if;
 if p_box is null then raise exception 'invalid_store_box_reopen_request';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into b from public.yt_store_boxes where id=p_box and customer_id=actor for update;
 if not found then raise exception 'store_box_not_found';end if;
 if b.claimed_at is null or b.storage_expires_at is null or b.storage_expires_at>clock_timestamp()
   or b.total_units<=b.served_units or b.status in ('completed','cancelled') then
  raise exception 'store_box_not_reopenable';
 end if;
 select * into r from public.yt_store_box_reopen_requests
  where box_id=b.id and status='pending' for update;
 if found then return jsonb_build_object('id',r.id,'status',r.status,'requested_at',r.requested_at,'already_pending',true);end if;
 insert into public.yt_store_box_reopen_requests(box_id,customer_id)
 values(b.id,actor) returning * into r;
 return jsonb_build_object('id',r.id,'status',r.status,'requested_at',r.requested_at,'already_pending',false);
end $$;

create or replace function private.yt_store_box_reopen_list() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.requested_at),'[]'::jsonb) into rows
 from(
  select r.id request_id,r.requested_at,r.status,r.review_note,
   b.id box_id,b.box_number,b.name,b.unit_label,b.total_units,b.served_units,
   b.total_units-b.served_units remaining_units,b.storage_expires_at,b.expiry_days,b.table_label,
   coalesce(nullif(pr.display_name,''),p.phone,'顾客') customer_name
  from public.yt_store_box_reopen_requests r
  join public.yt_store_boxes b on b.id=r.box_id
  left join public.profiles pr on pr.id=r.customer_id
  left join public.pin_accounts p on p.auth_user_id=r.customer_id
  where r.status='pending'
  order by r.requested_at
  limit 100
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_reopen_review(p_request uuid,p_action text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();r public.yt_store_box_reopen_requests%rowtype;b public.yt_store_boxes%rowtype;new_expiry timestamptz;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_request is null or p_action not in ('approve','reject') then raise exception 'invalid_store_box_reopen_action';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into r from public.yt_store_box_reopen_requests where id=p_request for update;
 if not found then raise exception 'store_box_reopen_request_not_found';end if;
 if r.status<>'pending' then raise exception 'store_box_reopen_request_not_pending';end if;
 select * into b from public.yt_store_boxes where id=r.box_id for update;
 if not found then raise exception 'store_box_not_found';end if;
 if p_action='approve' then
  if b.total_units<=b.served_units or b.storage_expires_at is null or b.storage_expires_at>clock_timestamp()
   or b.status in ('completed','cancelled') then raise exception 'store_box_not_reopenable';end if;
  new_expiry:=private.yt_business_start(private.yt_business_day(clock_timestamp())+greatest(1,b.expiry_days));
  update public.yt_store_boxes set storage_expires_at=new_expiry,status='active',updated_at=clock_timestamp()
   where id=b.id returning * into b;
  update public.yt_store_box_reopen_requests set status='approved',reviewed_at=clock_timestamp(),reviewed_by=actor,expires_at=new_expiry where id=r.id returning * into r;
 else
  update public.yt_store_box_reopen_requests set status='rejected',reviewed_at=clock_timestamp(),reviewed_by=actor where id=r.id returning * into r;
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(actor,'store_box.reopen.'||p_action,'store_box',b.id,jsonb_build_object('request_id',r.id,'box_number',b.box_number,'expires_at',r.expires_at));
 return jsonb_build_object('request',to_jsonb(r),'box',jsonb_build_object('id',b.id,'box_number',b.box_number,'status',b.status,'storage_expires_at',b.storage_expires_at));
end $$;

create or replace function private.yt_store_box_staff_boxes() returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb;can_view boolean:=private.yt_store_box_can_view_claim_identity();
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_boxes set status='expired',updated_at=clock_timestamp()
  where storage_expires_at<=clock_timestamp() and status in ('active','paused','exhausted');
 select coalesce(jsonb_agg(to_jsonb(x) order by x.storage_expires_at desc,x.updated_at desc),'[]'::jsonb) into rows from(
  select b.id,b.box_number,b.name,b.mode,b.status,b.unit_label,b.total_units,b.served_units,b.components,b.selection_mode,
   b.total_units-b.served_units remaining_units,b.request_limit,b.table_label,b.cashier_managed,
   (b.customer_id is not null or (b.cashier_managed and b.status in ('unclaimed','active'))) cashier_serve_allowed,
   case when can_view then coalesce(pr.display_name,p.phone) else null end customer_name,
   case when can_view then p.phone else null end customer_phone,
   b.claimed_at,b.storage_expires_at,b.updated_at,
   r.id active_request_id,r.status active_request_status,r.quantity active_request_quantity,r.component_name active_request_component_name,
   case when can_view then wa.username else null end claimed_qr_issued_by_name
  from public.yt_store_boxes b left join public.pin_accounts p on p.auth_user_id=b.customer_id
  left join public.profiles pr on pr.id=b.customer_id
  left join public.yt_store_box_requests r on r.box_id=b.id and r.status in ('pending','accepted','preparing')
  left join lateral(select c.issued_by from public.yt_store_box_claims c where c.box_id=b.id and c.status='claimed' order by c.claimed_at desc,c.created_at desc limit 1) cq on true
  left join public.work_accounts wa on wa.auth_user_id=cq.issued_by
  where b.customer_id is not null and b.status in ('active','paused','exhausted','completed','expired','cancelled')
  order by b.storage_expires_at desc,b.updated_at desc limit 200
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_staff_search(p_number text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb;v_query text;can_view boolean:=private.yt_store_box_can_view_claim_identity();
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 v_query:=upper(regexp_replace(btrim(coalesce(p_number,'')),'[^A-Z0-9]','','g'));
 if length(v_query)<2 or length(v_query)>24 then raise exception 'invalid_store_box_number_search';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.storage_expires_at desc,x.updated_at desc),'[]'::jsonb) into rows
 from(
  select b.id,b.box_number,b.name,b.mode,b.status,b.unit_label,b.total_units,b.served_units,b.components,b.selection_mode,
   b.total_units-b.served_units remaining_units,b.request_limit,b.table_label,b.cashier_managed,
   (b.customer_id is not null or (b.cashier_managed and b.status in ('unclaimed','active'))) cashier_serve_allowed,
   case when can_view then coalesce(pr.display_name,p.phone) else null end customer_name,
   case when can_view then p.phone else null end customer_phone,b.claimed_at,b.storage_expires_at,b.updated_at,
   r.id active_request_id,r.status active_request_status,r.quantity active_request_quantity,r.component_name active_request_component_name,
   case when can_view then wa.username else null end claimed_qr_issued_by_name
  from public.yt_store_boxes b left join public.pin_accounts p on p.auth_user_id=b.customer_id
  left join public.profiles pr on pr.id=b.customer_id
  left join public.yt_store_box_requests r on r.box_id=b.id and r.status in ('pending','accepted','preparing')
  left join lateral(select c.issued_by from public.yt_store_box_claims c where c.box_id=b.id and c.status='claimed' order by c.claimed_at desc,c.created_at desc limit 1) cq on true
  left join public.work_accounts wa on wa.auth_user_id=cq.issued_by
  where upper(replace(b.box_number,'-','')) like '%'||v_query||'%'
  order by b.updated_at desc limit 50
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_cashier_request(p_box uuid,p_selections jsonb,p_request uuid,p_initial boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
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
  if r.box_id<>p_box or not (r.selections @> p_selections and jsonb_array_length(r.selections)=jsonb_array_length(p_selections)) then raise exception 'request_conflict';end if;
  return jsonb_build_object('request_id',r.id,'quantity',r.quantity,'idempotent',true);
 end if;
 select * into b from public.yt_store_boxes where id=p_box for update;
 if not found or b.status not in('unclaimed','active') or b.storage_expires_at<=clock_timestamp()
  or (p_initial and (not b.cashier_managed or b.customer_id is not null))
  or (not p_initial and not (b.customer_id is not null and b.status='active' or b.cashier_managed and b.customer_id is null))
 then raise exception 'store_box_not_available';end if;
 if exists(select 1 from public.yt_store_box_requests where box_id=p_box and status in('pending','accepted','preparing')) then raise exception 'store_box_request_already_active';end if;
 for entry in select value from jsonb_array_elements(p_selections) loop
  v_key:=nullif(btrim(entry->>'key'),'');
  if v_key is null or coalesce(entry->>'quantity','')!~'^[0-9]{1,2}$' then raise exception 'invalid_store_box_selection';end if;
  v_qty:=(entry->>'quantity')::integer;
  if v_qty<1 then raise exception 'invalid_store_box_selection';end if;
  if exists(select 1 from jsonb_array_elements(sel) x where x->>'key'=v_key) then raise exception 'duplicate_store_box_component';end if;
  select value into candidate from jsonb_array_elements(b.components) where value->>'key'=v_key;
  if candidate is null or (candidate->>'total_units')::integer-(candidate->>'served_units')::integer<v_qty then raise exception 'store_box_component_unavailable';end if;
  v_name:=candidate->>'name';sel:=sel||jsonb_build_array(jsonb_build_object('key',v_key,'name',v_name,'quantity',v_qty));total_qty:=total_qty+v_qty;
 end loop;
 if total_qty<1 or total_qty>99 or total_qty>b.total_units-b.served_units then raise exception 'store_box_quantity_unavailable';end if;
 if b.mode='challenge' and total_qty<>1 then raise exception 'challenge_one_cup_only';end if;
 insert into public.yt_store_box_requests(box_id,customer_id,quantity,component_key,component_name,selections,client_request_id,table_label,expires_at)
 values(b.id,b.customer_id,total_qty,sel->0->>'key',sel->0->>'name',sel,p_request,b.table_label,clock_timestamp()+interval '8 hours')
 returning * into r;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,actor_id,customer_id,metadata)
 values(b.id,r.id,'drink_requested',total_qty,actor,b.customer_id,jsonb_build_object('source',case when p_initial then 'cashier_checkout' else 'cashier_direct' end,'selections',sel));
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(actor,'store_box.cashier_prep','store_box',b.id,jsonb_build_object('request_id',r.id,'quantity',total_qty,'initial',p_initial,'box_number',b.box_number));
 return jsonb_build_object('request_id',r.id,'quantity',total_qty,'selections',sel,'idempotent',false);
end $$;

create or replace function private.yt_my_store_boxes() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;actor uuid:=auth.uid();
begin
 if not private.yt_store_box_customer() then raise exception 'customer_only';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.storage_expires_at,x.created_at desc),'[]'::jsonb) into rows from(
  select b.id,b.box_number,b.name,b.mode,b.unit_label,b.total_units,b.served_units,b.components,b.selection_mode,
   b.total_units-b.served_units remaining_units,b.request_limit,b.table_label,
   case when b.storage_expires_at<=clock_timestamp() and b.status not in ('completed','cancelled') then 'expired' else b.status end status,
   b.claimed_at,b.storage_expires_at,b.created_at,
   r.id active_request_id,r.quantity active_request_quantity,r.component_key active_request_component_key,
   r.component_name active_request_component_name,r.selections active_request_selections,r.status active_request_status,r.requested_at,
   rr.status reopen_request_status,rr.requested_at reopen_requested_at,
   coalesce((select jsonb_agg(jsonb_build_object(
     'served_at',sr.served_at,'quantity',sr.quantity,'unit_label',b.unit_label,
     'served_by_name',coalesce(nullif(wa.username,''),'员工'),
     'table_label',sr.table_label,'selections',sr.selections
    ) order by sr.served_at desc)
    from public.yt_store_box_requests sr left join public.work_accounts wa on wa.auth_user_id=sr.served_by
    where sr.box_id=b.id and sr.status='served'),'[]'::jsonb) served_history
  from public.yt_store_boxes b
  left join public.yt_store_box_requests r on r.box_id=b.id and r.status in ('pending','accepted','preparing')
  left join lateral(select q.status,q.requested_at from public.yt_store_box_reopen_requests q where q.box_id=b.id order by q.requested_at desc limit 1) rr on true
  where b.customer_id=actor
 )x;
 return rows;
end $$;

create or replace function public.yt_store_box_reopen_request(p_box uuid) returns jsonb
language sql security invoker set search_path='' as $$select private.yt_store_box_reopen_request(p_box)$$;
create or replace function public.yt_store_box_reopen_list() returns jsonb
language sql security invoker set search_path='' as $$select private.yt_store_box_reopen_list()$$;
create or replace function public.yt_store_box_reopen_review(p_request uuid,p_action text) returns jsonb
language sql security invoker set search_path='' as $$select private.yt_store_box_reopen_review(p_request,p_action)$$;
create or replace function public.yt_store_box_staff_search(p_number text) returns jsonb
language sql security invoker set search_path='' as $$select private.yt_store_box_staff_search(p_number)$$;

revoke all on function private.yt_store_box_reopen_request(uuid),private.yt_store_box_reopen_list(),private.yt_store_box_reopen_review(uuid,text),private.yt_store_box_staff_search(text) from public,anon;
revoke all on function public.yt_store_box_reopen_request(uuid),public.yt_store_box_reopen_list(),public.yt_store_box_reopen_review(uuid,text),public.yt_store_box_staff_search(text) from public,anon;
grant execute on function private.yt_store_box_reopen_request(uuid),private.yt_store_box_reopen_list(),private.yt_store_box_reopen_review(uuid,text),private.yt_store_box_staff_search(text) to authenticated;
grant execute on function public.yt_store_box_reopen_request(uuid),public.yt_store_box_reopen_list(),public.yt_store_box_reopen_review(uuid,text),public.yt_store_box_staff_search(text) to authenticated;
