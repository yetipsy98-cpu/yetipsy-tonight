-- Registration-time association must precede loyalty onboarding.
CREATE OR REPLACE FUNCTION public.yt_lite_register_device(p_user uuid,p_digest text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $$
DECLARE v_count integer;
BEGIN
 IF coalesce(auth.jwt()->>'role','')<>'service_role' THEN RAISE EXCEPTION 'service_only'; END IF;
 IF p_user IS NULL OR p_digest IS NULL OR p_digest !~ '^[0-9a-f]{64}$'
 OR NOT EXISTS(SELECT 1 FROM public.pin_accounts WHERE auth_user_id=p_user)
 THEN RAISE EXCEPTION 'invalid_device_link'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_digest,0));
 INSERT INTO public.yt_lite_device_links(user_id,device_digest) VALUES(p_user,p_digest)
 ON CONFLICT(user_id,device_digest) DO UPDATE SET last_seen=clock_timestamp();
 SELECT count(DISTINCT user_id) INTO v_count FROM public.yt_lite_device_links WHERE device_digest=p_digest;
 IF v_count>=3 THEN
 INSERT INTO public.yt_lite_risk_events(user_id,event_type,detail)
 VALUES(p_user,'device_multi_account',jsonb_build_object('account_count',v_count))
 ON CONFLICT DO NOTHING;
 END IF;
 RETURN jsonb_build_object('linked',true,'account_count',v_count,'hold_new_user_promo',v_count>=5);
END; $$;
REVOKE ALL ON FUNCTION public.yt_lite_register_device(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.yt_lite_register_device(uuid,text) TO service_role;
