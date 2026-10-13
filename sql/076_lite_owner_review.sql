-- Owner-only risk review and release (observation mode).
CREATE TABLE IF NOT EXISTS public.yt_lite_owner_reviews (
 user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 released_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 released_by uuid NOT NULL REFERENCES auth.users(id),
 reason text NOT NULL DEFAULT 'Owner reviewed'
);
ALTER TABLE public.yt_lite_owner_reviews ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.yt_lite_owner_reviews FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.yt_lite_owner_review(p_user uuid,p_release boolean,p_reason text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only'; END IF;
 IF p_user IS NULL OR NOT EXISTS (SELECT 1 FROM public.pin_accounts WHERE auth_user_id=p_user)
 THEN RAISE EXCEPTION 'customer_not_found'; END IF;
 IF p_release THEN
  INSERT INTO public.yt_lite_owner_reviews(user_id,released_by,reason)
  VALUES(p_user,auth.uid(),left(coalesce(nullif(btrim(p_reason),''),'Owner reviewed'),200))
  ON CONFLICT(user_id) DO UPDATE SET released_at=clock_timestamp(),
    released_by=excluded.released_by,reason=excluded.reason;
  INSERT INTO public.yt_lite_risk_events(user_id,event_type,detail)
  VALUES(p_user,'manual_release',jsonb_build_object('reviewed_by',auth.uid()));
 ELSE
  DELETE FROM public.yt_lite_owner_reviews WHERE user_id=p_user;
 END IF;
 RETURN jsonb_build_object('ok',true,'released',p_release);
END; $$;
REVOKE ALL ON FUNCTION private.yt_lite_owner_review(uuid,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_lite_owner_review(uuid,boolean,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.yt_lite_owner_review(p_user uuid,p_release boolean,p_reason text DEFAULT '')
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path TO ''
AS $$ SELECT private.yt_lite_owner_review(p_user,p_release,p_reason); $$;
REVOKE ALL ON FUNCTION public.yt_lite_owner_review(uuid,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.yt_lite_owner_review(uuid,boolean,text) TO authenticated;

CREATE OR REPLACE FUNCTION private.yt_lite_owner_review_queue()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $$
DECLARE v jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.account_count DESC,q.last_seen DESC),'[]'::jsonb)
 INTO v FROM (
  SELECT l.user_id,count(DISTINCT d.user_id) AS account_count,
    max(l.last_seen) AS last_seen,(r.user_id IS NOT NULL) AS released
  FROM public.yt_lite_device_links l
  JOIN public.yt_lite_device_links d ON d.device_digest=l.device_digest
  LEFT JOIN public.yt_lite_owner_reviews r ON r.user_id=l.user_id
  GROUP BY l.user_id,r.user_id
  HAVING count(DISTINCT d.user_id)>=3
  ORDER BY account_count DESC,last_seen DESC LIMIT 100
 ) q;
 RETURN jsonb_build_object('items',v);
END; $$;
REVOKE ALL ON FUNCTION private.yt_lite_owner_review_queue() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_lite_owner_review_queue() TO authenticated;
CREATE OR REPLACE FUNCTION public.yt_lite_owner_review_queue()
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path TO ''
AS $$ SELECT private.yt_lite_owner_review_queue(); $$;
REVOKE ALL ON FUNCTION public.yt_lite_owner_review_queue() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.yt_lite_owner_review_queue() TO authenticated;
