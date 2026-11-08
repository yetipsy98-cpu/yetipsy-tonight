CREATE OR REPLACE FUNCTION private.yt_pos_adjustment_pay(p_order uuid, p_amount numeric, p_method text, p_note text, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_member_orders%rowtype;e public.yt_pos_payment_entries%rowtype;balance numeric;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_request is null or p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount=0 or abs(p_amount)>100000 or p_amount<>round(p_amount,2) or p_method is null or p_method not in ('foodcourt','cash','duitnow','card','bank_transfer','other') or length(btrim(coalesce(p_note,''))) not between 2 and 300 then raise exception 'invalid_adjustment_payment';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 select * into e from public.yt_pos_payment_entries where request_id=p_request;
 if found then if e.order_id<>p_order or e.amount_rm<>p_amount or e.method<>p_method or coalesce(e.note,'')<>p_note then raise exception 'request_conflict';end if;return private.yt_pos_owner_order_context(p_order);end if;
 if v.payment_status<>'paid' then raise exception 'order_not_paid';end if;
 balance:=v.amount_rm-private.yt_pos_received(p_order);
 if balance=0 or sign(balance)<>sign(p_amount) or abs(p_amount)>abs(balance) then raise exception 'adjustment_exceeds_balance';end if;
 perform pg_advisory_xact_lock(781943080);
 insert into public.yt_pos_payment_entries(order_id,request_id,method,amount_rm,kind,received_at,business_day,actor_id,note)
 values(p_order,p_request,p_method,p_amount,case when p_amount<0 then 'refund' else 'adjustment' end,clock_timestamp(),coalesce(v.pos_business_day,(select sale.business_day from public.yt_pos_payment_entries sale where sale.order_id=v.id and sale.kind='sale' order by sale.received_at,sale.id limit 1),private.yt_business_day(v.created_at)),auth.uid(),p_note);
 balance:=v.amount_rm-private.yt_pos_received(p_order);
 update public.yt_member_orders set settlement_due_since=case when balance=0 then null else coalesce(settlement_due_since,clock_timestamp()) end,
 payment_status=case when cancel_after_refund and balance=0 then 'refunded' else payment_status end,
 status=case when cancel_after_refund and balance=0 then 'refunded' else status end,updated_at=clock_timestamp() where id=p_order;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.adjustment_payment','pos_order',p_order,jsonb_build_object('amount_rm',p_amount,'method',p_method,'note',p_note,'remaining',balance));
 return private.yt_pos_owner_order_context(p_order);
end $function$
;

CREATE OR REPLACE FUNCTION private.yt_pos_owner_order_context(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b jsonb;
begin
 if not (private.yt_work_owner() or private.yt_pos_work_cashier()) then raise exception 'owner_only';end if;
 b:=private.yt_pos_bill_v8(p_order);
 return b||jsonb_build_object('items',coalesce((select jsonb_agg(jsonb_build_object('id',id,'product_id',product_id,'name',item_name,'quantity',quantity,'price_rm',unit_price_rm) order by id) from public.yt_member_order_items where order_id=p_order and quantity>0),'[]'::jsonb),
 'benefits',private.yt_pos_order_benefits(p_order),'received_rm',private.yt_pos_received(p_order),
 'revisions',coalesce((select jsonb_agg(to_jsonb(x) order by x.revision desc) from(select revision,reason,created_at,revoke_benefits,before_state->'amount_rm' before_amount,after_state->'amount_rm' after_amount,coalesce(before_state->>'business_day',before_state->>'pos_business_day',private.yt_business_day((before_state->>'created_at')::timestamptz)::text) before_business_day,coalesce(after_state->>'business_day',after_state->>'pos_business_day',private.yt_business_day((after_state->>'created_at')::timestamptz)::text) after_business_day from public.yt_pos_order_revisions where order_id=p_order order by revision desc limit 20)x),'[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION private.yt_pos_payment_capture()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.source='future_pos' and new.payment_status='paid' and old.payment_status<>'paid' and new.amount_rm>0 then
  insert into public.yt_pos_payment_entries(order_id,request_id,method,amount_rm,kind,received_at,business_day,actor_id)
  values(new.id,gen_random_uuid(),new.payment_method,new.amount_rm,'sale',new.paid_at,coalesce(new.pos_business_day,private.yt_business_day(new.created_at)),new.paid_by);
 end if;return new;
end $function$
;

CREATE OR REPLACE FUNCTION private.yt_pos_receipt(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_member_orders%rowtype;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found';end if;
 return jsonb_build_object(
  'id',v.id,'order_no',v.order_no,'table_label',v.table_label,
  'notes',v.notes,'status',v.status,'payment_status',v.payment_status,
  'payment_method',v.payment_method,'paid_at',v.paid_at,'paid_by',v.paid_by,
  'business_day',coalesce(v.pos_business_day,private.yt_business_day(v.created_at)),'created_at',v.created_at,'updated_at',v.updated_at,
  'discount_total_rm',coalesce((select sum(u.reward_discount_rm)
    from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id
    where i.order_id=v.id and i.quantity>0 and not u.retired),0)+5*(select count(*) from public.yt_moon_guest_codes c where c.kind='R0' and c.redeemed_order_id=v.id and c.status='redeemed'),
  'moon_codes',coalesce((select jsonb_agg(jsonb_build_object('kind',c.kind,'code',c.code,'item_id',c.reserved_item_id)) from public.yt_moon_guest_codes c where (c.reserved_order_id=v.id or c.redeemed_order_id=v.id) and c.status in ('reserved','redeemed')),'[]'::jsonb),
  'gross_total_rm',coalesce((select sum(i.quantity*i.unit_price_rm)
    from public.yt_member_order_items i where i.order_id=v.id and i.quantity>0),0),
  'amount_rm',v.amount_rm,
  'created_by',(select a.username from public.work_accounts a where a.auth_user_id=v.created_by),
  'items',coalesce((select jsonb_agg(jsonb_build_object(
    'item_name',i.item_name,'quantity',i.quantity,'unit_price_rm',i.unit_price_rm,
    'line_total_rm',i.quantity*i.unit_price_rm-coalesce((select sum(u.reward_discount_rm) from public.yt_pos_item_units u where u.order_item_id=i.id and not u.retired),0),
    'discount_rm',coalesce((select sum(u.reward_discount_rm) from public.yt_pos_item_units u where u.order_item_id=i.id and not u.retired),0)) order by i.item_name,i.id)
    from public.yt_member_order_items i where i.order_id=v.id and i.quantity>0),'[]'::jsonb),
  'document_type',case when v.payment_status='paid' then 'PAYMENT RECEIPT' else 'UNPAID BILL - NOT A RECEIPT' end,
  'disclaimer','Internal Yetipsy order record. Foodcourt payment method is recorded by cashier; not a tax invoice.',
  'receipt_settings',private.yt_receipt_settings_get()
 );
end;$function$
;


-- Accounting follows the order business day; received_at remains actual receipt time.
create or replace function private.yt_pos_owner_revision_apply_v3(
 p_order uuid,p_items jsonb,p_reason text,p_table text,p_note text,p_expected_updated timestamptz,p_request uuid,
 p_revoke boolean,p_cancel boolean,p_payment_method text,p_business_day date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.yt_member_orders%rowtype;done public.yt_pos_order_revisions%rowtype;payload jsonb;result jsonb;
 old_day date;new_day date;affected date[];new_updated timestamptz;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_request is null or p_order is null then raise exception 'invalid_order_revision';end if;
 payload:=jsonb_build_object('order',p_order,'items',p_items,'reason',p_reason,'table',p_table,'note',p_note,'expected',p_expected_updated,'revoke',p_revoke,'cancel',p_cancel,'payment_method',p_payment_method,'business_day',p_business_day);
 perform pg_advisory_xact_lock(781943081);
 select * into o from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 select * into done from public.yt_pos_order_revisions where request_id=p_request;
 if found then
  if done.order_id<>p_order or done.actor_id is distinct from auth.uid() or done.request_payload is distinct from payload then raise exception 'request_conflict';end if;
  return done.after_state||jsonb_build_object('ok',true,'retried',true);
 end if;
 old_day:=coalesce(o.pos_business_day,private.yt_business_day(o.created_at));
 new_day:=coalesce(p_business_day,old_day);
 if new_day<'2020-01-01' or new_day>private.yt_business_day(clock_timestamp()) then raise exception 'invalid_business_day';end if;
 select array_agg(distinct d) into affected from (
  select business_day d from public.yt_pos_payment_entries where order_id=p_order
  union select old_day union select new_day)x;
 result:=private.yt_pos_owner_revision_apply_v2(p_order,p_items,p_reason,p_table,p_note,p_expected_updated,p_request,p_revoke,p_cancel,p_payment_method);
 perform pg_advisory_xact_lock(781943080);
 update public.yt_member_orders set pos_business_day=new_day,
  backdate_approval_status=case when backdate_approval_status='pending' then 'approved' else backdate_approval_status end,
  updated_at=clock_timestamp() where id=p_order returning updated_at into new_updated;
 update public.yt_pos_order_backdate_requests set status=case when requested_business_day=new_day then 'approved' else 'rejected' end,
  reviewer_id=auth.uid(),reviewed_at=clock_timestamp(),review_note='Owner 改单指定营业日 '||new_day::text||'；'||p_reason
  where order_id=p_order and status='pending';
 update public.yt_pos_payment_entries set business_day=new_day where order_id=p_order and business_day is distinct from new_day;
 -- Keep Ambassador sales and their commission accrual on the same accounting day.
 update public.yt_ambassador_pos_sales set business_day=new_day where order_id=p_order and business_day is distinct from new_day;
 update public.yt_ambassador_checkins set business_day=new_day where request_id=p_order and business_day is distinct from new_day;
 update public.yt_ambassador_ledger l set business_day=new_day from public.yt_ambassador_checkins c
 where c.id=l.checkin_id and c.request_id=p_order and l.entry_type='commission' and l.business_day is distinct from new_day;
 if old_day is distinct from new_day or exists(select 1 from unnest(affected) d where d<>new_day) then
  update public.yt_pos_day_closings set state='reopened',reopened_at=clock_timestamp(),reopened_by=auth.uid(),reopen_reason='订单 '||o.order_no||' 营业日更正：'||old_day::text||' → '||new_day::text
  where business_day=any(affected) and state='closed';
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.order_business_day_corrected','pos_order',p_order,jsonb_build_object('request',p_request,'before_day',old_day,'after_day',new_day,'reason',p_reason,'receipt_timestamps_preserved',true));
 end if;
 result:=result||jsonb_build_object('pos_business_day',new_day,'business_day',new_day,'updated_at',new_updated);
 update public.yt_pos_order_revisions set request_payload=payload,
  before_state=before_state||jsonb_build_object('business_day',old_day),after_state=after_state||result
  where request_id=p_request;
 return result;
end $$;
create or replace function public.yt_pos_owner_revision_apply_v3(
 p_order uuid,p_items jsonb,p_reason text,p_table text,p_note text,p_expected_updated timestamptz,p_request uuid,
 p_revoke boolean,p_cancel boolean,p_payment_method text,p_business_day date)
returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_pos_owner_revision_apply_v3(p_order,p_items,p_reason,p_table,p_note,p_expected_updated,p_request,p_revoke,p_cancel,p_payment_method,p_business_day)
$$;
revoke all on function private.yt_pos_owner_revision_apply_v3(uuid,jsonb,text,text,text,timestamptz,uuid,boolean,boolean,text,date),public.yt_pos_owner_revision_apply_v3(uuid,jsonb,text,text,text,timestamptz,uuid,boolean,boolean,text,date) from public,anon;
grant execute on function private.yt_pos_owner_revision_apply_v3(uuid,jsonb,text,text,text,timestamptz,uuid,boolean,boolean,text,date),public.yt_pos_owner_revision_apply_v3(uuid,jsonb,text,text,text,timestamptz,uuid,boolean,boolean,text,date) to authenticated;

-- Repair existing cross-day receipts under the newly specified order-day policy.
-- Preserve payment timestamps, IDs, methods and amounts; keep an audit per row.
do $$
declare e record;target_day date;
begin
 perform pg_advisory_xact_lock(781943081);
 perform pg_advisory_xact_lock(781943080);
 for e in select p.id,p.order_id,p.business_day,coalesce(o.pos_business_day,private.yt_business_day(o.created_at)) target_day
  from public.yt_pos_payment_entries p join public.yt_member_orders o on o.id=p.order_id
  where o.source='future_pos' and p.business_day is distinct from coalesce(o.pos_business_day,private.yt_business_day(o.created_at))
  for update of p
 loop
  target_day:=e.target_day;
  update public.yt_pos_payment_entries set business_day=target_day where id=e.id;
  update public.yt_pos_day_closings set state='reopened',reopened_at=clock_timestamp(),reopened_by=auth.uid(),reopen_reason='跨日挂单收款归回下单营业日，需重新日结'
   where business_day in(e.business_day,target_day) and state='closed';
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.held_sale_business_day_corrected','pos_order',e.order_id,jsonb_build_object('entry_id',e.id,'before_day',e.business_day,'after_day',target_day,'receipt_timestamps_preserved',true));
 end loop;
end $$;
