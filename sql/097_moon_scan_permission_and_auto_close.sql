-- Keep Moon-code auto-detection inside a staff-checked database function.
-- The Moon guest-code table intentionally has no direct authenticated grants.
CREATE OR REPLACE FUNCTION public.yt_pos_preorder_scan_auto(
 p_draft uuid,
 p_code text,
 p_request uuid,
 p_cart jsonb,
 p_product uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $function$
DECLARE normalized text;
BEGIN
 IF NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 BEGIN
  normalized:=private.yt_moon_norm(p_code);
 EXCEPTION WHEN OTHERS THEN
  normalized:=NULL;
 END;
 IF normalized IS NOT NULL AND EXISTS(
  SELECT 1 FROM public.yt_moon_guest_codes WHERE code=normalized
 ) THEN
  RETURN private.yt_moon_preorder_scan(p_draft,normalized,p_cart,p_product::text);
 END IF;
 RETURN private.yt_pos_preorder_scan_code(p_draft,p_code,p_request,p_cart);
END;
$function$;

REVOKE ALL ON FUNCTION public.yt_pos_preorder_scan_auto(uuid,text,uuid,jsonb,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.yt_pos_preorder_scan_auto(uuid,text,uuid,jsonb,uuid) TO authenticated;
