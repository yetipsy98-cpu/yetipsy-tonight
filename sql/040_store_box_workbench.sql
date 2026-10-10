-- Store Box workbench support: staff-visible active QR and compact operational lists.
alter table public.yt_store_box_claims add column claim_token uuid;

create or replace function private.yt_store_box_issue_orders() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;d date:=private.yt_business_day(clock_timestamp());
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into rows from(
  select o.id,o.order_no,o.table_label,o.amount_rm,o.created_at,count(*) eligible_items
  from public.yt_member_orders o join public.yt_member_order_items i on i.order_id=o.id
  join public.yt_store_box_product_rules r on r.product_id=i.product_id and r.active
  where o.source='future_pos' and o.status='fulfilled' and o.payment_status='paid' and o.paid_at is not null
   and o.settlement_due_since is null and not o.cancel_after_refund
   and o.created_at>=private.yt_business_start(d) and o.created_at<private.yt_business_start(d+1)
  group by o.id,o.order_no,o.table_label,o.amount_rm,o.created_at
 )x;
 return jsonb_build_object('business_day',d,'orders',rows);
end $$;

create or replace function private.yt_store_box_issue_quote(p_order uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare o public.yt_member_orders%rowtype;rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select * into o from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.item_name),'[]'::jsonb) into rows from(
  select i.id order_item_id,i.product_id,i.item_name,i.quantity,r.mode,
   i.quantity*r.total_units total_units,r.request_limit,r.expiry_days,r.unit_label,
   r.game_pass_enabled,b.id box_id,b.status box_status,b.customer_id,b.served_units,b.completed_units,
   c.id active_claim_id,c.claim_token,c.expires_at claim_expires_at,c.issued_by,w.username issued_by_name
  from public.yt_member_order_items i join public.yt_store_box_product_rules r on r.product_id=i.product_id and r.active
  left join public.yt_store_boxes b on b.source_order_item_id=i.id
  left join public.yt_store_box_claims c on c.box_id=b.id and c.status='issued' and c.expires_at>clock_timestamp()
  left join public.work_accounts w on w.auth_user_id=c.issued_by
  where i.order_id=p_order and i.quantity>0
 )x;
 return jsonb_build_object('order_id',o.id,'order_no',o.order_no,'table_label',o.table_label,
  'ready',o.status='fulfilled' and o.payment_status='paid' and o.paid_at is not null and o.settlement_due_since is null and not o.cancel_after_refund,
  'items',rows);
end $$;

create or replace function private.yt_store_box_issue(p_order_item uuid,p_token uuid,p_request uuid,p_minutes integer default 2) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();i public.yt_member_order_items%rowtype;o public.yt_member_orders%rowtype;
 r public.yt_store_box_product_rules%rowtype;b public.yt_store_boxes%rowtype;c public.yt_store_box_claims%rowtype;h text;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_order_item is null or p_token is null or p_request is null or p_minutes not between 1 and 15 then raise exception 'invalid_store_box_issue';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into i from public.yt_member_order_items where id=p_order_item;
 if not found then raise exception 'order_item_not_found';end if;
 select * into o from public.yt_member_orders where id=i.order_id and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 if o.status<>'fulfilled' or o.payment_status<>'paid' or o.paid_at is null then raise exception 'store_box_after_payment_only';end if;
 if o.settlement_due_since is not null or o.cancel_after_refund then raise exception 'order_payment_adjustment_pending';end if;
 select * into r from public.yt_store_box_product_rules where product_id=i.product_id and active;
 if not found then raise exception 'store_box_product_not_configured';end if;
 update public.yt_store_box_claims set status='expired',claim_token=null where box_id in(select id from public.yt_store_boxes where source_order_item_id=i.id) and status='issued' and expires_at<=clock_timestamp();
 select * into c from public.yt_store_box_claims where request_id=p_request;
 h:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 if found then
  if c.token_hash<>h then raise exception 'request_conflict';end if;
  return jsonb_build_object('box_id',c.box_id,'claim_id',c.id,'claim_token',c.claim_token,'expires_at',c.expires_at);
 end if;
 insert into public.yt_store_boxes(source_order_id,source_order_item_id,product_id,customer_id,name,mode,unit_label,total_units,request_limit,expiry_days,completion_reward_id,game_pass_enabled,table_label,created_by)
 values(o.id,i.id,i.product_id,o.customer_id,i.item_name,r.mode,r.unit_label,i.quantity*r.total_units,r.request_limit,r.expiry_days,r.completion_reward_id,r.game_pass_enabled,o.table_label,actor)
 on conflict(source_order_item_id) do nothing;
 select * into b from public.yt_store_boxes where source_order_item_id=i.id for update;
 if b.status not in ('unclaimed','active','paused','exhausted') then raise exception 'store_box_not_issuable';end if;
 if b.customer_id is not null and b.claimed_at is not null then raise exception 'store_box_already_claimed';end if;
 if exists(select 1 from public.yt_store_box_claims where box_id=b.id and status='issued') then raise exception 'store_box_claim_already_active';end if;
 insert into public.yt_store_box_claims(box_id,token_hash,claim_token,request_id,issued_by,expires_at)
 values(b.id,h,p_token,p_request,actor,clock_timestamp()+make_interval(mins=>p_minutes)) returning * into c;
 insert into public.yt_store_box_events(box_id,event_type,actor_id,metadata)
 values(b.id,'claim_issued',actor,jsonb_build_object('claim_id',c.id,'order_id',o.id,'order_item_id',i.id));
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(actor,'store_box.claim_issue','store_box',b.id,jsonb_build_object('claim_id',c.id,'order_id',o.id));
 return jsonb_build_object('box_id',b.id,'claim_id',c.id,'claim_token',c.claim_token,'expires_at',c.expires_at,'name',b.name,'total_units',b.total_units,'unit_label',b.unit_label);
