BEGIN;

DO $test$
DECLARE body jsonb; owner_id uuid; member_id uuid; reward_id uuid;
BEGIN
 IF has_function_privilege('authenticated','public.yt_claim_random_points(uuid)','execute')
    OR has_function_privilege('authenticated','public.yt_point_pass_quote(uuid)','execute')
    OR has_function_privilege('authenticated','public.yt_loyalty_owner_tier(uuid,integer,integer,boolean)','execute')
    OR has_function_privilege('authenticated','public.yt_loyalty_owner_save(boolean,uuid,boolean,uuid,uuid,boolean,boolean,integer,numeric,numeric,numeric)','execute')
 THEN RAISE EXCEPTION 'legacy RPC still executable'; END IF;
 IF NOT has_function_privilege('authenticated','public.yt_loyalty_owner_settings()','execute')
    OR NOT has_function_privilege('authenticated','public.yt_loyalty_owner_member_save(boolean,uuid,boolean,uuid,uuid,boolean)','execute')
 THEN RAISE EXCEPTION 'formal member RPC grant missing'; END IF;
 IF has_function_privilege('anon','public.yt_loyalty_owner_settings()','execute')
    OR has_function_privilege('anon','public.yt_loyalty_owner_member_save(boolean,uuid,boolean,uuid,uuid,boolean)','execute')
 THEN RAISE EXCEPTION 'anonymous member admin access'; END IF;

 SELECT auth_user_id INTO owner_id FROM public.work_accounts WHERE role='owner' AND active AND NOT must_change_password LIMIT 1;
 SELECT auth_user_id INTO member_id FROM public.pin_accounts p WHERE NOT EXISTS(SELECT 1 FROM public.work_accounts w WHERE w.auth_user_id=p.auth_user_id) LIMIT 1;
 IF owner_id IS NULL OR member_id IS NULL THEN RAISE EXCEPTION 'fixture_missing'; END IF;
 INSERT INTO public.rewards(name,category,validity_days,next_day_only,active)
 VALUES('formal cleanup rollback','voucher',7,false,true) RETURNING id INTO reward_id;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 PERFORM public.yt_loyalty_owner_member_save(true,reward_id,true,reward_id,null,false);
 body:=public.yt_loyalty_owner_settings();
 IF body ? 'points_enabled' OR body ? 'points_per_rm' OR body ? 'tiers'
    OR (body->>'welcome_reward_id')::uuid<>reward_id
    OR (body->>'friend_reward_id')::uuid<>reward_id
 THEN RAISE EXCEPTION 'focused member settings response invalid'; END IF;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member_id)::text,true);
 BEGIN
  PERFORM public.yt_loyalty_owner_member_save(false,null,false,null,null,false);
  RAISE EXCEPTION 'expected_failure';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM<>'owner_only' THEN RAISE; END IF;
 END;
 body:=public.yt_loyalty_member_summary();
 IF body ? 'points_enabled' OR body ? 'points_per_rm' OR body ? 'max_points_percent'
    OR NOT body ? 'points_balance' OR NOT body ? 'points_history'
 THEN RAISE EXCEPTION 'member summary still exposes retired point mode'; END IF;
END;
$test$;

ROLLBACK;
