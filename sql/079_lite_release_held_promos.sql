-- Releasing a held promotion issues its original configured reward exactly once.
CREATE OR REPLACE FUNCTION private.yt_lite_owner_review(p_user uuid,p_release boolean,p_reason text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $$
DECLARE v record; v_issued integer:=0;
BEGIN
 IF auth.uid() IS NULL OR NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only'; END IF;
 IF p_user IS NULL OR NOT EXISTS(SELECT 1 FROM public.pin_accounts WHERE auth_user_id=p_user)
 THEN RAISE EXCEPTION 'customer_not_found'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('lite-release:'||p_user::text,0));
 IF p_release THEN
  INSERT INTO public.yt_lite_owner_reviews(user_id,released_by,reason)
  VALUES(p_user,auth.uid(),left(coalesce(nullif(btrim(p_reason),''),'Owner reviewed'),200))
  ON CONFLICT(user_id) DO UPDATE SET released_at=clock_timestamp(),
   released_by=excluded.released_by,reason=excluded.reason;
  FOR v IN SELECT * FROM public.yt_lite_held_promos
   WHERE customer_id=p_user AND released_at IS NULL ORDER BY created_at FOR UPDATE
  LOOP
   IF private.yt_award_promo(v.customer_id,v.kind,v.source_customer_id,v.reward_id) THEN
    v_issued:=v_issued+1;
   END IF;
   UPDATE public.yt_lite_held_promos SET released_at=clock_timestamp()
   WHERE customer_id=v.customer_id AND kind=v.kind AND source_customer_id=v.source_customer_id;
  END LOOP;
  INSERT INTO public.yt_lite_risk_events(user_id,event_type,detail)
  VALUES(p_user,'manual_release',jsonb_build_object('reviewed_by',auth.uid(),'issued',v_issued));
 ELSE
  DELETE FROM public.yt_lite_owner_reviews WHERE user_id=p_user;
 END IF;
 RETURN jsonb_build_object('ok',true,'released',p_release,'issued',v_issued);
END; $$;
REVOKE ALL ON FUNCTION private.yt_lite_owner_review(uuid,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_lite_owner_review(uuid,boolean,text) TO authenticated;
