-- V16.7 Store Box bar hub.
-- Drink requests are operational order tasks. A served request only reduces the
-- remaining balance; the retired "completed/drank" counter is kept in storage
-- for backwards compatibility but is no longer read or changed.

create or replace function private.yt_my_store_boxes() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;actor uuid:=auth.uid();
begin
 if not private.yt_store_box_customer() then raise exception 'customer_only';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.storage_expires_at,x.created_at desc),'[]'::jsonb) into rows from(
  select b.id,b.name,b.mode,b.unit_label,b.total_units,b.served_units,
   b.total_units-b.served_units remaining_units,b.request_limit,b.table_label,
   case when b.storage_expires_at<=clock_timestamp() and b.status not in ('completed','cancelled') then 'expired' else b.status end status,
   b.claimed_at,b.storage_expires_at,b.created_at,
   r.id active_request_id,r.quantity active_request_quantity,r.status active_request_status,r.requested_at
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
  select r.id request_id,r.status,r.quantity,r.table_label,r.requested_at,r.expires_at,r.accepted_by,wa.username accepted_by_name,
   b.id box_id,b.name,b.mode,b.unit_label,b.total_units,b.served_units,b.total_units-b.served_units remaining_units,
   b.customer_id,p.phone customer_phone,coalesce(pr.display_name,p.phone) customer_name,o.order_no
  from public.yt_store_box_requests r join public.yt_store_boxes b on b.id=r.box_id
  join public.yt_member_orders o on o.id=b.source_order_id
  left join public.pin_accounts p on p.auth_user_id=b.customer_id
  left join public.profiles pr on pr.id=b.customer_id
  left join public.work_accounts wa on wa.auth_user_id=r.accepted_by
  where r.status in ('pending','accepted','preparing')
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_staff_boxes() returns jsonb language plpgsql security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_boxes set status='expired',updated_at=clock_timestamp()
  where storage_expires_at<=clock_timestamp() and status in ('active','paused','exhausted');
 select coalesce(jsonb_agg(to_jsonb(x) order by x.storage_expires_at,x.updated_at desc),'[]'::jsonb) into rows from(
  select b.id,b.name,b.mode,b.status,b.unit_label,b.total_units,b.served_units,
   b.total_units-b.served_units remaining_units,b.request_limit,b.table_label,b.customer_id,
   coalesce(pr.display_name,p.phone) customer_name,p.phone customer_phone,b.claimed_at,b.storage_expires_at,b.updated_at,
   r.id active_request_id,r.status active_request_status,r.quantity active_request_quantity
  from public.yt_store_boxes b left join public.pin_accounts p on p.auth_user_id=b.customer_id
  left join public.profiles pr on pr.id=b.customer_id
  left join public.yt_store_box_requests r on r.box_id=b.id and r.status in ('pending','accepted','preparing')
  where b.customer_id is not null and b.status in ('active','paused','exhausted')
  order by b.storage_expires_at,b.updated_at desc limit 200
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_request_action(p_request uuid,p_action text,p_completed_delta integer default 0,p_reason text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();r public.yt_store_box_requests%rowtype;b public.yt_store_boxes%rowtype;next_status text;
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
  if b.status not in ('active','exhausted') or b.storage_expires_at<=clock_timestamp() then raise exception 'store_box_not_available';end if;
  if r.quantity>b.total_units-b.served_units then raise exception 'store_box_quantity_unavailable';end if;
  update public.yt_store_box_requests set status='served',served_by=actor,served_at=clock_timestamp(),completed_delta=0 where id=r.id returning * into r;
  update public.yt_store_boxes set served_units=served_units+r.quantity,
   status=case when served_units+r.quantity=total_units then 'exhausted' else 'active' end,
   updated_at=clock_timestamp() where id=b.id returning * into b;
  next_status:='drink_served';
 else
  if r.status not in ('pending','accepted','preparing') then raise exception 'store_box_request_not_active';end if;
  if r.status in ('accepted','preparing') and length(btrim(coalesce(p_reason,'')))<2 then raise exception 'cancel_reason_required';end if;
  update public.yt_store_box_requests set status='cancelled',cancelled_by=actor,cancelled_at=clock_timestamp(),cancel_reason=nullif(btrim(p_reason),'') where id=r.id returning * into r;
  next_status:='drink_request_cancelled';
 end if;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,completed_delta,actor_id,note)
 values(b.id,r.id,next_status,r.quantity,0,actor,nullif(btrim(p_reason),''));
 return jsonb_build_object('request',to_jsonb(r),'box',to_jsonb(b));
end $$;

create or replace function private.yt_store_box_progress(p_box uuid,p_action text,p_completed_delta integer default 0) returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.yt_store_boxes%rowtype;event_name text;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_box is null then raise exception 'invalid_store_box_progress';end if;
 if p_action='complete' then raise exception 'store_box_progress_retired';end if;
 if p_action not in ('pause','resume') then raise exception 'invalid_store_box_progress';end if;
 select * into b from public.yt_store_boxes where id=p_box for update;
 if not found then raise exception 'store_box_not_found';end if;
 if p_action='pause' then
  if b.status not in ('active','exhausted') then raise exception 'store_box_not_active';end if;
  update public.yt_store_boxes set status='paused',updated_at=clock_timestamp() where id=b.id returning * into b;event_name:='box_paused';
 else
  if b.status<>'paused' then raise exception 'store_box_not_paused';end if;
  update public.yt_store_boxes set status=case when served_units=total_units then 'exhausted' else 'active' end,updated_at=clock_timestamp() where id=b.id returning * into b;event_name:='box_resumed';
 end if;
 insert into public.yt_store_box_events(box_id,event_type,completed_delta,actor_id) values(b.id,event_name,0,auth.uid());
 return to_jsonb(b);
end $$;
