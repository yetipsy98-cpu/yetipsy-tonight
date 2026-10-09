-- Core backend acceptance test: temporary fixtures only; all data mutations roll back.
-- Existing active staff/owner/member identities exercise the actual authenticated APIs.
BEGIN;
SELECT set_config('ytv5.owner',(SELECT auth_user_id::text FROM public.work_accounts WHERE role='owner' AND active LIMIT 1),true);
SELECT set_config('ytv5.staff',(SELECT auth_user_id::text FROM public.work_accounts WHERE role='staff' AND active LIMIT 1),true);
SELECT set_config('ytv5.customer',(SELECT auth_user_id::text FROM public.pin_accounts ORDER BY created_at DESC LIMIT 1),true);
WITH fixture AS (INSERT INTO public.rewards(name,next_day_only,category) VALUES ('V5 ROLLBACK FIXTURE',false,'custom') RETURNING id) SELECT set_config('ytv5.reward',(SELECT id::text FROM fixture),true);
SELECT set_config('ytv5.token',gen_random_uuid()::text,true),set_config('ytv5.draft',gen_random_uuid()::text,true),set_config('ytv5.req',gen_random_uuid()::text,true);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',current_setting('ytv5.owner'),true);
SELECT set_config('ytv5.series',(SELECT public.yt_pos_owner_series(NULL,'V5 ROLLBACK SERIES','games',1,NULL,true,true)::text),true);
SELECT set_config('ytv5.product',(SELECT public.yt_pos_owner_product_v2(NULL,'V5 TEMP CUP','TEST',28,true,999,current_setting('ytv5.series')::uuid)::text),true);
SELECT public.yt_pos_owner_save_reward_v43(current_setting('ytv5.reward')::uuid,'any_drink',NULL,NULL,'fixed',5,1,0);
SET LOCAL ROLE postgres;
INSERT INTO public.user_rewards(customer_id,reward_id,redeem_after,expires_at)
VALUES(current_setting('ytv5.customer')::uuid,current_setting('ytv5.reward')::uuid,clock_timestamp()-interval '1 hour',clock_timestamp()+interval '7 days');
SELECT set_config('ytv5.award',(SELECT id::text FROM public.user_rewards WHERE customer_id=current_setting('ytv5.customer')::uuid AND reward_id=current_setting('ytv5.reward')::uuid ORDER BY created_at DESC,id DESC LIMIT 1),true);
UPDATE public.user_rewards SET redeem_after=clock_timestamp()-interval '1 hour' WHERE id=current_setting('ytv5.award')::uuid;
UPDATE public.rewards SET daily_start_local=NULL,daily_end_local=NULL WHERE id=current_setting('ytv5.reward')::uuid;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',current_setting('ytv5.customer'),true);

SELECT set_config('ytv5.shortdata',public.yt_make_redeem_v5(current_setting('ytv5.award')::uuid,current_setting('ytv5.token')::uuid)::text,true);
DO $$ BEGIN
 IF (current_setting('ytv5.shortdata')::jsonb->>'short_code')!~'^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$'
 OR (current_setting('ytv5.shortdata')::jsonb->>'display_code')!~'^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}$'
 THEN RAISE EXCEPTION 'FAIL code format';END IF;
 BEGIN
  PERFORM public.yt_pos_preorder_scan_code(gen_random_uuid(),'BAD',gen_random_uuid(),'[]');
  RAISE EXCEPTION 'FAIL member staff access';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'staff_only' THEN RAISE;END IF;END;
END;$$;
SELECT set_config('request.jwt.claim.sub',current_setting('ytv5.staff'),true);
DO $$ BEGIN
 BEGIN
  PERFORM public.yt_make_redeem_v5(current_setting('ytv5.award')::uuid,gen_random_uuid());
  RAISE EXCEPTION 'FAIL nonowner issuance';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'reward_not_redeemable' THEN RAISE;END IF;END;
