-- KDS history and Store Box privacy/role boundaries.

create or replace function private.yt_store_box_can_view_claim_identity() returns boolean
language sql stable security definer set search_path='' as $$
 select private.yt_work_owner() or (
  private.yt_pos_work_staff() and exists(
   select 1 from public.work_accounts wa
   where wa.auth_user_id=auth.uid() and wa.role='cashier'
  )
 )
$$;
revoke all on function private.yt_store_box_can_view_claim_identity() from public,anon,authenticated;

create or replace function private.yt_store_box_issue_quote(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare o public.yt_member_orders%rowtype;rows jsonb;can_view boolean:=private.yt_store_box_can_view_claim_identity();
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select * into o from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.item_name),'[]'::jsonb) into rows from(
  select i.id order_item_id,i.product_id,i.item_name,i.quantity,r.mode,
   i.quantity*r.total_units total_units,r.request_limit,r.expiry_days,r.unit_label,r.selection_mode,r.components,
   r.game_pass_enabled,b.id box_id,b.status box_status,b.served_units,
   case when can_view then coalesce(pr.display_name,p.phone) else null end customer_name,
   case when can_view then p.phone else null end customer_phone,
   c.id active_claim_id,c.claim_token,c.expires_at claim_expires_at,
   case when can_view then w.username else null end issued_by_name
  from public.yt_member_order_items i
  join public.yt_store_box_product_rules r on r.product_id=i.product_id and r.active
  left join public.yt_store_boxes b on b.source_order_item_id=i.id
  left join public.yt_store_box_claims c on c.box_id=b.id and c.status='issued' and c.expires_at>clock_timestamp()
  left join public.work_accounts w on w.auth_user_id=c.issued_by
  left join public.pin_accounts p on p.auth_user_id=b.customer_id
  left join public.profiles pr on pr.id=b.customer_id
  where i.order_id=p_order and i.quantity>0
 )x;
 return jsonb_build_object('order_id',o.id,'order_no',o.order_no,'table_label',o.table_label,
  'ready',o.status='fulfilled' and o.payment_status='paid' and o.paid_at is not null and o.settlement_due_since is null and not o.cancel_after_refund,
  'items',rows);
end $$;

