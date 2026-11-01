BEGIN;
DO $test$
DECLARE actor uuid;product uuid;o uuid;line uuid;d date:=private.yt_business_day(now());r jsonb;n int;method text;
BEGIN
 SELECT auth_user_id INTO actor FROM public.work_accounts WHERE role='owner' AND active AND NOT must_change_password LIMIT 1;
 IF actor IS NULL THEN RAISE EXCEPTION 'fixture_missing';END IF;
 PERFORM set_config('request.jwt.claim.sub',actor::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
 INSERT INTO public.yt_shop_products(title,price_rm,active,is_drink) VALUES('ROLLBACK method grouping',20,true,true) RETURNING id INTO product;
 FOR n IN 1..3 LOOP
  method:=case when n=3 then 'duitnow' else 'cash' end;
  INSERT INTO public.yt_member_orders(source,status,amount_rm,created_by,pos_business_day)
  VALUES('future_pos','fulfilled',case when n=1 then 40 else 20 end,actor,d) RETURNING id INTO o;
  INSERT INTO public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
  VALUES(o,product,'ROLLBACK method grouping',1,20) RETURNING id INTO line;
  IF n=1 THEN INSERT INTO public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
   VALUES(o,product,'ROLLBACK method grouping',1,20);END IF;
  UPDATE public.yt_member_orders SET payment_status='paid',paid_at=clock_timestamp(),paid_by=actor,payment_method=method WHERE id=o;
  IF n=1 THEN
   UPDATE public.yt_member_order_items SET unit_price_rm=25 WHERE id=line;
   UPDATE public.yt_member_orders SET amount_rm=45 WHERE id=o;
   PERFORM public.yt_pos_adjustment_pay(o,5,'duitnow','ROLLBACK later top up',gen_random_uuid());
   UPDATE public.yt_member_order_items SET unit_price_rm=22 WHERE id=line;
   UPDATE public.yt_member_orders SET amount_rm=42 WHERE id=o;
   PERFORM public.yt_pos_adjustment_pay(o,-3,'card','ROLLBACK later refund',gen_random_uuid());
  END IF;
 END LOOP;
 r:=public.yt_pos_day_preview(d);
 IF (SELECT count(*) FROM jsonb_array_elements(r->'items') x WHERE x->>'product_id'=product::text)<>2 THEN RAISE EXCEPTION 'FAIL payment methods not separated';END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(r->'items') x WHERE x->>'product_id'=product::text AND x->>'payment_method'='cash' AND (x->>'quantity')::int=3 AND (x->>'net_rm')::numeric=62) THEN RAISE EXCEPTION 'FAIL matching cash rows not combined';END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(r->'items') x WHERE x->>'product_id'=product::text AND x->>'payment_method'='duitnow' AND (x->>'quantity')::int=1 AND (x->>'net_rm')::numeric=20) THEN RAISE EXCEPTION 'FAIL DuitNow row';END IF;
 IF (SELECT sum((x->>'quantity')::int) FROM jsonb_array_elements(r->'items') x WHERE x->>'product_id'=product::text)<>4 THEN RAISE EXCEPTION 'FAIL corrections duplicated cups';END IF;
 IF (SELECT sum((x->>'net_rm')::numeric) FROM jsonb_array_elements(r->'items') x WHERE x->>'product_id'=product::text)<>82 THEN RAISE EXCEPTION 'FAIL item money changed';END IF;
END $test$;
ROLLBACK;
SELECT 'PASS same product/method combined, cash and DuitNow split, duplicate order lines combined, later top-up/refund do not duplicate cups; fixtures rolled back' result;
