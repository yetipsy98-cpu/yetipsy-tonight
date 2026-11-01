-- Financial corrections follow the order's effective business day; receipt timestamps remain actual.
DO $fix$
DECLARE d text;
BEGIN
 PERFORM pg_advisory_xact_lock(781943080);
 SELECT pg_get_functiondef('private.yt_pos_adjustment_pay(uuid,numeric,text,text,uuid)'::regprocedure) INTO d;
 IF strpos(d,'private.yt_business_day(clock_timestamp())')=0 THEN RAISE EXCEPTION 'Expected adjustment day expression not found';END IF;
 d:=replace(d,'private.yt_business_day(clock_timestamp())',
  'coalesce(v.pos_business_day,(select sale.business_day from public.yt_pos_payment_entries sale where sale.order_id=v.id and sale.kind=''sale'' order by sale.received_at,sale.id limit 1),private.yt_business_day(coalesce(v.paid_at,v.created_at)))');
 EXECUTE d;
END $fix$;

-- Repair already recorded corrections and leave an audit trail; reopen affected daily statements.
DO $repair$
DECLARE r record;
BEGIN
 PERFORM pg_advisory_xact_lock(781943080);
 FOR r IN
  SELECT e.id,e.order_id,e.actor_id,e.kind,e.amount_rm,e.received_at,e.business_day old_day,
   coalesce(o.pos_business_day,
    (select sale.business_day from public.yt_pos_payment_entries sale where sale.order_id=o.id and sale.kind='sale' order by sale.received_at,sale.id limit 1),
    private.yt_business_day(coalesce(o.paid_at,o.created_at))) target_day
  FROM public.yt_pos_payment_entries e JOIN public.yt_member_orders o ON o.id=e.order_id
  WHERE e.kind IN ('adjustment','refund')
  AND e.business_day IS DISTINCT FROM coalesce(o.pos_business_day,
    (select sale.business_day from public.yt_pos_payment_entries sale where sale.order_id=o.id and sale.kind='sale' order by sale.received_at,sale.id limit 1),
    private.yt_business_day(coalesce(o.paid_at,o.created_at)))
  FOR UPDATE OF e
 LOOP
  UPDATE public.yt_pos_payment_entries SET business_day=r.target_day WHERE id=r.id;
  UPDATE public.yt_pos_day_closings SET state='reopened',reopened_at=clock_timestamp(),
   reopened_by=r.actor_id,reopen_reason='补收／退款归回原订单营业日，需重新核对日结'
   WHERE business_day IN (r.old_day,r.target_day) AND state='closed';
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  VALUES(r.actor_id,'pos.adjustment_business_day_corrected','pos_order',r.order_id,
   jsonb_build_object('payment_entry_id',r.id,'kind',r.kind,'amount_rm',r.amount_rm,
    'old_business_day',r.old_day,'business_day',r.target_day,'received_at',r.received_at));
 END LOOP;
END $repair$;
