-- Add a direct reward reference to Moon codes and keep owner RPCs compatible during rollout.
ALTER TABLE public.yt_moon_guest_codes
 ADD COLUMN IF NOT EXISTS reward_id uuid REFERENCES public.rewards(id) ON DELETE RESTRICT;

CREATE OR REPLACE FUNCTION private.yt_moon_owner_add(
 p_code text,p_reward uuid,p_issued date,p_until date,p_used boolean DEFAULT false,p_note text DEFAULT ''
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $function$
DECLARE c text;v uuid;
BEGIN
 IF NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only';END IF;
 IF p_reward IS NULL OR p_issued IS NULL OR p_until IS NULL OR p_until<p_issued
  OR p_until>p_issued+365 OR length(coalesce(p_note,''))>300
  OR NOT EXISTS(SELECT 1 FROM public.rewards r JOIN public.yt_pos_reward_rules rr ON rr.reward_id=r.id
    WHERE r.id=p_reward AND r.active AND rr.mode IN('product','series','any_drink'))
 THEN RAISE EXCEPTION 'moon_invalid_details';END IF;
 c:=private.yt_moon_norm(p_code);
 INSERT INTO public.yt_moon_guest_codes(code,kind,reward_id,issued_on,valid_until,legacy_used,status,notes,created_by,redeemed_at)
 VALUES(c,'R0',p_reward,p_issued,p_until,coalesce(p_used,false),
  CASE WHEN p_used THEN 'redeemed' ELSE 'available' END,coalesce(p_note,''),auth.uid(),
  CASE WHEN p_used THEN clock_timestamp() ELSE NULL END)
 ON CONFLICT(code) DO NOTHING RETURNING id INTO v;
 IF v IS NULL THEN RAISE EXCEPTION 'moon_duplicate_code';END IF;
 RETURN jsonb_build_object('id',v,'code',c,'reward_id',p_reward);
END;$function$;
CREATE OR REPLACE FUNCTION public.yt_moon_owner_add(
 p_code text,p_reward uuid,p_issued date,p_until date,p_used boolean DEFAULT false,p_note text DEFAULT ''
) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $function$
 SELECT private.yt_moon_owner_add(p_code,p_reward,p_issued,p_until,p_used,p_note)
$function$;

CREATE OR REPLACE FUNCTION private.yt_moon_owner_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $function$
DECLARE v jsonb;
BEGIN
 IF NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',q.id,'code',q.code,'kind',q.kind,
  'reward_id',q.reward_id,'reward_name',r.name,'issued',q.issued_on,'until',q.valid_until,'status',q.status,
  'order',coalesce(q.reserved_order_id,q.redeemed_order_id)) ORDER BY q.created_at DESC),'[]'::jsonb)
 INTO v FROM (SELECT * FROM public.yt_moon_guest_codes ORDER BY created_at DESC LIMIT 500) q
 LEFT JOIN public.rewards r ON r.id=q.reward_id;
 RETURN v;
END;$function$;
CREATE OR REPLACE FUNCTION public.yt_moon_owner_list()
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $function$
 SELECT private.yt_moon_owner_list()
$function$;

