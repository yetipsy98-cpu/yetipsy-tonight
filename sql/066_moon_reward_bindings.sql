-- Explicit Moon reward kind -> existing POS reward association.
CREATE TABLE IF NOT EXISTS public.yt_moon_reward_bindings(
 kind text PRIMARY KEY CHECK(kind IN('R5','R4','R3','R0')),
 reward_id uuid NOT NULL UNIQUE REFERENCES public.rewards(id) ON DELETE CASCADE,
 updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.yt_moon_reward_bindings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.yt_moon_reward_bindings FROM PUBLIC,anon,authenticated;
INSERT INTO public.yt_moon_reward_bindings(kind,reward_id)
SELECT x.kind,r.id FROM (VALUES('R0','Yetipsy Lucky Box · RM5 Voucher'),('R3','RAINBOW SHOT X1'),
 ('R4','Yetipsy Lucky Box · 指定微醺特调'),('R5','Yetipsy Lucky Box · 指定经典鸡尾酒')) x(kind,reward_name)
JOIN public.rewards r ON r.name=x.reward_name ON CONFLICT(kind) DO NOTHING;
CREATE OR REPLACE FUNCTION private.yt_moon_owner_bind_reward(p_kind text, p_reward uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE selected_mode text;selected_type text;
BEGIN
 IF NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only';END IF;
 IF p_kind NOT IN('R5','R4','R3','R0') OR p_reward IS NULL THEN RAISE EXCEPTION 'moon_reward_not_bound';END IF;
 SELECT rr.mode,rr.discount_type INTO selected_mode,selected_type FROM public.rewards r
 JOIN public.yt_pos_reward_rules rr ON rr.reward_id=r.id WHERE r.id=p_reward AND r.active;
 IF NOT FOUND OR selected_mode='disabled' OR
  (p_kind='R0' AND NOT(selected_mode='any_drink' AND selected_type IN('fixed','percent'))) OR
  (p_kind<>'R0' AND NOT(selected_mode IN('product','series') AND selected_type='free'))
 THEN RAISE EXCEPTION 'moon_reward_not_bound';END IF;
 INSERT INTO public.yt_moon_reward_bindings(kind,reward_id,updated_by,updated_at)
 VALUES(p_kind,p_reward,auth.uid(),clock_timestamp())
 ON CONFLICT(kind) DO UPDATE SET reward_id=excluded.reward_id,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 RETURN jsonb_build_object('ok',true,'kind',p_kind,'reward_id',p_reward);
END;$function$


CREATE OR REPLACE FUNCTION private.yt_moon_owner_reward_bindings()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v jsonb;
BEGIN
 IF NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('kind',b.kind,'reward_id',b.reward_id,'reward_name',r.name) ORDER BY b.kind),'[]'::jsonb)
 INTO v FROM public.yt_moon_reward_bindings b JOIN public.rewards r ON r.id=b.reward_id;
 RETURN v;
END;$function$


