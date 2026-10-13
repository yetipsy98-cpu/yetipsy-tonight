-- Yetipsy Lite Protection V1: additive, observation-only migration.
-- No existing reward, checkout, registration or redemption function is replaced.
CREATE TABLE IF NOT EXISTS public.yt_lite_device_links (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_digest text NOT NULL CHECK (device_digest ~ '^[0-9a-f]{64}$'),
  first_seen timestamptz NOT NULL DEFAULT now(),
  last_seen timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, device_digest)
);
CREATE INDEX IF NOT EXISTS yt_lite_device_links_digest_idx
  ON public.yt_lite_device_links (device_digest, first_seen DESC);
CREATE TABLE IF NOT EXISTS public.yt_lite_risk_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  event_type text NOT NULL CHECK (event_type IN ('device_multi_account','registration_burst','duplicate_reward_attempt','manual_release')),
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS yt_lite_risk_events_created_idx ON public.yt_lite_risk_events(created_at DESC);
ALTER TABLE public.yt_lite_device_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.yt_lite_risk_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.yt_lite_device_links FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.yt_lite_risk_events FROM PUBLIC, anon, authenticated;
-- Tables remain server-only; the authenticated RPC performs guarded inserts.
-- Client-generated digests are weak signals, not trusted device attestation.
-- A server-side keyed digest is required before enabling punitive enforcement.
CREATE OR REPLACE FUNCTION private.yt_owner_lite_risk_summary()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $$
DECLARE v_result jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only'; END IF;
 SELECT jsonb_build_object(
  'linked_devices', (SELECT count(*) FROM public.yt_lite_device_links),
  'multi_account_devices', (SELECT count(*) FROM (
     SELECT device_digest FROM public.yt_lite_device_links
     GROUP BY device_digest HAVING count(DISTINCT user_id) >= 3
  ) d),
  'recent_events', (SELECT count(*) FROM public.yt_lite_risk_events WHERE created_at >= now() - interval '24 hours')
 ) INTO v_result;
 RETURN v_result;
END; $$;
REVOKE ALL ON FUNCTION private.yt_owner_lite_risk_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.yt_owner_lite_risk_summary() TO authenticated;
CREATE OR REPLACE FUNCTION public.yt_owner_lite_risk_summary()
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path TO ''
AS 'SELECT private.yt_owner_lite_risk_summary();';
REVOKE ALL ON FUNCTION public.yt_owner_lite_risk_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.yt_owner_lite_risk_summary() TO authenticated;
