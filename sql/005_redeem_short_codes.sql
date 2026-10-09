-- Applied through Supabase MCP: redeem_short_code_v5.
-- Requires the deployed V5 preorder cart functions. No existing reward rules changed.
CREATE TABLE private.yt_redeem_short_codes (
 redeem_token_id uuid PRIMARY KEY REFERENCES public.redeem_tokens(id) ON DELETE CASCADE,
 code_hash text NOT NULL UNIQUE CHECK(length(code_hash)=64),
 expires_at timestamptz NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE private.yt_redeem_short_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.yt_redeem_short_codes FROM PUBLIC,anon,authenticated;
CREATE TABLE private.yt_redeem_code_attempts (
 operator_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 window_started_at timestamptz NOT NULL,
 attempts integer NOT NULL CHECK(attempts BETWEEN 1 AND 21)
);
ALTER TABLE private.yt_redeem_code_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.yt_redeem_code_attempts FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.yt_make_redeem_v5(p_award uuid,p_token uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_exp timestamptz;v_token uuid;v_code text;v_bytes bytea;i int;j int;
 alphabet constant text:='23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated';END IF;
 v_exp:=private.yt_make_redeem(p_award,p_token);
 SELECT id INTO STRICT v_token FROM public.redeem_tokens
 WHERE token_hash=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 FOR j IN 1..5 LOOP
  v_code:='';v_bytes:=extensions.gen_random_bytes(8);
  FOR i IN 0..7 LOOP v_code:=v_code||substr(alphabet,1+(get_byte(v_bytes,i)%32),1);END LOOP;
  BEGIN
   INSERT INTO private.yt_redeem_short_codes(redeem_token_id,code_hash,expires_at)
   VALUES(v_token,encode(sha256(convert_to(v_code,'UTF8')),'hex'),v_exp);
   RETURN jsonb_build_object('expires_at',v_exp,'short_code',v_code,
    'display_code',substr(v_code,1,4)||'-'||substr(v_code,5,4));
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
 END LOOP;
 RAISE EXCEPTION 'short_code_generation_failed';
END;$$;
CREATE FUNCTION public.yt_make_redeem_v5(p_award uuid,p_token uuid)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.yt_make_redeem_v5(p_award,p_token);
$$;
REVOKE ALL ON FUNCTION private.yt_make_redeem_v5(uuid,uuid),public.yt_make_redeem_v5(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_make_redeem_v5(uuid,uuid),public.yt_make_redeem_v5(uuid,uuid) TO authenticated;

-- QR and manual input converge before wallet and draft locking.
CREATE OR REPLACE FUNCTION private.yt_pos_preorder_scan_by_hash(p_draft uuid, p_hash text, p_request uuid, p_cart jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor uuid:=auth.uid(); tok public.redeem_tokens%rowtype;w public.user_rewards%rowtype;
m public.yt_pos_reward_rules%rowtype;h public.yt_pos_preorder_holds%rowtype;
v_gross numeric;v_drinks int;v_count int;v_options jsonb;v_until timestamptz;
BEGIN
 IF NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 IF p_draft IS NULL OR p_hash IS NULL OR p_request IS NULL THEN RAISE EXCEPTION 'invalid_request';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('yt-pos-draft:'||actor::text||':'||p_draft::text,0));
 IF EXISTS(SELECT 1 FROM private.yt_pos_draft_submissions WHERE operator_id=actor AND draft_id=p_draft) THEN RAISE EXCEPTION 'draft_already_submitted';END IF;
 IF (SELECT count(*) FROM public.yt_pos_preorder_holds WHERE operator_id=actor AND draft_id=p_draft AND state IN('pending','chosen'))>=20 THEN RAISE EXCEPTION 'too_many_cart_rewards';END IF;
 SELECT gross_rm,paid_drinks,valid_units INTO v_gross,v_drinks,v_count FROM private.yt_pos_draft_price(p_cart);
 IF v_drinks<1 THEN RAISE EXCEPTION 'minimum_one_paid_drink';END IF;
 SELECT * INTO tok FROM public.redeem_tokens
 WHERE token_hash=p_hash FOR UPDATE;
 IF NOT FOUND OR tok.consumed_at IS NOT NULL OR tok.expires_at<=clock_timestamp()
 THEN RAISE EXCEPTION 'token_invalid_rescan_wallet';END IF;
 SELECT * INTO w FROM public.user_rewards WHERE id=tok.user_reward_id FOR UPDATE;
 IF NOT FOUND OR w.status<>'available' OR w.redeem_after>clock_timestamp()
 OR w.expires_at<=clock_timestamp() OR NOT private.yt_redeem_hours(w.reward_id)
 THEN RAISE EXCEPTION 'reward_unavailable';END IF;
 PERFORM private.yt_pos_assert_reward_bound(w.reward_id);
 SELECT * INTO m FROM public.yt_pos_reward_rules WHERE reward_id=w.reward_id;
 IF NOT FOUND OR m.mode NOT IN('product','series','any_drink')
 THEN RAISE EXCEPTION 'reward_pos_binding_required';END IF;
 IF m.mode='any_drink' AND m.discount_type='free' THEN RAISE EXCEPTION 'any_drink_discount_only';END IF;
 IF v_drinks<m.min_paid_drinks OR v_gross<m.min_spend_rm THEN RAISE EXCEPTION 'minimum_purchase_not_met';END IF;
 IF EXISTS(SELECT 1 FROM public.yt_pos_reward_holds x WHERE x.user_reward_id=w.id
 AND x.state IN('reserved','ready'))
 THEN RAISE EXCEPTION 'reward_reserved_by_another_order';END IF;
 SELECT * INTO h FROM public.yt_pos_preorder_holds
 WHERE user_reward_id=w.id AND operator_id=actor AND draft_id=p_draft AND state IN('pending','chosen') FOR UPDATE;
 IF FOUND THEN
  IF h.expires_at>clock_timestamp() AND (h.operator_id<>actor OR h.draft_id<>p_draft)
  THEN RAISE EXCEPTION 'reward_reserved_by_other_cart';END IF;
  IF h.expires_at<=clock_timestamp() THEN
   UPDATE public.yt_pos_preorder_holds SET state='expired',updated_at=clock_timestamp() WHERE id=h.id;
  ELSE
   RETURN jsonb_build_object('id',h.id,'reward_name',(SELECT name FROM public.rewards WHERE id=w.reward_id),
    'mode',h.rule_mode,'discount_type',h.discount_type,'discount_value',h.discount_value,
    'state',h.state,'expires_at',h.expires_at,'idempotent',true,'products',coalesce((SELECT jsonb_agg(jsonb_build_object('product_id',p.id,'name',p.title,'price_rm',p.price_rm)) FROM public.yt_shop_products p WHERE p.active AND ((m.mode='product' AND p.id=m.product_id) OR (m.mode='series' AND p.series_id=m.series_id) OR (m.mode='any_drink' AND p.is_drink))),'[]'::jsonb));
  END IF;
 END IF;
 v_until:=least(w.expires_at,clock_timestamp()+interval '120 minutes');
 INSERT INTO public.yt_pos_preorder_holds(
 draft_id,operator_id,user_reward_id,reward_id,request_id,rule_mode,
 discount_type,discount_value,min_paid_drinks,min_spend_rm,expires_at)
 VALUES(p_draft,actor,w.id,w.reward_id,p_request,m.mode,m.discount_type,m.discount_value,
 m.min_paid_drinks,m.min_spend_rm,v_until) RETURNING * INTO h;
 SELECT coalesce(jsonb_agg(jsonb_build_object('product_id',p.id,'name',p.title,'price_rm',p.price_rm)
 ORDER BY p.title),'[]'::jsonb) INTO v_options
 FROM public.yt_shop_products p WHERE p.active
 AND ((m.mode='product' AND p.id=m.product_id)
 OR (m.mode='series' AND p.series_id=m.series_id)
 OR (m.mode='any_drink' AND p.is_drink));
 RETURN jsonb_build_object('id',h.id,'reward_name',(SELECT name FROM public.rewards WHERE id=w.reward_id),
 'mode',h.rule_mode,'discount_type',h.discount_type,'discount_value',h.discount_value,
 'min_paid_drinks',h.min_paid_drinks,'min_spend_rm',h.min_spend_rm,
 'state',h.state,'expires_at',h.expires_at,'products',v_options,'idempotent',false);
END;$function$
;
REVOKE ALL ON FUNCTION private.yt_pos_preorder_scan_by_hash(uuid,text,uuid,jsonb) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION private.yt_pos_preorder_scan(p_draft uuid,p_token uuid,p_request uuid,p_cart jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 IF p_token IS NULL THEN RAISE EXCEPTION 'invalid_request';END IF;
 RETURN private.yt_pos_preorder_scan_by_hash(p_draft,
  encode(sha256(convert_to(p_token::text,'UTF8')),'hex'),p_request,p_cart);
END;$$;

CREATE FUNCTION private.yt_pos_preorder_scan_code(p_draft uuid,p_code text,p_request uuid,p_cart jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor uuid:=auth.uid();v_now timestamptz:=clock_timestamp();v_attempts int;
 v_code text;v_hash text;
BEGIN
 IF actor IS NULL OR NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 INSERT INTO private.yt_redeem_code_attempts AS a(operator_id,window_started_at,attempts)
 VALUES(actor,v_now,1) ON CONFLICT(operator_id) DO UPDATE SET
  attempts=CASE WHEN a.window_started_at<=v_now-interval '1 minute' THEN 1 ELSE least(a.attempts+1,21) END,
  window_started_at=CASE WHEN a.window_started_at<=v_now-interval '1 minute' THEN v_now ELSE a.window_started_at END
 RETURNING attempts INTO v_attempts;
 -- Return business failures so unsuccessful guesses still commit the attempt counter.
 IF v_attempts>20 THEN RETURN jsonb_build_object('error_code','short_code_rate_limited');END IF;
 v_code:=upper(regexp_replace(coalesce(p_code,''),'[[:space:]-]','','g'));
 IF length(v_code)<>8 OR v_code!~'^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$'
 THEN RETURN jsonb_build_object('error_code','short_code_invalid_or_expired');END IF;
 SELECT t.token_hash INTO v_hash FROM private.yt_redeem_short_codes c
 JOIN public.redeem_tokens t ON t.id=c.redeem_token_id
 WHERE c.code_hash=encode(sha256(convert_to(v_code,'UTF8')),'hex')
 AND c.expires_at>clock_timestamp() AND t.expires_at>clock_timestamp() AND t.consumed_at IS NULL;
 IF NOT FOUND THEN RETURN jsonb_build_object('error_code','short_code_invalid_or_expired');END IF;
 BEGIN
  RETURN private.yt_pos_preorder_scan_by_hash(p_draft,v_hash,p_request,p_cart);
 EXCEPTION WHEN raise_exception THEN RETURN jsonb_build_object('error_code',SQLERRM);
 END;
END;$$;
CREATE FUNCTION public.yt_pos_preorder_scan_code(p_draft uuid,p_code text,p_request uuid,p_cart jsonb)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.yt_pos_preorder_scan_code(p_draft,p_code,p_request,p_cart);
$$;
REVOKE ALL ON FUNCTION private.yt_pos_preorder_scan_code(uuid,text,uuid,jsonb),public.yt_pos_preorder_scan_code(uuid,text,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_pos_preorder_scan_code(uuid,text,uuid,jsonb),public.yt_pos_preorder_scan_code(uuid,text,uuid,jsonb) TO authenticated;
NOTIFY pgrst,'reload schema';