CREATE OR REPLACE FUNCTION private.yt_moon_preorder_scan(p_draft uuid, p_code text, p_cart jsonb, p_drink text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor uuid:=auth.uid();v_code text;v public.yt_moon_guest_codes%rowtype;hold_id uuid;v_paid int;v_gross numeric;
 v_now timestamptz:=clock_timestamp();attempts int;reward_id uuid;reward_name text;
 r_mode text;r_product uuid;r_series uuid;r_type text;r_value numeric;r_min_drinks int;r_min_spend numeric;
 product_id uuid;product_name text;products jsonb;
BEGIN
 IF NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 IF p_draft IS NULL OR p_cart IS NULL THEN RAISE EXCEPTION 'invalid_draft';END IF;
 SELECT gross_rm,paid_drinks INTO v_gross,v_paid FROM private.yt_pos_draft_price(p_cart);
 IF v_paid<1 OR v_gross<=0 THEN RAISE EXCEPTION 'minimum_one_paid_drink';END IF;
 INSERT INTO private.yt_redeem_code_attempts AS a(operator_id,window_started_at,attempts) VALUES(actor,v_now,1)
 ON CONFLICT(operator_id) DO UPDATE SET attempts=CASE WHEN a.window_started_at<=v_now-interval '1 minute' THEN 1 ELSE least(a.attempts+1,26) END,
 window_started_at=CASE WHEN a.window_started_at<=v_now-interval '1 minute' THEN v_now ELSE a.window_started_at END RETURNING a.attempts INTO attempts;
 IF attempts>25 THEN RETURN jsonb_build_object('error_code','short_code_rate_limited');END IF;
 BEGIN v_code:=private.yt_moon_norm(p_code);EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error_code','moon_invalid_code');END;
 PERFORM pg_advisory_xact_lock(hashtextextended('moon:'||v_code,0));
 SELECT * INTO v FROM public.yt_moon_guest_codes WHERE code=v_code FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('error_code','moon_code_not_found');END IF;
 IF v.status='redeemed' THEN RETURN jsonb_build_object('error_code','moon_already_redeemed');END IF;
 IF v.status<>'available' THEN RETURN jsonb_build_object('error_code','moon_reserved_elsewhere');END IF;
 IF v.valid_until<(v_now AT TIME ZONE 'Asia/Kuala_Lumpur')::date THEN RETURN jsonb_build_object('error_code','moon_expired');END IF;
 IF v.issued_on>(v_now AT TIME ZONE 'Asia/Kuala_Lumpur')::date THEN RETURN jsonb_build_object('error_code','moon_not_started');END IF;
 SELECT r.id,r.name,rr.mode,rr.product_id,rr.series_id,rr.discount_type,rr.discount_value,rr.min_paid_drinks,rr.min_spend_rm
 INTO reward_id,reward_name,r_mode,r_product,r_series,r_type,r_value,r_min_drinks,r_min_spend
 FROM public.rewards r JOIN public.yt_pos_reward_rules rr ON rr.reward_id=r.id AND rr.mode<>'disabled'
 WHERE r.id=v.reward_id AND r.active;
 IF reward_id IS NULL THEN RETURN jsonb_build_object('error_code','moon_reward_not_bound');END IF;
 IF v_paid<r_min_drinks OR v_gross<r_min_spend THEN RETURN jsonb_build_object('error_code','minimum_purchase_not_met');END IF;
 UPDATE public.yt_moon_preorder_holds SET state='released' WHERE code_id=v.id AND state='held' AND expires_at<=v_now;
 SELECT id,product_id,drink_name INTO hold_id,product_id,product_name FROM public.yt_moon_preorder_holds WHERE code_id=v.id AND state='held' AND operator_id=actor AND draft_id=p_draft FOR UPDATE;
 IF hold_id IS NOT NULL THEN RETURN jsonb_build_object('id',hold_id,'source','moon','code',v_code,'kind',v.kind,'reward_name',reward_name,'chosen_product_id',product_id,'chosen_product_name',product_name,'discount_rm',CASE WHEN r_mode='any_drink' THEN CASE WHEN r_type='percent' THEN least(v_gross*r_value/100,v_gross) ELSE r_value END ELSE 0 END,'idempotent',true);END IF;
 IF EXISTS(SELECT 1 FROM public.yt_moon_preorder_holds WHERE code_id=v.id AND state='held') THEN RETURN jsonb_build_object('error_code','moon_reserved_elsewhere');END IF;
 IF r_mode='any_drink' THEN
  IF r_type='free' THEN RETURN jsonb_build_object('error_code','moon_reward_not_bound');END IF;
 ELSIF r_mode IN('product','series') THEN
  IF r_type<>'free' THEN RETURN jsonb_build_object('error_code','moon_reward_not_bound');END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('product_id',p.id,'name',p.title,'price_rm',p.price_rm) ORDER BY p.sort_order,p.title),'[]'::jsonb) INTO products FROM public.yt_shop_products p
   WHERE p.active AND p.is_drink AND ((r_mode='product' AND p.id=r_product) OR (r_mode='series' AND p.series_id=r_series));
  IF p_drink IS NULL THEN RETURN jsonb_build_object('source','moon','requires_product',true,'id',v.id,'code',v_code,'kind',v.kind,'reward_name',reward_name,'discount_type','free','products',products);END IF;
  BEGIN product_id:=p_drink::uuid;EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error_code','reward_product_mismatch');END;
  SELECT p.title INTO product_name FROM public.yt_shop_products p WHERE p.id=product_id AND p.active AND p.is_drink AND
   ((r_mode='product' AND p.id=r_product) OR (r_mode='series' AND p.series_id=r_series));
  IF product_name IS NULL THEN RETURN jsonb_build_object('error_code','reward_product_mismatch');END IF;
 ELSE RETURN jsonb_build_object('error_code','moon_reward_not_bound');
 END IF;
 INSERT INTO public.yt_moon_preorder_holds(draft_id,operator_id,code_id,drink_name,product_id) VALUES(p_draft,actor,v.id,product_name,product_id) RETURNING id INTO hold_id;
 RETURN jsonb_build_object('id',hold_id,'source','moon','code',v_code,'kind',v.kind,'reward_name',reward_name,'chosen_product_id',product_id,'chosen_product_name',product_name,'discount_rm',CASE WHEN r_mode='any_drink' THEN CASE WHEN r_type='percent' THEN least(v_gross*r_value/100,v_gross) ELSE r_value END ELSE 0 END,'idempotent',false);
END;$function$
;
REVOKE ALL ON FUNCTION private.yt_moon_owner_add(text,uuid,date,date,boolean,text),
 public.yt_moon_owner_add(text,uuid,date,date,boolean,text),
 private.yt_moon_owner_list(),public.yt_moon_owner_list() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_moon_owner_add(text,uuid,date,date,boolean,text),
 public.yt_moon_owner_add(text,uuid,date,date,boolean,text),
 private.yt_moon_owner_list(),public.yt_moon_owner_list() TO authenticated;