CREATE OR REPLACE FUNCTION private.yt_moon_owner_unbind_reward(p_kind text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 IF NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only';END IF;
 DELETE FROM public.yt_moon_reward_bindings WHERE kind=p_kind;
 RETURN jsonb_build_object('ok',true,'kind',p_kind);
END;$function$


CREATE OR REPLACE FUNCTION private.yt_moon_preorder_attach(p_draft uuid, p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE o public.yt_member_orders%rowtype;h record;v public.yt_moon_guest_codes%rowtype;item uuid;count_attached int:=0;discount numeric:=0;total_discount numeric;paid_drinks int;reward_name text;
 r_mode text;r_type text;r_value numeric;r_min_drinks int;r_min_spend numeric;r_product uuid;r_series uuid;product_title text;
BEGIN
 IF NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('yt-pos-draft:'||auth.uid()::text||':'||p_draft::text,0));
 SELECT * INTO o FROM public.yt_member_orders WHERE id=p_order AND source='future_pos' FOR UPDATE;
 IF NOT FOUND OR o.created_by<>auth.uid() OR o.payment_status<>'unpaid' OR o.status NOT IN('pending','confirmed') THEN RAISE EXCEPTION 'order_not_available_for_preorder';END IF;
 IF EXISTS(SELECT 1 FROM public.yt_moon_preorder_holds WHERE draft_id=p_draft AND operator_id=auth.uid() AND state='attached' AND attached_order_id<>p_order) THEN RAISE EXCEPTION 'request_conflict';END IF;
 SELECT count(*) INTO count_attached FROM public.yt_moon_preorder_holds WHERE draft_id=p_draft AND operator_id=auth.uid() AND state='attached' AND attached_order_id=p_order;
 FOR h IN SELECT ph.id,ph.code_id,ph.drink_name,ph.product_id FROM public.yt_moon_preorder_holds ph WHERE ph.draft_id=p_draft AND ph.operator_id=auth.uid() AND ph.state='held' ORDER BY ph.id FOR UPDATE LOOP
  SELECT * INTO v FROM public.yt_moon_guest_codes WHERE id=h.code_id FOR UPDATE;
  IF NOT FOUND OR v.status<>'available' THEN RAISE EXCEPTION 'moon_reserved_elsewhere';END IF;
  IF v.issued_on>(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date THEN RAISE EXCEPTION 'moon_not_started';END IF;
  IF v.valid_until<(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date THEN RAISE EXCEPTION 'moon_expired';END IF;
  IF NOT EXISTS(SELECT 1 FROM public.yt_moon_preorder_holds WHERE id=h.id AND expires_at>clock_timestamp()) THEN RAISE EXCEPTION 'moon_expired';END IF;
  SELECT r.name,rr.mode,rr.discount_type,rr.discount_value,rr.min_paid_drinks,rr.min_spend_rm,rr.product_id,rr.series_id
   INTO reward_name,r_mode,r_type,r_value,r_min_drinks,r_min_spend,r_product,r_series
   FROM public.yt_moon_reward_bindings b JOIN public.rewards r ON r.id=b.reward_id AND r.active JOIN public.yt_pos_reward_rules rr ON rr.reward_id=r.id AND rr.mode<>'disabled' WHERE b.kind=v.kind;
  IF reward_name IS NULL THEN RAISE EXCEPTION 'moon_reward_not_bound';END IF;
  IF coalesce((private.yt_pos_order_minimum(p_order)->>'paid_drinks')::int,0)<r_min_drinks OR o.amount_rm<r_min_spend THEN RAISE EXCEPTION 'minimum_purchase_not_met';END IF;
  IF v.kind='R0' THEN IF r_mode<>'any_drink' OR r_type='free' THEN RAISE EXCEPTION 'moon_reward_not_bound';END IF;discount:=discount+r_value;item:=NULL;
  ELSE
   IF r_type<>'free' OR h.product_id IS NULL OR r_mode NOT IN('product','series') THEN RAISE EXCEPTION 'moon_reward_not_bound';END IF;
   SELECT p.title INTO product_title FROM public.yt_shop_products p WHERE p.id=h.product_id AND p.active AND p.is_drink AND ((r_mode='product' AND p.id=r_product) OR (r_mode='series' AND p.series_id=r_series));
   IF product_title IS NULL THEN RAISE EXCEPTION 'reward_product_mismatch';END IF;
   INSERT INTO public.yt_member_order_items(order_id,item_name,quantity,unit_price_rm,is_drink_at_order) VALUES(p_order,product_title||' · Moon 赠品',1,0,false) RETURNING id INTO item;INSERT INTO public.yt_pos_item_units(order_item_id,unit_number) VALUES(item,1);
  END IF;
  UPDATE public.yt_moon_guest_codes SET status='reserved',reserved_order_id=p_order,reserved_item_id=item WHERE id=v.id;UPDATE public.yt_moon_preorder_holds SET state='attached',attached_order_id=p_order WHERE id=h.id;count_attached:=count_attached+1;
 END LOOP;
 IF count_attached>0 THEN
  SELECT coalesce(sum(discount_rm),0) INTO total_discount FROM public.yt_pos_reward_holds WHERE order_id=p_order AND state='ready';
  IF discount>0 AND o.amount_rm<=discount+total_discount THEN RAISE EXCEPTION 'moon_minimum_payable';END IF;
  SELECT (private.yt_pos_order_minimum(p_order)->>'paid_drinks')::int INTO paid_drinks;IF paid_drinks<1 THEN RAISE EXCEPTION 'minimum_one_paid_drink';END IF;
  IF o.status='confirmed' THEN INSERT INTO public.yt_pos_order_chits(order_id) VALUES(p_order) ON CONFLICT(order_id) DO UPDATE SET status='queued',issued_at=clock_timestamp(),printed_at=NULL,printed_by=NULL;END IF;
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,metadata) VALUES(auth.uid(),'moon.preorder_attached','pos_order',p_order,jsonb_build_object('codes',count_attached,'r0_discount_rm',discount));
 END IF;
 RETURN jsonb_build_object('attached',count_attached,'discount_rm',discount,'idempotent',discount=0 AND count_attached=0);
END;$function$


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
 SELECT b.reward_id,r.name,rr.mode,rr.product_id,rr.series_id,rr.discount_type,rr.discount_value,rr.min_paid_drinks,rr.min_spend_rm
 INTO reward_id,reward_name,r_mode,r_product,r_series,r_type,r_value,r_min_drinks,r_min_spend
 FROM public.yt_moon_reward_bindings b JOIN public.rewards r ON r.id=b.reward_id AND r.active
 JOIN public.yt_pos_reward_rules rr ON rr.reward_id=r.id AND rr.mode<>'disabled' WHERE b.kind=v.kind;
 IF reward_id IS NULL THEN RETURN jsonb_build_object('error_code','moon_reward_not_bound');END IF;
 IF v_paid<r_min_drinks OR v_gross<r_min_spend THEN RETURN jsonb_build_object('error_code','minimum_purchase_not_met');END IF;
 UPDATE public.yt_moon_preorder_holds SET state='released' WHERE code_id=v.id AND state='held' AND expires_at<=v_now;
 SELECT id,product_id,drink_name INTO hold_id,product_id,product_name FROM public.yt_moon_preorder_holds WHERE code_id=v.id AND state='held' AND operator_id=actor AND draft_id=p_draft FOR UPDATE;
 IF hold_id IS NOT NULL THEN RETURN jsonb_build_object('id',hold_id,'source','moon','code',v_code,'kind',v.kind,'reward_name',reward_name,'chosen_product_id',product_id,'chosen_product_name',product_name,'discount_rm',CASE WHEN v.kind='R0' THEN r_value ELSE 0 END,'idempotent',true);END IF;
 IF EXISTS(SELECT 1 FROM public.yt_moon_preorder_holds WHERE code_id=v.id AND state='held') THEN RETURN jsonb_build_object('error_code','moon_reserved_elsewhere');END IF;
 IF v.kind='R0' THEN
  IF r_mode<>'any_drink' OR r_type='free' THEN RETURN jsonb_build_object('error_code','moon_reward_not_bound');END IF;
 ELSE
  IF r_type<>'free' OR r_mode NOT IN('product','series') THEN RETURN jsonb_build_object('error_code','moon_reward_not_bound');END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('product_id',p.id,'name',p.title,'price_rm',p.price_rm) ORDER BY p.sort_order,p.title),'[]'::jsonb) INTO products FROM public.yt_shop_products p
   WHERE p.active AND p.is_drink AND ((r_mode='product' AND p.id=r_product) OR (r_mode='series' AND p.series_id=r_series));
  IF p_drink IS NULL THEN RETURN jsonb_build_object('source','moon','requires_product',true,'id',v.id,'code',v_code,'kind',v.kind,'reward_name',reward_name,'discount_type','free','products',products);END IF;
  BEGIN product_id:=p_drink::uuid;EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error_code','reward_product_mismatch');END;
  SELECT p.title INTO product_name FROM public.yt_shop_products p WHERE p.id=product_id AND p.active AND p.is_drink AND
   ((r_mode='product' AND p.id=r_product) OR (r_mode='series' AND p.series_id=r_series));
  IF product_name IS NULL THEN RETURN jsonb_build_object('error_code','reward_product_mismatch');END IF;
 END IF;
 INSERT INTO public.yt_moon_preorder_holds(draft_id,operator_id,code_id,drink_name,product_id) VALUES(p_draft,actor,v.id,product_name,product_id) RETURNING id INTO hold_id;
 RETURN jsonb_build_object('id',hold_id,'source','moon','code',v_code,'kind',v.kind,'reward_name',reward_name,'chosen_product_id',product_id,'chosen_product_name',product_name,'discount_rm',CASE WHEN v.kind='R0' THEN r_value ELSE 0 END,'idempotent',false);
