BEGIN;
DO $test$
DECLARE actor uuid;member uuid;d date:=(date_trunc('month',private.yt_business_day(now())::timestamp)-interval '1 month')::date+17;products uuid[]:='{}';orders uuid[]:='{}';p uuid;o uuid;r jsonb;n int;before_count int;
BEGIN
 SELECT auth_user_id INTO actor FROM public.work_accounts WHERE role='owner' AND active AND NOT must_change_password LIMIT 1;
 SELECT auth_user_id INTO member FROM public.pin_accounts WHERE NOT EXISTS(SELECT 1 FROM public.work_accounts w WHERE w.auth_user_id=pin_accounts.auth_user_id) LIMIT 1;
 IF actor IS NULL OR member IS NULL THEN RAISE EXCEPTION 'fixture_missing';END IF;
 PERFORM set_config('request.jwt.claim.sub',member::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
 BEGIN PERFORM public.yt_owner_financial_export(d,d);RAISE EXCEPTION 'FAIL customer export';EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'owner_only' THEN RAISE;END IF;END;
 PERFORM set_config('request.jwt.claim.sub',actor::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
 IF has_function_privilege('anon','public.yt_owner_financial_export(date,date)','EXECUTE') THEN RAISE EXCEPTION 'FAIL anonymous export';END IF;
 BEGIN PERFORM public.yt_owner_financial_export(d,d+366);RAISE EXCEPTION 'FAIL unbounded range';EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'invalid_report_range' THEN RAISE;END IF;END;
 r:=public.yt_owner_financial_export(d,d);before_count:=(r#>>'{counts,orders}')::int;
 FOR n IN 1..21 LOOP INSERT INTO public.yt_shop_products(title,category,price_rm,active,is_drink) VALUES('ROLLBACK PDF product '||n,'PDF TEST',10,true,true) RETURNING id INTO p;products:=array_append(products,p);END LOOP;
 FOR n IN 1..51 LOOP
  INSERT INTO public.yt_member_orders(source,status,amount_rm,created_by,pos_business_day) VALUES('future_pos','fulfilled',10,actor,d) RETURNING id INTO o;orders:=array_append(orders,o);
  INSERT INTO public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) VALUES(o,products[1+((n-1)%21)],'ROLLBACK PDF product '||(1+((n-1)%21)),1,10);
  UPDATE public.yt_member_orders SET payment_status='paid',paid_at=clock_timestamp(),paid_by=actor,payment_method=case when n%2=0 then 'cash' else 'duitnow' end WHERE id=o;
 END LOOP;
 r:=public.yt_owner_financial_export(d,d);
 IF r->>'complete'<>'true' OR (r#>>'{counts,orders}')::int<>before_count+51 THEN RAISE EXCEPTION 'FAIL export truncated orders';END IF;
 IF (SELECT count(*) FROM jsonb_array_elements(r->'orders')x WHERE (x->>'id')::uuid=ANY(orders))<>51 THEN RAISE EXCEPTION 'FAIL missing order details';END IF;
 IF (SELECT count(DISTINCT x->>'product_id') FROM jsonb_array_elements(r->'products')x WHERE (x->>'product_id')::uuid=ANY(products))<>21 THEN RAISE EXCEPTION 'FAIL truncated products';END IF;
 IF (SELECT sum((x->>'net_rm')::numeric) FROM jsonb_array_elements(r->'days')x)<>(r#>>'{summary,net_rm}')::numeric OR (SELECT sum((x->>'net_rm')::numeric) FROM jsonb_array_elements(r->'payments')x)<>(r#>>'{summary,net_rm}')::numeric THEN RAISE EXCEPTION 'FAIL financial totals';END IF;
 IF (r#>>'{summary,net_rm}')::numeric<>(public.yt_owner_report_v8(d,d)#>>'{stats,range_amount}')::numeric THEN RAISE EXCEPTION 'FAIL differs from live sales';END IF;
END $test$;
ROLLBACK;
SELECT 'PASS complete export includes >50 orders and >20 products, original business dates, matching daily/payment totals, Owner-only access and bounded dates; fixtures rolled back' result;
