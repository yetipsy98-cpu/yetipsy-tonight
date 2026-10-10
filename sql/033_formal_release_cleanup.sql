-- Formal-release cleanup: member campaigns are independent from game points.
-- The retired pre-game random-points RPCs remain as migration history only and
-- are no longer callable by browser roles.

UPDATE public.yt_loyalty_config
SET points_enabled=false,updated_at=clock_timestamp()
WHERE id=true AND points_enabled;

CREATE OR REPLACE FUNCTION private.yt_loyalty_owner_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE cfg public.yt_loyalty_config%rowtype;
BEGIN
 IF NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only'; END IF;
 SELECT * INTO cfg FROM public.yt_loyalty_config WHERE id=true;
 RETURN jsonb_build_object(
  'welcome_enabled',cfg.welcome_enabled,
  'welcome_reward_id',cfg.welcome_reward_id,
  'referral_enabled',cfg.referral_enabled,
  'friend_reward_id',cfg.friend_reward_id,
  'inviter_reward_id',cfg.inviter_reward_id,
  'rewards_stack',cfg.rewards_stack,
  'stats',jsonb_build_object(
   'referred_members',(SELECT count(*) FROM public.yt_referral_links),
   'welcome_grants',(SELECT count(*) FROM public.yt_promo_grants WHERE kind='welcome'),
   'referral_grants',(SELECT count(*) FROM public.yt_promo_grants WHERE kind IN ('friend','inviter'))
  )
 );
END;
$function$;

CREATE OR REPLACE FUNCTION private.yt_loyalty_owner_member_save(
 p_welcome_enabled boolean,
 p_welcome_reward uuid,
 p_referral_enabled boolean,
 p_friend_reward uuid,
 p_inviter_reward uuid,
 p_stack boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
 IF NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only'; END IF;
 IF p_welcome_enabled IS NULL OR p_referral_enabled IS NULL OR p_stack IS NULL
 THEN RAISE EXCEPTION 'invalid_member_settings'; END IF;
 IF p_welcome_enabled AND NOT EXISTS(
  SELECT 1 FROM public.rewards WHERE id=p_welcome_reward AND active
 ) THEN RAISE EXCEPTION 'select_welcome_reward'; END IF;
 IF p_referral_enabled AND NOT EXISTS(
  SELECT 1 FROM public.rewards WHERE id=p_friend_reward AND active
 ) THEN RAISE EXCEPTION 'select_referral_reward'; END IF;
 IF p_inviter_reward IS NOT NULL AND NOT EXISTS(
  SELECT 1 FROM public.rewards WHERE id=p_inviter_reward AND active
 ) THEN RAISE EXCEPTION 'invalid_inviter_reward'; END IF;

 UPDATE public.yt_loyalty_config
 SET welcome_enabled=p_welcome_enabled,
     welcome_reward_id=p_welcome_reward,
     referral_enabled=p_referral_enabled,
     friend_reward_id=p_friend_reward,
     inviter_reward_id=p_inviter_reward,
     rewards_stack=p_stack,
     updated_at=clock_timestamp(),
     updated_by=auth.uid()
 WHERE id=true;

 INSERT INTO public.audit_logs(actor_id,action,entity_type,metadata)
 VALUES(auth.uid(),'loyalty.member_settings_updated','loyalty_config',
  jsonb_build_object('welcome',p_welcome_enabled,'referral',p_referral_enabled));
 RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.yt_loyalty_owner_settings()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO ''
AS $function$ SELECT private.yt_loyalty_owner_settings(); $function$;

CREATE OR REPLACE FUNCTION public.yt_loyalty_owner_member_save(
 p_welcome_enabled boolean,
 p_welcome_reward uuid,
 p_referral_enabled boolean,
 p_friend_reward uuid,
 p_inviter_reward uuid,
 p_stack boolean
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path TO ''
AS $function$
 SELECT private.yt_loyalty_owner_member_save(
  p_welcome_enabled,p_welcome_reward,p_referral_enabled,p_friend_reward,p_inviter_reward,p_stack
 );
$function$;

REVOKE ALL ON FUNCTION private.yt_loyalty_owner_settings() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.yt_loyalty_owner_member_save(boolean,uuid,boolean,uuid,uuid,boolean) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.yt_loyalty_owner_settings() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.yt_loyalty_owner_member_save(boolean,uuid,boolean,uuid,uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.yt_loyalty_owner_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.yt_loyalty_owner_member_save(boolean,uuid,boolean,uuid,uuid,boolean) TO authenticated;

REVOKE ALL ON FUNCTION public.yt_claim_random_points(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.yt_claim_random_points(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.yt_point_pass_quote(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.yt_point_pass_quote(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.yt_loyalty_owner_tier(uuid,integer,integer,boolean) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.yt_loyalty_owner_tier(uuid,integer,integer,boolean) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.yt_loyalty_owner_save(boolean,uuid,boolean,uuid,uuid,boolean,boolean,integer,numeric,numeric,numeric) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.yt_loyalty_owner_save(boolean,uuid,boolean,uuid,uuid,boolean,boolean,integer,numeric,numeric,numeric) FROM PUBLIC,anon,authenticated;
