-- Lite Protection V1: safe server-authoritative member registration observation.
-- This migration extends 074 and leaves registration, rewards and checkout unchanged.
CREATE OR REPLACE FUNCTION private.yt_lite_link_my_device(p_digest text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $$
DECLARE v_actor uuid := auth.uid(); v_count integer;
BEGIN
 IF v_actor IS NULL OR NOT EXISTS
   (SELECT 1 FROM public.pin_accounts WHERE auth_user_id=v_actor)
   OR EXISTS (SELECT 1 FROM public.work_accounts WHERE auth_user_id=v_actor)
 THEN RAISE EXCEPTION 'customer_only'; END IF;
 IF p_digest IS NULL OR p_digest !~ '^[0-9a-f]{64}$'
 THEN RAISE EXCEPTION 'invalid_device_digest'; END IF;
 -- Browser-provided digest is a weak association signal, NOT proof of a device.
 PERFORM pg_advisory_xact_lock(hashtextextended(p_digest, 0));
 INSERT INTO public.yt_lite_device_links(user_id,device_digest)
 VALUES(v_actor,p_digest)
 ON CONFLICT(user_id,device_digest)
 DO UPDATE SET last_seen=clock_timestamp();
 SELECT count(DISTINCT user_id) INTO v_count
 FROM public.yt_lite_device_links WHERE device_digest=p_digest;
 IF v_count >= 3 AND NOT EXISTS(
   SELECT 1 FROM public.yt_lite_risk_events
   WHERE user_id=v_actor AND event_type='device_multi_account'
   AND detail->>'device_digest'=p_digest
 ) THEN
   INSERT INTO public.yt_lite_risk_events(user_id,event_type,detail)
   VALUES(v_actor,'device_multi_account',jsonb_build_object(
     'device_digest',p_digest,'account_count',v_count));
 END IF;
 RETURN jsonb_build_object('linked',true,'review_only',v_count>=3);
END; $$;
REVOKE ALL ON FUNCTION private.yt_lite_link_my_device(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_lite_link_my_device(text) TO authenticated;
CREATE OR REPLACE FUNCTION public.yt_lite_link_my_device(p_digest text)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path TO ''
AS $$ SELECT private.yt_lite_link_my_device(p_digest); $$;
REVOKE ALL ON FUNCTION public.yt_lite_link_my_device(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.yt_lite_link_my_device(text) TO authenticated;
