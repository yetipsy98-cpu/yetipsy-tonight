-- Complete Moon reward lookup migration and remove the old kind-to-reward mapping.
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
   FROM public.rewards r JOIN public.yt_pos_reward_rules rr ON rr.reward_id=r.id AND rr.mode<>'disabled' WHERE r.id=h.reward_id AND r.active;
  IF h.expires_at<=clock_timestamp() OR h.code_status<>'available' OR h.issued_on>(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date OR h.valid_until<(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date
   OR reward_name IS NULL OR paid<r_min_drinks OR gross<r_min_spend OR (r_mode IN('product','series') AND h.product_id IS NULL) THEN bad:=bad+1;
  ELSIF r_mode='any_drink' THEN discount:=discount+CASE WHEN r_type='percent' THEN least(gross*r_value/100,gross) ELSE r_value END;END IF;
  rows:=rows||jsonb_build_array(jsonb_build_object('id',h.id,'source','moon','code',h.code,'state',CASE WHEN h.expires_at>clock_timestamp() AND h.code_status='available' THEN 'chosen' ELSE 'expired' END,'kind',h.kind,'reward_name',reward_name,'chosen_product_id',h.product_id,'chosen_product_name',h.drink_name,'discount_rm',CASE WHEN r_mode='any_drink' THEN CASE WHEN r_type='percent' THEN least(gross*r_value/100,gross) ELSE r_value END ELSE 0 END,'discount_type',CASE WHEN r_mode='any_drink' THEN r_type ELSE 'free' END,'valid',h.expires_at>clock_timestamp() AND h.code_status='available','expires_at',h.expires_at));
 END LOOP;
 balance:=greatest(0,(original->>'payable_rm')::numeric-discount);
 RETURN original||jsonb_build_object('moon_holds',rows,'holds',coalesce(original->'holds','[]'::jsonb)||rows,'reserved_discount_rm',(original->>'reserved_discount_rm')::numeric+discount,'payable_rm',balance,'unresolved_count',coalesce((original->>'unresolved_count')::int,0)+bad,'can_submit',coalesce((original->>'can_submit')::boolean,false) AND bad=0 AND (jsonb_array_length(rows)=0 OR (paid>=1 AND gross>=discount+0.01 AND balance>0)));
END;$function$
;
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
   FROM public.rewards r JOIN public.yt_pos_reward_rules rr ON rr.reward_id=r.id AND rr.mode<>'disabled' WHERE r.id=v.reward_id AND r.active;
  IF reward_name IS NULL THEN RAISE EXCEPTION 'moon_reward_not_bound';END IF;
  IF coalesce((private.yt_pos_order_minimum(p_order)->>'paid_drinks')::int,0)<r_min_drinks OR o.amount_rm<r_min_spend THEN RAISE EXCEPTION 'minimum_purchase_not_met';END IF;
  IF r_mode='any_drink' THEN IF r_type='free' THEN RAISE EXCEPTION 'moon_reward_not_bound';END IF;discount:=discount+CASE WHEN r_type='percent' THEN least(o.amount_rm*r_value/100,o.amount_rm) ELSE r_value END;item:=NULL;
  ELSIF r_mode IN('product','series') THEN
   IF r_type<>'free' OR h.product_id IS NULL THEN RAISE EXCEPTION 'moon_reward_not_bound';END IF;
   SELECT p.title INTO product_title FROM public.yt_shop_products p WHERE p.id=h.product_id AND p.active AND p.is_drink AND ((r_mode='product' AND p.id=r_product) OR (r_mode='series' AND p.series_id=r_series));
   IF product_title IS NULL THEN RAISE EXCEPTION 'reward_product_mismatch';END IF;
   INSERT INTO public.yt_member_order_items(order_id,item_name,quantity,unit_price_rm,is_drink_at_order) VALUES(p_order,product_title||' · Moon 赠品',1,0,false) RETURNING id INTO item;INSERT INTO public.yt_pos_item_units(order_item_id,unit_number) VALUES(item,1);
  ELSE RAISE EXCEPTION 'moon_reward_not_bound';
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
;
DROP FUNCTION IF EXISTS public.yt_moon_owner_add(text,text,date,date,boolean,text);
DROP FUNCTION IF EXISTS private.yt_moon_owner_add(text,text,date,date,boolean,text);
DROP FUNCTION IF EXISTS public.yt_moon_owner_bind_reward(text,uuid);
DROP FUNCTION IF EXISTS public.yt_moon_owner_unbind_reward(text);
DROP FUNCTION IF EXISTS public.yt_moon_owner_reward_bindings();
DROP FUNCTION IF EXISTS private.yt_moon_owner_bind_reward(text,uuid);
DROP FUNCTION IF EXISTS private.yt_moon_owner_unbind_reward(text);
DROP FUNCTION IF EXISTS private.yt_moon_owner_reward_bindings();
DROP TABLE IF EXISTS public.yt_moon_reward_bindings;
