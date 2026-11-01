BEGIN;
DO $test$
DECLARE actor uuid;orig date:=(date_trunc('month',private.yt_business_day(now())::timestamp)-interval '1 month')::date+17;today date:=private.yt_business_day(now());o uuid;req uuid;case_no int;start_time timestamptz:=clock_timestamp();
 before_day numeric;before_week numeric;before_month numeric;before_today numeric;before_this_month numeric;r jsonb;
BEGIN
 SELECT auth_user_id INTO actor FROM public.work_accounts WHERE role='owner' AND active AND NOT must_change_password LIMIT 1;
 IF actor IS NULL THEN RAISE EXCEPTION 'fixture_missing';END IF;
 PERFORM set_config('request.jwt.claim.sub',actor::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
 before_day:=(public.yt_owner_report_v8(orig,orig)#>>'{stats,range_amount}')::numeric;
 before_week:=(public.yt_owner_report_v8(orig-6,orig)#>>'{stats,range_amount}')::numeric;
 before_month:=(public.yt_owner_report_v8(date_trunc('month',orig::timestamp)::date,(date_trunc('month',orig::timestamp)+interval '1 month - 1 day')::date)#>>'{stats,range_amount}')::numeric;
 r:=public.yt_owner_report_v8(today,today);before_today:=(r#>>'{stats,range_amount}')::numeric;before_this_month:=(r#>>'{stats,month_amount}')::numeric;
 FOR case_no IN 1..2 LOOP
  INSERT INTO public.yt_member_orders(source,status,amount_rm,created_by,pos_business_day)
  VALUES('future_pos','fulfilled',100,actor,case when case_no=1 then orig else null end) RETURNING id INTO o;
  UPDATE public.yt_member_orders SET payment_status='paid',paid_at=case when case_no=1 then clock_timestamp() else private.yt_business_start(orig)+interval '1 hour' end,paid_by=actor,payment_method='cash' WHERE id=o;
  UPDATE public.yt_member_orders SET amount_rm=140 WHERE id=o;
  req:=gen_random_uuid();
  PERFORM public.yt_pos_adjustment_pay(o,40,'cash','ROLLBACK prior-month top up',req);
  PERFORM public.yt_pos_adjustment_pay(o,40,'cash','ROLLBACK prior-month top up',req);
  IF (SELECT count(*) FROM public.yt_pos_payment_entries WHERE order_id=o AND kind='adjustment')<>1 THEN RAISE EXCEPTION 'FAIL retry duplicate';END IF;
  UPDATE public.yt_member_orders SET amount_rm=110 WHERE id=o;
  PERFORM public.yt_pos_adjustment_pay(o,-30,'bank_transfer','ROLLBACK prior-month refund',gen_random_uuid());
  IF EXISTS(SELECT 1 FROM public.yt_pos_payment_entries WHERE order_id=o AND business_day<>orig) THEN RAISE EXCEPTION 'FAIL adjustments assigned to today';END IF;
  IF EXISTS(SELECT 1 FROM public.yt_pos_payment_entries WHERE order_id=o AND kind IN ('refund','adjustment') AND received_at<start_time) THEN RAISE EXCEPTION 'FAIL actual payment timestamps rewritten';END IF;
  r:=public.yt_pos_bill_v8(o);
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(r->'payment_entries') x WHERE x->>'business_day'<>orig::text) THEN RAISE EXCEPTION 'FAIL displayed accounting day';END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(r->'payment_entries') x WHERE x->>'kind' in ('adjustment','refund') AND coalesce(x->>'amendment_note','') NOT LIKE '%'||to_char(clock_timestamp() at time zone 'Asia/Kuala_Lumpur','YYYY-MM-DD')||'%') THEN RAISE EXCEPTION 'FAIL amendment date note';END IF;
  r:=public.yt_owner_report_v8(orig,orig);
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(r->'orders') x WHERE x->>'id'=o::text AND x->>'business_day'=orig::text AND x->>'amendment_note' LIKE '%修改退款%') THEN RAISE EXCEPTION 'FAIL report accounting day and note';END IF;
  IF private.yt_pos_received(o)<>110 THEN RAISE EXCEPTION 'FAIL net receipts';END IF;
 END LOOP;
 IF (public.yt_owner_report_v8(orig,orig)#>>'{stats,range_amount}')::numeric<>before_day+220 THEN RAISE EXCEPTION 'FAIL original day sales';END IF;
 IF (public.yt_owner_report_v8(orig-6,orig)#>>'{stats,range_amount}')::numeric<>before_week+220 THEN RAISE EXCEPTION 'FAIL original week sales';END IF;
 IF (public.yt_owner_report_v8(date_trunc('month',orig::timestamp)::date,(date_trunc('month',orig::timestamp)+interval '1 month - 1 day')::date)#>>'{stats,range_amount}')::numeric<>before_month+220 THEN RAISE EXCEPTION 'FAIL original month sales';END IF;
 r:=public.yt_owner_report_v8(today,today);
 IF (r#>>'{stats,range_amount}')::numeric<>before_today OR (r#>>'{stats,month_amount}')::numeric<>before_this_month THEN RAISE EXCEPTION 'FAIL current day/month sales changed';END IF;
 IF (public.yt_pos_day_preview(orig)#>>'{stats,net_rm}')::numeric<>before_day+220 THEN RAISE EXCEPTION 'FAIL original daily statement';END IF;
 IF (public.yt_pos_day_preview(today)#>>'{stats,net_rm}')::numeric<>before_today THEN RAISE EXCEPTION 'FAIL current daily statement';END IF;
END $test$;
ROLLBACK;
SELECT 'PASS edits made today affect last-month 18th sales and its week/month/daily statement; current day/month unchanged; explicit order day and original-sale fallback; actual timestamps retained and duplicate retry safe; all fixtures rolled back' result;
