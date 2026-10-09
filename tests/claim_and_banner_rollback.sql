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

SET LOCAL ROLE authenticated;
SELECT set_config('ytv5.offerdata',public.yt_create_offer_v5(current_setting('ytv5.reward')::uuid,current_setting('ytv5.token')::uuid,
 clock_timestamp()-interval '1 minute',clock_timestamp()+interval '1 day',2,1)::text,true);
SELECT set_config('request.jwt.claim.sub',current_setting('ytv5.customer'),true);
DO $$ DECLARE a jsonb;b jsonb;BEGIN
 IF current_setting('ytv5.offerdata')::jsonb->>'display_code'!~'^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}$' THEN RAISE EXCEPTION 'FAIL format';END IF;
 BEGIN
  PERFORM public.yt_create_offer_v5(current_setting('ytv5.reward')::uuid,gen_random_uuid(),NULL,clock_timestamp()+interval '1 day',1,1);
  RAISE EXCEPTION 'FAIL member issuance';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'owner_only' THEN RAISE;END IF;END;
 a:=public.yt_claim_offer_code(' '||lower(current_setting('ytv5.offerdata')::jsonb->>'display_code')||' ',current_setting('ytv5.req')::uuid);
 IF jsonb_array_length(a->'awards') IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL short claim: %',a;END IF;
 b:=public.yt_claim_offer_code(current_setting('ytv5.offerdata')::jsonb->>'short_code',current_setting('ytv5.req')::uuid);
 IF a IS DISTINCT FROM b THEN RAISE EXCEPTION 'FAIL retry';END IF;
 IF (SELECT award_id FROM public.yt_claim_offer(current_setting('ytv5.token')::uuid,current_setting('ytv5.req')::uuid))::text IS DISTINCT FROM (a->'awards'->0->>'award_id') THEN RAISE EXCEPTION 'FAIL UUID compatibility';END IF;
 b:=public.yt_claim_offer_code(current_setting('ytv5.offerdata')::jsonb->>'short_code',gen_random_uuid());
 IF b->>'error_code' IS DISTINCT FROM 'account_claim_limit' THEN RAISE EXCEPTION 'FAIL per-user limit';END IF;
END;$$;
SET LOCAL ROLE postgres;
UPDATE public.reward_offers SET max_claims=1 WHERE id=(current_setting('ytv5.offerdata')::jsonb->>'offer_id')::uuid;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',current_setting('ytv5.staff'),true);
DO $$ DECLARE a jsonb;BEGIN
 a:=public.yt_claim_offer_code(current_setting('ytv5.offerdata')::jsonb->>'short_code',gen_random_uuid());
 IF a->>'error_code' IS DISTINCT FROM 'offer_unavailable' THEN RAISE EXCEPTION 'FAIL total cap: %',a;END IF;
END;$$;
SET LOCAL ROLE postgres;
DO $$ BEGIN
 IF (SELECT claimed_count FROM public.reward_offers WHERE id=(current_setting('ytv5.offerdata')::jsonb->>'offer_id')::uuid)<>1
 OR (SELECT count(*) FROM public.reward_offer_claims WHERE offer_id=(current_setting('ytv5.offerdata')::jsonb->>'offer_id')::uuid)<>1 THEN RAISE EXCEPTION 'FAIL duplicate awards';END IF;
END;$$;
-- Expiry is checked by the shared claim core, while successful request retries survive expiry.
UPDATE public.reward_offers SET ends_at=clock_timestamp()-interval '1 second' WHERE id=(current_setting('ytv5.offerdata')::jsonb->>'offer_id')::uuid;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',current_setting('ytv5.customer'),true);
DO $$ DECLARE a jsonb;BEGIN
 a:=public.yt_claim_offer_code(current_setting('ytv5.offerdata')::jsonb->>'short_code',current_setting('ytv5.req')::uuid);
 IF jsonb_array_length(a->'awards') IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL expiry safe retry';END IF;