end $$;

create or replace function private.yt_store_box_claims_active() returns jsonb language plpgsql security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_box_claims set status='expired',claim_token=null where status='issued' and expires_at<=clock_timestamp();
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into rows from(
  select c.id claim_id,c.box_id,c.claim_token,c.expires_at,c.created_at,c.issued_by,w.username issued_by_name,
   b.name,b.mode,b.total_units,b.unit_label,b.table_label,o.id order_id,o.order_no
  from public.yt_store_box_claims c join public.yt_store_boxes b on b.id=c.box_id
  join public.yt_member_orders o on o.id=b.source_order_id
  left join public.work_accounts w on w.auth_user_id=c.issued_by
  where c.status='issued' and c.expires_at>clock_timestamp()
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_claim_cancel(p_claim uuid,p_reason text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.yt_store_box_claims%rowtype;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_claim is null or length(btrim(coalesce(p_reason,''))) not between 2 and 200 then raise exception 'invalid_claim_cancellation';end if;
 select * into c from public.yt_store_box_claims where id=p_claim for update;
 if not found then raise exception 'store_box_claim_not_found';end if;
 if c.status='cancelled' then return jsonb_build_object('ok',true,'already_cancelled',true);end if;
 if c.status<>'issued' then raise exception 'store_box_claim_not_cancellable';end if;
 update public.yt_store_box_claims set status='cancelled',claim_token=null,cancelled_by=auth.uid(),cancelled_at=clock_timestamp(),cancel_reason=btrim(p_reason) where id=c.id;
 insert into public.yt_store_box_events(box_id,event_type,actor_id,note) values(c.box_id,'claim_cancelled',auth.uid(),btrim(p_reason));
 return jsonb_build_object('ok',true,'box_id',c.box_id);
end $$;

create or replace function private.yt_store_box_staff_boxes() returns jsonb language plpgsql security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_boxes set status='expired',updated_at=clock_timestamp()
  where storage_expires_at<=clock_timestamp() and status in ('active','paused','exhausted');
 select coalesce(jsonb_agg(to_jsonb(x) order by x.storage_expires_at,x.updated_at desc),'[]'::jsonb) into rows from(
  select b.id,b.name,b.mode,b.status,b.unit_label,b.total_units,b.served_units,b.completed_units,
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

create function public.yt_store_box_issue_orders() returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_issue_orders()$$;
create function public.yt_store_box_staff_boxes() returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_staff_boxes()$$;
revoke all on function private.yt_store_box_issue_orders(),private.yt_store_box_staff_boxes(),public.yt_store_box_issue_orders(),public.yt_store_box_staff_boxes() from public,anon;
grant execute on function private.yt_store_box_issue_orders(),private.yt_store_box_staff_boxes(),public.yt_store_box_issue_orders(),public.yt_store_box_staff_boxes() to authenticated;