END;$$;
SET LOCAL ROLE postgres;
DELETE FROM private.yt_redeem_code_attempts WHERE operator_id=current_setting('ytv5.staff')::uuid;
SET LOCAL ROLE authenticated;
SELECT set_config('ytv5.hold',(public.yt_pos_preorder_scan_code(current_setting('ytv5.draft')::uuid,
 ' '||lower(current_setting('ytv5.shortdata')::jsonb->>'display_code')||' ',gen_random_uuid(),
 jsonb_build_array(jsonb_build_object('product_id',current_setting('ytv5.product'),'quantity',2)))->>'id'),true);
DO $$ DECLARE h jsonb;BEGIN
 IF current_setting('ytv5.hold')='' THEN RAISE EXCEPTION 'FAIL manual scan';END IF;
 h:=public.yt_pos_preorder_scan(current_setting('ytv5.draft')::uuid,current_setting('ytv5.token')::uuid,gen_random_uuid(),
 jsonb_build_array(jsonb_build_object('product_id',current_setting('ytv5.product'),'quantity',2)));
 IF h->>'id'<>current_setting('ytv5.hold') OR (h->>'idempotent')::boolean IS DISTINCT FROM true
 THEN RAISE EXCEPTION 'FAIL QR and code must share hold';END IF;
END;$$;
SELECT public.yt_pos_preorder_choose(current_setting('ytv5.hold')::uuid,current_setting('ytv5.product')::uuid,1,
 jsonb_build_array(jsonb_build_object('product_id',current_setting('ytv5.product'),'quantity',2)));
SELECT set_config('ytv5.order',(public.yt_pos_create_order_with_rewards(current_setting('ytv5.req')::uuid,'V5 SHORT ROLLBACK',NULL,
 jsonb_build_array(jsonb_build_object('product_id',current_setting('ytv5.product'),'quantity',2)),'staff',current_setting('ytv5.draft')::uuid)->>'id'),true);
SET LOCAL ROLE postgres;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.user_rewards WHERE id=current_setting('ytv5.award')::uuid AND status='available')
 OR (SELECT count(*) FROM public.yt_pos_reward_holds WHERE user_reward_id=current_setting('ytv5.award')::uuid AND state='ready')<>1
 THEN RAISE EXCEPTION 'FAIL submit lock';END IF;
END;$$;
SET LOCAL ROLE authenticated;
DO $$ DECLARE h jsonb;BEGIN
 h:=public.yt_pos_preorder_scan_code(gen_random_uuid(),current_setting('ytv5.shortdata')::jsonb->>'short_code',gen_random_uuid(),
 jsonb_build_array(jsonb_build_object('product_id',current_setting('ytv5.product'),'quantity',2)));
 IF h->>'error_code' IS DISTINCT FROM 'reward_reserved_by_another_order' THEN RAISE EXCEPTION 'FAIL second order lock: %',h;END IF;
END;$$;
SELECT set_config('request.jwt.claim.sub',current_setting('ytv5.owner'),true);
SELECT public.yt_pos_action(current_setting('ytv5.order')::uuid,'accept');
SELECT public.yt_pos_action(current_setting('ytv5.order')::uuid,'fulfilled');
SELECT public.yt_pos_action(current_setting('ytv5.order')::uuid,'paid',NULL,'foodcourt');
SET LOCAL ROLE postgres;
DO $$ BEGIN
 IF (SELECT count(*) FROM public.redemptions WHERE user_reward_id=current_setting('ytv5.award')::uuid)<>1
 OR (SELECT amount_rm FROM public.yt_member_orders WHERE id=current_setting('ytv5.order')::uuid)<>51 THEN RAISE EXCEPTION 'FAIL payment';END IF;
END;$$;
-- A fresh test wallet proves reissuance invalidates old aliases and expiry is enforced.
WITH fixture AS (INSERT INTO public.user_rewards(customer_id,reward_id,redeem_after,expires_at)
 VALUES(current_setting('ytv5.customer')::uuid,current_setting('ytv5.reward')::uuid,clock_timestamp()-interval '1 hour',clock_timestamp()+interval '7 days') RETURNING id)
 SELECT set_config('ytv5.newaward',(SELECT id::text FROM fixture),true);
