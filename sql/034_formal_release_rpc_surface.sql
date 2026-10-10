-- Keep the exposed wrappers as invokers so Supabase's public-schema advisor
-- sees no unnecessary SECURITY DEFINER surface. The guarded implementation is
-- in the non-exposed private schema and still checks the active Owner account.

CREATE OR REPLACE FUNCTION public.yt_loyalty_owner_settings()
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
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
SECURITY INVOKER
SET search_path TO ''
AS $function$
 SELECT private.yt_loyalty_owner_member_save(
  p_welcome_enabled,p_welcome_reward,p_referral_enabled,p_friend_reward,p_inviter_reward,p_stack
 );
$function$;

REVOKE ALL ON FUNCTION private.yt_loyalty_owner_settings() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.yt_loyalty_owner_member_save(boolean,uuid,boolean,uuid,uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_loyalty_owner_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION private.yt_loyalty_owner_member_save(boolean,uuid,boolean,uuid,uuid,boolean) TO authenticated;

REVOKE ALL ON FUNCTION public.yt_loyalty_owner_settings() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.yt_loyalty_owner_member_save(boolean,uuid,boolean,uuid,uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.yt_loyalty_owner_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.yt_loyalty_owner_member_save(boolean,uuid,boolean,uuid,uuid,boolean) TO authenticated;
