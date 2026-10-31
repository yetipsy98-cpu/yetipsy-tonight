BEGIN;
DO $test$
DECLARE actor uuid;member uuid;reward uuid;award uuid;product uuid:='c34c9d9e-2d96-4696-a0b1-fc5805d8c800';token uuid:=gen_random_uuid();draft uuid:=gen_random_uuid();h jsonb;s jsonb;o jsonb;oid uuid;
BEGIN
SELECT auth_user_id INTO actor FROM public.work_accounts WHERE role='owner' AND active AND NOT must_change_password LIMIT 1;
SELECT auth_user_id INTO member FROM public.pin_accounts LIMIT 1;
IF actor IS NULL OR member IS NULL THEN RAISE EXCEPTION 'missing_test_identity'; END IF;
INSERT INTO public.rewards(name,category,active,next_day_only) VALUES('ROLLBACK zero purchase QR test','drink',true,false) RETURNING id INTO reward;
INSERT INTO public.yt_pos_reward_rules(reward_id,mode,product_id,discount_type,discount_value,min_paid_drinks,min_spend_rm) VALUES(reward,'product',product,'free',0,0,0);
INSERT INTO public.user_rewards(customer_id,reward_id,redeem_after,expires_at) VALUES(member,reward,clock_timestamp()-interval '1 hour',clock_timestamp()+interval '1 day') RETURNING id INTO award;
UPDATE public.user_rewards SET redeem_after=clock_timestamp()-interval '1 hour' WHERE id=award;
PERFORM set_config('request.jwt.claim.sub',member::text,true);
PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
s:=public.yt_make_redeem_v5(award,token);
PERFORM set_config('request.jwt.claim.sub',actor::text,true);
PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
UPDATE public.yt_pos_reward_rules SET min_paid_drinks=1 WHERE reward_id=reward;
BEGIN
 PERFORM public.yt_pos_preorder_scan(draft,token,gen_random_uuid(),'[]');
 RAISE EXCEPTION 'FAIL positive minimum bypass';
EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'minimum_purchase_not_met' THEN RAISE; END IF; END;
UPDATE public.yt_pos_reward_rules SET min_paid_drinks=0 WHERE reward_id=reward;
BEGIN
 PERFORM public.yt_pos_create_order_with_rewards(gen_random_uuid(),'EMPTY INVALID',NULL,'[]','staff',gen_random_uuid());
 RAISE EXCEPTION 'FAIL empty order without reward';
EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'minimum_purchase_not_met' THEN RAISE; END IF; END;
h:=public.yt_pos_preorder_scan(draft,token,gen_random_uuid(),'[]');
IF h->>'id' IS NULL THEN RAISE EXCEPTION 'scan_failed %',h; END IF;
s:=public.yt_pos_preorder_scan_code(draft,s->>'short_code',gen_random_uuid(),'[]');
IF s->>'id' IS DISTINCT FROM h->>'id' THEN RAISE EXCEPTION 'QR_short_code_mismatch %',s;END IF;
PERFORM public.yt_pos_preorder_choose((h->>'id')::uuid,product,NULL,'[]');
s:=public.yt_pos_preorder_summary(draft,'[]');
IF (s->>'payable_rm')::numeric<>0 OR NOT (s->>'can_submit')::boolean THEN RAISE EXCEPTION 'zero_summary_failed %',s;END IF;
o:=public.yt_pos_create_order_with_rewards(gen_random_uuid(),'QR TEST ROLLBACK',NULL,'[]','staff',draft);
oid:=(o->>'id')::uuid;
IF oid IS NULL THEN RAISE EXCEPTION 'order_failed %',o;END IF;
s:=public.yt_pos_bill_v8(oid);
IF (s->>'amount_rm')::numeric<>0 THEN RAISE EXCEPTION 'nonzero_bill %',s;END IF;
PERFORM public.yt_pos_action(oid,'accept');
PERFORM public.yt_pos_action(oid,'fulfilled');
PERFORM public.yt_pos_action(oid,'paid',NULL,'foodcourt');
IF (SELECT status FROM public.user_rewards WHERE id=award)<>'redeemed' OR (SELECT count(*) FROM public.redemptions WHERE user_reward_id=award)<>1 THEN RAISE EXCEPTION 'redemption_failed';END IF;
IF (SELECT price_rm FROM public.yt_shop_products WHERE id=product)<>999.99 THEN RAISE EXCEPTION 'price_changed'; END IF;
END $test$;
ROLLBACK;
SELECT 'PASS QR + short code, empty cart, free Blood Shot, zero bill, order accept/fulfill/pay, single redemption, price preserved; fixtures rolled back' result;