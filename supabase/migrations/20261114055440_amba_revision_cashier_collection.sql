-- Approved Amba revisions may leave a positive balance for Cashier to collect.
CREATE OR REPLACE FUNCTION private.yt_pos_adjustment_pay(p_order uuid, p_amount numeric, p_method text, p_note text, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_member_orders%rowtype;e public.yt_pos_payment_entries%rowtype;balance numeric;entry_method text;ff_received numeric;
begin
 if not private.yt_work_owner() and not (private.yt_pos_work_cashier() and p_amount>0 and exists(select 1 from public.yt_ambassador_pos_sales where order_id=p_order) and (exists(select 1 from public.audit_logs where action='freeflow.pax_add' and entity_id=p_order) or exists(select 1 from public.yt_pos_order_revisions where order_id=p_order))) then raise exception 'owner_only';end if;
 if p_request is null or p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount=0 or abs(p_amount)>100000 or p_amount<>round(p_amount,2) or p_method is null or p_method not in ('foodcourt','cash','duitnow','card','bank_transfer','other') or length(btrim(coalesce(p_note,''))) not between 2 and 300 then raise exception 'invalid_adjustment_payment';end if;
 perform 1 from public.yt_freeflow_sessions where order_id=p_order for update;
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
 perform private.yt_pos_amba_revision_sync(p_order,v.cancel_after_refund);
 return private.yt_pos_owner_order_context(p_order);
end $function$;
