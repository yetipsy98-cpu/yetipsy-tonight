-- Owner-facing RPCs must run as the database owner so they can call private-schema
-- implementations. Those implementations continue to check private.yt_work_owner().
CREATE OR REPLACE FUNCTION public.yt_moon_owner_reward_bindings()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path='' AS $function$
 SELECT private.yt_moon_owner_reward_bindings()
$function$;

CREATE OR REPLACE FUNCTION public.yt_moon_owner_bind_reward(p_kind text,p_reward uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path='' AS $function$
 SELECT private.yt_moon_owner_bind_reward(p_kind,p_reward)
$function$;

CREATE OR REPLACE FUNCTION public.yt_moon_owner_unbind_reward(p_kind text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path='' AS $function$
 SELECT private.yt_moon_owner_unbind_reward(p_kind)
$function$;

REVOKE ALL ON FUNCTION public.yt_moon_owner_reward_bindings(),
 public.yt_moon_owner_bind_reward(text,uuid),
 public.yt_moon_owner_unbind_reward(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.yt_moon_owner_reward_bindings(),
 public.yt_moon_owner_bind_reward(text,uuid),
 public.yt_moon_owner_unbind_reward(text) TO authenticated;