UPDATE public.user_rewards SET redeem_after=clock_timestamp()-interval '1 hour' WHERE id=current_setting('ytv5.newaward')::uuid;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',current_setting('ytv5.customer'),true);
SELECT set_config('ytv5.oldcode',(public.yt_make_redeem_v5(current_setting('ytv5.newaward')::uuid,gen_random_uuid())->>'short_code'),true);
SELECT set_config('ytv5.newcode',(public.yt_make_redeem_v5(current_setting('ytv5.newaward')::uuid,gen_random_uuid())->>'short_code'),true);
SELECT set_config('request.jwt.claim.sub',current_setting('ytv5.staff'),true);
DO $$ DECLARE h jsonb;BEGIN
 h:=public.yt_pos_preorder_scan_code(gen_random_uuid(),current_setting('ytv5.oldcode'),gen_random_uuid(),'[]');
 IF h->>'error_code' IS DISTINCT FROM 'short_code_invalid_or_expired' THEN RAISE EXCEPTION 'FAIL reissue';END IF;
END;$$;
SET LOCAL ROLE postgres;
UPDATE private.yt_redeem_short_codes SET expires_at=clock_timestamp()-interval '1 second'
 WHERE code_hash=encode(sha256(convert_to(current_setting('ytv5.newcode'),'UTF8')),'hex');
SET LOCAL ROLE authenticated;
DO $$ DECLARE h jsonb;BEGIN
 h:=public.yt_pos_preorder_scan_code(gen_random_uuid(),current_setting('ytv5.newcode'),gen_random_uuid(),'[]');
 IF h->>'error_code' IS DISTINCT FROM 'short_code_invalid_or_expired' THEN RAISE EXCEPTION 'FAIL expiry';END IF;
END;$$;
SET LOCAL ROLE postgres;
DELETE FROM private.yt_redeem_code_attempts WHERE operator_id=current_setting('ytv5.staff')::uuid;
SET LOCAL ROLE authenticated;
DO $$ DECLARE h jsonb;i int;BEGIN
 FOR i IN 1..20 LOOP
  h:=public.yt_pos_preorder_scan_code(gen_random_uuid(),'BAD',gen_random_uuid(),'[]');
  IF h->>'error_code' IS DISTINCT FROM 'short_code_invalid_or_expired' THEN RAISE EXCEPTION 'FAIL early limit';END IF;
 END LOOP;
 h:=public.yt_pos_preorder_scan_code(gen_random_uuid(),'BAD',gen_random_uuid(),'[]');
 IF h->>'error_code' IS DISTINCT FROM 'short_code_rate_limited' THEN RAISE EXCEPTION 'FAIL missing limit';END IF;
END;$$;
SET LOCAL ROLE postgres;
DO $$ BEGIN
 IF (SELECT attempts FROM private.yt_redeem_code_attempts WHERE operator_id=current_setting('ytv5.staff')::uuid)<>21
 THEN RAISE EXCEPTION 'FAIL guesses rolled back';END IF;
 IF has_function_privilege('anon','public.yt_make_redeem_v5(uuid,uuid)','EXECUTE')
 OR has_function_privilege('anon','public.yt_pos_preorder_scan_code(uuid,text,uuid,jsonb)','EXECUTE')
 OR has_function_privilege('authenticated','private.yt_pos_preorder_scan_by_hash(uuid,text,uuid,jsonb)','EXECUTE')
 OR has_table_privilege('authenticated','private.yt_redeem_short_codes','SELECT')
 OR EXISTS(SELECT 1 FROM pg_class WHERE oid IN('private.yt_redeem_short_codes'::regclass,'private.yt_redeem_code_attempts'::regclass) AND NOT relrowsecurity)
 THEN RAISE EXCEPTION 'FAIL permissions';END IF;
END;$$;
SELECT 'PASS: short format, ownership, staff-only, normalized input, shared QR hold, submit lock, single RM5 payment, reissue, expiry, persistent rate limit, RLS and privileges' AS result;
ROLLBACK;
