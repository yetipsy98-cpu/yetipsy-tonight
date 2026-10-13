CREATE OR REPLACE FUNCTION private.yt_moon_owner_add(p_code text, p_reward uuid, p_issued date, p_until date, p_used boolean DEFAULT false, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c text;v uuid;existing_reward uuid;
BEGIN
 IF NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only';END IF;
 IF p_reward IS NULL OR p_issued IS NULL OR p_until IS NULL OR p_until<p_issued
  OR p_until>p_issued+365 OR length(coalesce(p_note,''))>300
  OR NOT EXISTS(SELECT 1 FROM public.rewards r JOIN public.yt_pos_reward_rules rr ON rr.reward_id=r.id
    WHERE r.id=p_reward AND r.active AND rr.mode IN('product','series','any_drink'))
 THEN RAISE EXCEPTION 'moon_invalid_details';END IF;
 c:=private.yt_moon_norm(p_code);
 SELECT id,reward_id INTO v,existing_reward FROM public.yt_moon_guest_codes WHERE code=c FOR UPDATE;
 IF FOUND THEN
  IF existing_reward IS NOT NULL THEN RAISE EXCEPTION 'moon_duplicate_code';END IF;
  UPDATE public.yt_moon_guest_codes SET reward_id=p_reward WHERE id=v;
  RETURN jsonb_build_object('id',v,'code',c,'reward_id',p_reward,'updated_existing',true);
 END IF;
 INSERT INTO public.yt_moon_guest_codes(code,kind,reward_id,issued_on,valid_until,legacy_used,status,notes,created_by,redeemed_at)
 VALUES(c,'R0',p_reward,p_issued,p_until,coalesce(p_used,false),
  CASE WHEN p_used THEN 'redeemed' ELSE 'available' END,coalesce(p_note,''),auth.uid(),
  CASE WHEN p_used THEN clock_timestamp() ELSE NULL END)
 ON CONFLICT(code) DO NOTHING RETURNING id INTO v;
 IF v IS NULL THEN RAISE EXCEPTION 'moon_duplicate_code';END IF;
 RETURN jsonb_build_object('id',v,'code',c,'reward_id',p_reward,'updated_existing',false);
END;$function$
;