END;$$;
SET LOCAL ROLE postgres;
DELETE FROM private.yt_offer_code_attempts WHERE customer_id=current_setting('ytv5.customer')::uuid;
SET LOCAL ROLE authenticated;
DO $$ DECLARE a jsonb;i int;BEGIN
 FOR i IN 1..20 LOOP
  a:=public.yt_claim_offer_code('BAD',gen_random_uuid());
  IF a->>'error_code' IS DISTINCT FROM 'claim_code_invalid' THEN RAISE EXCEPTION 'FAIL guessing counter';END IF;
 END LOOP;
 a:=public.yt_claim_offer_code('BAD',gen_random_uuid());
 IF a->>'error_code' IS DISTINCT FROM 'claim_code_rate_limited' THEN RAISE EXCEPTION 'FAIL rate limit';END IF;
END;$$;
SET LOCAL ROLE postgres;
DO $$ BEGIN
 IF (SELECT attempts FROM private.yt_offer_code_attempts WHERE customer_id=current_setting('ytv5.customer')::uuid)<>21
 OR has_function_privilege('anon','public.yt_claim_offer_code(text,uuid)','EXECUTE')
 OR has_function_privilege('authenticated','private.yt_claim_offer_by_hash(text,uuid)','EXECUTE') THEN RAISE EXCEPTION 'FAIL claim permissions';END IF;
END;$$;
-- Storage policy test: rollback-only metadata; no physical files are created.
SELECT set_config('ytv5.image','ads/'||gen_random_uuid()::text||'.jpg',true);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',current_setting('ytv5.customer'),true);
DO $$ BEGIN
 BEGIN
  INSERT INTO storage.objects(bucket_id,name) VALUES('yetipsy-home-banners',current_setting('ytv5.image'));
  RAISE EXCEPTION 'FAIL member upload';
 EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN
  PERFORM public.yt_owner_banner_save(NULL,'TEST',current_setting('ytv5.image'),10,true);
  RAISE EXCEPTION 'FAIL member manage';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'owner_only' THEN RAISE;END IF;END;
END;$$;
SELECT set_config('request.jwt.claim.sub',current_setting('ytv5.owner'),true);
INSERT INTO storage.objects(bucket_id,name) VALUES('yetipsy-home-banners',current_setting('ytv5.image'));
SELECT set_config('ytv5.banner',public.yt_owner_banner_save(NULL,'V5 ROLLBACK AD',current_setting('ytv5.image'),0,true)::text,true);
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.yt_home_banner_list()) a WHERE a->>'id'=current_setting('ytv5.banner')) THEN RAISE EXCEPTION 'FAIL published banner';END IF;
END;$$;
SELECT public.yt_owner_banner_save(current_setting('ytv5.banner')::uuid,'V5 ROLLBACK AD',current_setting('ytv5.image'),5,false);
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(public.yt_home_banner_list()) a WHERE a->>'id'=current_setting('ytv5.banner')) THEN RAISE EXCEPTION 'FAIL disabled ad';END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.yt_owner_banner_list()) a WHERE a->>'id'=current_setting('ytv5.banner') AND (a->>'sort_order')::int=5) THEN RAISE EXCEPTION 'FAIL admin edit';END IF;
END;$$;
SET LOCAL ROLE anon;
SELECT public.yt_home_banner_list();
SET LOCAL ROLE postgres;
DO $$ BEGIN
 IF (SELECT file_size_limit FROM storage.buckets WHERE id='yetipsy-home-banners')<>5242880
 OR has_function_privilege('anon','public.yt_owner_banner_save(uuid,text,text,integer,boolean)','EXECUTE')
 OR EXISTS(SELECT 1 FROM pg_class WHERE oid IN('private.yt_offer_short_codes'::regclass,'private.yt_offer_code_attempts'::regclass,'public.yt_home_banners'::regclass) AND NOT relrowsecurity)
 THEN RAISE EXCEPTION 'FAIL storage or RLS';END IF;
END;$$;
SELECT 'PASS: normalized short claim, safe retry, UUID compatibility, per-user and total limits, rate limiter, Owner-only upload/management, publish/sort/unpublish and anonymous public ads' AS result;
ROLLBACK;