create or replace function private.yt_store_box_claims_active() returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb;can_view boolean:=private.yt_store_box_can_view_claim_identity();
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_box_claims set status='expired',claim_token=null where status='issued' and expires_at<=clock_timestamp();
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into rows from(
  select c.id claim_id,c.box_id,c.claim_token,c.expires_at,c.created_at,
   case when can_view then w.username else null end issued_by_name,
   b.name,b.mode,b.total_units,b.unit_label,b.table_label,o.id order_id,o.order_no
  from public.yt_store_box_claims c join public.yt_store_boxes b on b.id=c.box_id
  join public.yt_member_orders o on o.id=b.source_order_id
  left join public.work_accounts w on w.auth_user_id=c.issued_by
  where c.status='issued' and c.expires_at>clock_timestamp()
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_staff_boxes() returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb;can_view boolean:=private.yt_store_box_can_view_claim_identity();
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_boxes set status='expired',updated_at=clock_timestamp()
  where storage_expires_at<=clock_timestamp() and status in ('active','paused','exhausted');
 select coalesce(jsonb_agg(to_jsonb(x) order by x.storage_expires_at desc,x.updated_at desc),'[]'::jsonb) into rows from(
  select b.id,b.name,b.mode,b.status,b.unit_label,b.total_units,b.served_units,b.components,b.selection_mode,
   b.total_units-b.served_units remaining_units,b.request_limit,b.table_label,
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

create or replace function private.yt_store_box_queue() returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_box_requests set status='expired' where status='pending' and expires_at<=clock_timestamp();
 select coalesce(jsonb_agg(to_jsonb(x) order by x.requested_at),'[]'::jsonb) into rows from(
  select r.id request_id,r.status,r.quantity,r.component_key,r.component_name,r.selections,
   case when r.customer_id is not null then 'customer' else coalesce((select e.metadata->>'source' from public.yt_store_box_events e where e.request_id=r.id and e.event_type='drink_requested' order by e.created_at desc limit 1),'staff') end request_source,
   r.table_label,r.requested_at,r.expires_at,b.id box_id,b.name,b.mode,b.unit_label,b.total_units,b.served_units,
   b.components,b.selection_mode,b.total_units-b.served_units remaining_units,o.order_no
  from public.yt_store_box_requests r join public.yt_store_boxes b on b.id=r.box_id
  join public.yt_member_orders o on o.id=b.source_order_id
  where r.status in ('pending','accepted','preparing')
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_progress(p_box uuid,p_action text,p_completed_delta integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b public.yt_store_boxes%rowtype;event_name text;
begin
 if not (private.yt_work_owner() or (private.yt_pos_work_staff() and exists(select 1 from public.work_accounts wa where wa.auth_user_id=auth.uid() and wa.role='cashier'))) then
  raise exception 'cashier_or_owner_only';
 end if;
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

create or replace function private.yt_kds_history(p_day date default null,p_limit integer default 100) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare d date:=coalesce(p_day,private.yt_business_day(clock_timestamp()));start_at timestamptz;end_at timestamptz;orders jsonb;requests jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_limit is null or p_limit not between 1 and 150 then raise exception 'invalid_filter';end if;
 start_at:=private.yt_business_start(d);end_at:=private.yt_business_start(d+1);
 select coalesce(jsonb_agg(to_jsonb(x) order by x.event_at desc),'[]'::jsonb) into orders from(
  select o.id,o.order_no,o.table_label,o.notes,o.status,o.payment_status,o.created_at,o.updated_at,o.fulfilled_at,
   coalesce(o.fulfilled_at,o.updated_at,o.created_at) event_at,wa.username created_by_name,
   coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'name',i.item_name,'quantity',i.quantity) order by i.item_name)
    from public.yt_member_order_items i where i.order_id=o.id and i.quantity>0),'[]'::jsonb) items
  from public.yt_member_orders o left join public.work_accounts wa on wa.auth_user_id=o.created_by
  where o.source='future_pos' and (
   (o.status='fulfilled' and coalesce(o.fulfilled_at,o.updated_at)>=start_at and coalesce(o.fulfilled_at,o.updated_at)<end_at)
   or (o.status='cancelled' and o.updated_at>=start_at and o.updated_at<end_at)
  ) order by coalesce(o.fulfilled_at,o.updated_at,o.created_at) desc limit p_limit
 )x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.event_at desc),'[]'::jsonb) into requests from(
  select r.status,r.quantity,r.component_name,r.selections,r.table_label,r.requested_at,r.served_at,r.cancelled_at,r.expires_at,r.cancel_reason,
   coalesce(r.served_at,r.cancelled_at,case when r.status='expired' then r.expires_at end,r.requested_at) event_at,
   b.name,b.unit_label,o.order_no
  from public.yt_store_box_requests r join public.yt_store_boxes b on b.id=r.box_id
  join public.yt_member_orders o on o.id=b.source_order_id
  where r.status in ('served','cancelled','expired')
   and coalesce(r.served_at,r.cancelled_at,case when r.status='expired' then r.expires_at end,r.requested_at)>=start_at
   and coalesce(r.served_at,r.cancelled_at,case when r.status='expired' then r.expires_at end,r.requested_at)<end_at
  order by coalesce(r.served_at,r.cancelled_at,case when r.status='expired' then r.expires_at end,r.requested_at) desc limit p_limit
 )x;
 return jsonb_build_object('business_day',d,'orders',orders,'store_box_requests',requests);
end $$;

create or replace function public.yt_kds_history(p_day date default null,p_limit integer default 100) returns jsonb
language sql security invoker set search_path='' as $$select private.yt_kds_history($1,$2)$$;

revoke all on function private.yt_kds_history(date,integer),public.yt_kds_history(date,integer) from public,anon;
grant execute on function private.yt_kds_history(date,integer),public.yt_kds_history(date,integer) to authenticated;
