BEGIN;
SELECT set_config('ytv6.owner',(SELECT auth_user_id::text FROM public.work_accounts WHERE role='owner' AND active LIMIT 1),true);
SELECT set_config('ytv6.customer',(SELECT auth_user_id::text FROM public.pin_accounts ORDER BY created_at DESC LIMIT 1),true);
SELECT set_config('ytv6.reward','{"name":"V6 ROLLBACK RM5","category":"voucher","validity_days":30,"next_day_only":false}'::jsonb::text,true);
SELECT set_config('ytv6.binding','{"mode":"any_drink","product_id":null,"series_id":null,"discount_type":"fixed","discount_value":5,"min_paid_drinks":1,"min_spend_rm":0}'::jsonb::text,true);
SELECT set_config('ytv6.request',gen_random_uuid()::text,true);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',current_setting('ytv6.owner'),true);
SELECT set_config('ytv6.created',public.yt_owner_create_bound_reward_v6(current_setting('ytv6.reward')::jsonb,current_setting('ytv6.binding')::jsonb,current_setting('ytv6.request')::uuid)::text,true);
DO $$ DECLARE r uuid;b jsonb;n int;BEGIN
 r:=public.yt_owner_create_bound_reward_v6(current_setting('ytv6.reward')::jsonb,current_setting('ytv6.binding')::jsonb,current_setting('ytv6.request')::uuid);
 IF r::text IS DISTINCT FROM current_setting('ytv6.created') THEN RAISE EXCEPTION 'FAIL duplicate creation';END IF;
 SELECT count(*) INTO n FROM public.rewards WHERE name='V6 ROLLBACK RM5';
 IF n<>1 THEN RAISE EXCEPTION 'FAIL request produced multiple rewards';END IF;
 BEGIN
  PERFORM public.yt_owner_create_bound_reward_v6(current_setting('ytv6.reward')::jsonb||'{"name":"different"}',current_setting('ytv6.binding')::jsonb,current_setting('ytv6.request')::uuid);
  RAISE EXCEPTION 'FAIL request conflict';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'request_conflict' THEN RAISE;END IF;END;
 BEGIN
  PERFORM public.yt_owner_create_bound_reward_v6(current_setting('ytv6.reward')::jsonb,'{}',gen_random_uuid());
  RAISE EXCEPTION 'FAIL missing binding';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'reward_not_pos_bound' THEN RAISE;END IF;END;
 BEGIN
  PERFORM public.yt_owner_create_bound_reward_v6(current_setting('ytv6.reward')::jsonb,jsonb_build_object('mode','product','product_id',gen_random_uuid(),'discount_type','free','discount_value',0,'min_paid_drinks',1,'min_spend_rm',0),gen_random_uuid());
  RAISE EXCEPTION 'FAIL invalid product';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'select_active_product' THEN RAISE;END IF;END;
 IF (SELECT count(*) FROM public.rewards WHERE name='V6 ROLLBACK RM5')<>n THEN RAISE EXCEPTION 'FAIL unbound orphan after binding error';END IF;
 BEGIN
  PERFORM public.yt_owner_create_bound_reward_v6(current_setting('ytv6.reward')::jsonb,current_setting('ytv6.binding')::jsonb||'{"min_paid_drinks":0}',gen_random_uuid());
  RAISE EXCEPTION 'FAIL minimum';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'minimum_paid_drink_required' THEN RAISE;END IF;END;
 r:=public.yt_owner_create_bound_reward_v6(current_setting('ytv6.reward')::jsonb||'{"name":"V6 ROLLBACK COPY"}',jsonb_build_object('template_reward_id',current_setting('ytv6.created')),gen_random_uuid());
 PERFORM set_config('ytv6.copied',r::text,true);
 b:=public.yt_create_offer_v5(r,gen_random_uuid(),clock_timestamp()-interval '1 minute',clock_timestamp()+interval '1 day',1,1);
 IF b->>'display_code'!~'^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}$' THEN RAISE EXCEPTION 'FAIL Owner short code';END IF;
 PERFORM set_config('ytv6.code',b->>'short_code',true);
END;$$;
SELECT set_config('request.jwt.claim.sub',current_setting('ytv6.customer'),true);
DO $$ DECLARE b jsonb;BEGIN
 BEGIN
  PERFORM public.yt_owner_create_bound_reward_v6(current_setting('ytv6.reward')::jsonb,current_setting('ytv6.binding')::jsonb,gen_random_uuid());
  RAISE EXCEPTION 'FAIL member creation';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'owner_only' THEN RAISE;END IF;END;
 b:=public.yt_claim_offer_code(current_setting('ytv6.code'),gen_random_uuid());
 IF jsonb_array_length(b->'awards') IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL claim of newly bound reward: %',b;END IF;
END;$$;
SET LOCAL ROLE postgres;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.yt_pos_reward_rules WHERE reward_id=current_setting('ytv6.created')::uuid AND mode='any_drink' AND discount_value=5 AND min_paid_drinks=1)
 OR NOT EXISTS(SELECT 1 FROM public.yt_pos_reward_rules WHERE reward_id=current_setting('ytv6.copied')::uuid AND mode='any_drink' AND discount_value=5 AND min_paid_drinks=1)
 OR has_function_privilege('anon','public.yt_owner_create_bound_reward_v6(jsonb,jsonb,uuid)','EXECUTE') THEN RAISE EXCEPTION 'FAIL binding or permissions';END IF;
END;$$;
SELECT 'PASS: atomic binding, copy existing rights, no orphan on failure, retry once, Owner authorization, short-code claim' AS result;
ROLLBACK;