END;$function$


CREATE OR REPLACE FUNCTION private.yt_moon_preorder_summary(p_draft uuid, p_cart jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE original jsonb;rows jsonb:='[]'::jsonb;discount numeric:=0;bad int:=0;h record;balance numeric;gross numeric;paid int;reward_name text;
 r_mode text;r_type text;r_value numeric;r_min_drinks int;r_min_spend numeric;
BEGIN
 IF NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 original:=private.yt_pos_preorder_summary(p_draft,p_cart);gross:=coalesce((original->>'purchased_gross_rm')::numeric,0);paid:=coalesce((original->>'paid_drinks')::integer,0);
 FOR h IN SELECT ph.*,c.code,c.kind,c.issued_on,c.valid_until,c.status code_status FROM public.yt_moon_preorder_holds ph JOIN public.yt_moon_guest_codes c ON c.id=ph.code_id
 WHERE ph.operator_id=auth.uid() AND ph.draft_id=p_draft AND ph.state='held' ORDER BY ph.created_at,ph.id LOOP
  reward_name:=NULL;r_mode:=NULL;
  SELECT r.name,rr.mode,rr.discount_type,rr.discount_value,rr.min_paid_drinks,rr.min_spend_rm
   INTO reward_name,r_mode,r_type,r_value,r_min_drinks,r_min_spend
   FROM public.yt_moon_reward_bindings b JOIN public.rewards r ON r.id=b.reward_id AND r.active JOIN public.yt_pos_reward_rules rr ON rr.reward_id=r.id AND rr.mode<>'disabled' WHERE b.kind=h.kind;
  IF h.expires_at<=clock_timestamp() OR h.code_status<>'available' OR h.issued_on>(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date OR h.valid_until<(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date
   OR reward_name IS NULL OR paid<r_min_drinks OR gross<r_min_spend OR (h.kind IN('R3','R4','R5') AND h.product_id IS NULL) THEN bad:=bad+1;
  ELSIF h.kind='R0' THEN discount:=discount+r_value;END IF;
  rows:=rows||jsonb_build_array(jsonb_build_object('id',h.id,'source','moon','code',h.code,'state',CASE WHEN h.expires_at>clock_timestamp() AND h.code_status='available' THEN 'chosen' ELSE 'expired' END,'kind',h.kind,'reward_name',reward_name,'chosen_product_id',h.product_id,'chosen_product_name',h.drink_name,'discount_rm',CASE WHEN h.kind='R0' THEN r_value ELSE 0 END,'discount_type',CASE WHEN h.kind='R0' THEN r_type ELSE 'free' END,'valid',h.expires_at>clock_timestamp() AND h.code_status='available','expires_at',h.expires_at));
 END LOOP;
 balance:=greatest(0,(original->>'payable_rm')::numeric-discount);
 RETURN original||jsonb_build_object('moon_holds',rows,'holds',coalesce(original->'holds','[]'::jsonb)||rows,'reserved_discount_rm',(original->>'reserved_discount_rm')::numeric+discount,'payable_rm',balance,'unresolved_count',coalesce((original->>'unresolved_count')::int,0)+bad,'can_submit',coalesce((original->>'can_submit')::boolean,false) AND bad=0 AND (jsonb_array_length(rows)=0 OR (paid>=1 AND gross>=discount+0.01 AND balance>0)));
END;$function$


CREATE OR REPLACE FUNCTION public.yt_moon_owner_bind_reward(p_kind text, p_reward uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ SELECT private.yt_moon_owner_bind_reward(p_kind,p_reward); $function$


CREATE OR REPLACE FUNCTION public.yt_moon_owner_reward_bindings()
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ SELECT private.yt_moon_owner_reward_bindings(); $function$


CREATE OR REPLACE FUNCTION public.yt_moon_owner_unbind_reward(p_kind text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ SELECT private.yt_moon_owner_unbind_reward(p_kind); $function$

REVOKE ALL ON FUNCTION private.yt_moon_owner_reward_bindings(),public.yt_moon_owner_reward_bindings(),
 private.yt_moon_owner_bind_reward(text,uuid),public.yt_moon_owner_bind_reward(text,uuid),
 private.yt_moon_owner_unbind_reward(text),public.yt_moon_owner_unbind_reward(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.yt_moon_owner_reward_bindings(),public.yt_moon_owner_bind_reward(text,uuid),
 public.yt_moon_owner_unbind_reward(text) TO authenticated;
