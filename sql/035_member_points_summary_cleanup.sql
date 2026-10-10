-- Member summary exposes only the active game-points wallet and member campaign
-- fields. Retired spend-to-random-points configuration is no longer returned.

CREATE OR REPLACE FUNCTION private.yt_loyalty_member_summary()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
 v_actor uuid:=auth.uid();
 v_code text;
 cfg public.yt_loyalty_config%rowtype;
 i integer;
 v_wallet public.yt_point_wallets%rowtype;
BEGIN
 IF v_actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.pin_accounts WHERE auth_user_id=v_actor)
    OR EXISTS(SELECT 1 FROM public.work_accounts WHERE auth_user_id=v_actor)
 THEN RAISE EXCEPTION 'customer_only'; END IF;
 SELECT * INTO cfg FROM public.yt_loyalty_config WHERE id=true;
 SELECT code INTO v_code FROM public.yt_member_ref_codes WHERE customer_id=v_actor;
 IF v_code IS NULL THEN
  FOR i IN 1..8 LOOP
   v_code:='YT'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
   INSERT INTO public.yt_member_ref_codes(customer_id,code)
   VALUES(v_actor,v_code) ON CONFLICT DO NOTHING;
   SELECT code INTO v_code FROM public.yt_member_ref_codes WHERE customer_id=v_actor;
   EXIT WHEN v_code IS NOT NULL;
  END LOOP;
  IF v_code IS NULL THEN RAISE EXCEPTION 'code_generation_failed'; END IF;
 END IF;
 PERFORM pg_advisory_xact_lock(781943081);
 PERFORM private.yt_points_sync(v_actor);
 SELECT * INTO v_wallet FROM public.yt_point_wallets WHERE customer_id=v_actor;
 RETURN jsonb_build_object(
  'referral_code',v_code,
  'referral_enabled',cfg.referral_enabled,
  'welcome_enabled',cfg.welcome_enabled,
  'points_balance',coalesce(v_wallet.balance,0),
  'points_earned',coalesce(v_wallet.lifetime_earned,0),
  'points_history',coalesce((
   SELECT jsonb_agg(to_jsonb(hist)) FROM (
    SELECT direction,points,reference,created_at,source,expires_at
    FROM public.yt_point_entries WHERE customer_id=v_actor
    ORDER BY created_at DESC LIMIT 30
   ) hist
  ),'[]'::jsonb)
 );
END;
$function$;
