-- Owner creation and POS binding succeed together, or neither is stored.
CREATE UNIQUE INDEX yt_reward_create_bound_request_idx ON public.audit_logs(actor_id,(metadata->>'request_id')) WHERE action='reward.create_bound';
CREATE FUNCTION private.yt_owner_create_bound_reward_v6(p_reward jsonb,p_binding jsonb,p_request uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor uuid:=auth.uid();v_id uuid;v_hash text;v_old_hash text;
 v_mode text;v_product uuid;v_series uuid;v_type text;v_value numeric;v_min int;v_spend numeric;
 v_template uuid;v_rule public.yt_pos_reward_rules%rowtype;
BEGIN
 IF actor IS NULL OR NOT private.yt_has_role('owner') OR NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'owner_only';END IF;
 IF p_request IS NULL OR jsonb_typeof(p_reward) IS DISTINCT FROM 'object' OR jsonb_typeof(p_binding) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'invalid_reward';END IF;
 v_hash:=encode(sha256(convert_to(p_reward::text||p_binding::text,'UTF8')),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(actor::text||':bound-reward:'||p_request::text,0));
 SELECT entity_id,metadata->>'payload_hash' INTO v_id,v_old_hash FROM public.audit_logs
 WHERE actor_id=actor AND action='reward.create_bound' AND metadata->>'request_id'=p_request::text LIMIT 1;
 IF FOUND THEN
  IF v_old_hash IS DISTINCT FROM v_hash THEN RAISE EXCEPTION 'request_conflict';END IF;
  RETURN v_id;
 END IF;
 v_template:=nullif(p_binding->>'template_reward_id','')::uuid;
 IF v_template IS NOT NULL THEN
  SELECT rule.* INTO v_rule FROM public.yt_pos_reward_rules rule JOIN public.rewards r ON r.id=rule.reward_id
  WHERE rule.reward_id=v_template AND r.active AND rule.mode IN('product','series','any_drink') FOR SHARE OF rule,r;
  IF NOT FOUND THEN RAISE EXCEPTION 'reward_not_pos_bound';END IF;
  v_mode:=v_rule.mode;v_product:=v_rule.product_id;v_series:=v_rule.series_id;
  v_type:=v_rule.discount_type;v_value:=v_rule.discount_value;v_min:=v_rule.min_paid_drinks;v_spend:=v_rule.min_spend_rm;
 ELSE
  v_mode:=p_binding->>'mode';v_product:=nullif(p_binding->>'product_id','')::uuid;v_series:=nullif(p_binding->>'series_id','')::uuid;
  v_type:=p_binding->>'discount_type';v_value:=(p_binding->>'discount_value')::numeric;
  v_min:=(p_binding->>'min_paid_drinks')::int;v_spend:=(p_binding->>'min_spend_rm')::numeric;
 END IF;
 IF v_mode IS NULL OR v_mode NOT IN('product','series','any_drink') OR v_type IS NULL OR v_type NOT IN('free','fixed','percent')
 OR v_value IS NULL OR v_min IS NULL OR v_spend IS NULL
 OR (v_mode='product' AND (v_product IS NULL OR v_series IS NOT NULL))
 OR (v_mode='series' AND (v_series IS NULL OR v_product IS NOT NULL)) THEN RAISE EXCEPTION 'reward_not_pos_bound';END IF;
 IF (v_type='free' AND v_value<>0) OR (v_type='fixed' AND v_value NOT BETWEEN .01 AND 5000)
 OR (v_type='percent' AND v_value NOT BETWEEN .01 AND 100) THEN RAISE EXCEPTION 'invalid_reward_discount';END IF;
 v_id:=private.yt_create_reward_v11(p_reward->>'name',p_reward->>'description',p_reward->>'category',
 (p_reward->>'validity_days')::int,(p_reward->>'next_day_only')::boolean,
 nullif(p_reward->>'use_from','')::timestamptz,nullif(p_reward->>'use_until','')::timestamptz,
 nullif(p_reward->>'daily_from','')::time,nullif(p_reward->>'daily_until','')::time);
 PERFORM private.yt_pos_owner_save_reward_v43(v_id,v_mode,v_product,v_series,v_type,v_value,v_min,v_spend);
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 VALUES(actor,'reward.create_bound','reward',v_id,jsonb_build_object('request_id',p_request,'payload_hash',v_hash,'template_reward_id',v_template));
 RETURN v_id;
END;$$;
CREATE FUNCTION public.yt_owner_create_bound_reward_v6(p_reward jsonb,p_binding jsonb,p_request uuid)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.yt_owner_create_bound_reward_v6(p_reward,p_binding,p_request);$$;
REVOKE ALL ON FUNCTION private.yt_owner_create_bound_reward_v6(jsonb,jsonb,uuid),public.yt_owner_create_bound_reward_v6(jsonb,jsonb,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_owner_create_bound_reward_v6(jsonb,jsonb,uuid),public.yt_owner_create_bound_reward_v6(jsonb,jsonb,uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
