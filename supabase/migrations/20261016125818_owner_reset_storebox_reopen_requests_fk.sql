-- Store Box reset must truncate every referencing child together with its parent.
-- A new reopen-request FK was added after the reset function was first defined.
DO $patch$
DECLARE
  v_definition text;
  v_anchor text := 'truncate table public.yt_store_box_events,public.yt_store_box_requests,public.yt_store_box_claims,public.yt_store_boxes restart identity;';
  v_replacement text := 'truncate table public.yt_store_box_events,public.yt_store_box_requests,public.yt_store_box_reopen_requests,public.yt_store_box_claims,public.yt_store_boxes restart identity;';
BEGIN
  SELECT pg_get_functiondef(
    'private.yt_owner_reset_v9(uuid,text,text,uuid,uuid,bigint[],text[])'::regprocedure
  ) INTO v_definition;

  IF position(v_replacement IN v_definition) > 0 THEN
    RETURN;
  END IF;

  IF position(v_anchor IN v_definition) = 0 THEN
    RAISE EXCEPTION 'owner_reset_storebox_reopen_requests_patch_anchor_missing';
  END IF;

  EXECUTE replace(v_definition, v_anchor, v_replacement);
END
$patch$;
