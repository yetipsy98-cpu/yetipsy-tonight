-- Whole-order and per-cup allocation share the same live series rules.
CREATE OR REPLACE FUNCTION private.yt_pos_bundle_quote(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE o public.yt_member_orders%rowtype;eligible int;total int;issued int;unsupported int;active_bundles int;
BEGIN
 IF NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 SELECT * INTO o FROM public.yt_member_orders WHERE id=p_order AND source='future_pos';
 IF NOT FOUND THEN RAISE EXCEPTION 'order_not_found';END IF;
 IF o.payment_status<>'paid' OR o.status<>'fulfilled' THEN RAISE EXCEPTION 'benefits_after_payment_only';END IF;
 SELECT count(*)::int,
 count(*) FILTER(WHERE (u.game_pass_id IS NULL OR (gp.status='issued' AND gp.expires_at<=clock_timestamp()))
 AND u.reward_redemption_id IS NULL AND u.assigned_customer_id IS NULL
 AND s.active AND s.benefit_mode IN('games','choose') AND s.game_plays=1)::int,
 count(*) FILTER (WHERE u.game_pass_id IS NOT NULL OR u.assigned_customer_id IS NOT NULL)::int,
 count(*) FILTER (WHERE s.id IS NULL OR NOT s.active OR s.benefit_mode NOT IN('games','choose') OR s.game_plays<>1)::int
 INTO total,eligible,issued,unsupported
 FROM public.yt_member_order_items i
 JOIN public.yt_pos_item_units u ON u.order_item_id=i.id
 LEFT JOIN public.yt_shop_products product ON product.id=i.product_id
 LEFT JOIN public.yt_pos_series s ON s.id=product.series_id
 LEFT JOIN public.game_passes gp ON gp.id=u.game_pass_id
 WHERE i.order_id=p_order;
 SELECT count(*) INTO active_bundles FROM public.yt_pos_pass_bundles b
 WHERE b.order_id=p_order AND b.status='issued' AND b.expires_at>clock_timestamp();
 RETURN jsonb_build_object('order_id',p_order,'total_units',total,'eligible_units',eligible,
  'already_issued_units',issued,'unsupported_units',unsupported,'active_bundle_count',active_bundles,
  'active_bundle',(SELECT jsonb_build_object('id',b.id,'request_id',b.request_id,'expires_at',b.expires_at,'pass_count',(SELECT count(*) FROM public.yt_pos_pass_bundle_items x WHERE x.bundle_id=b.id)) FROM public.yt_pos_pass_bundles b WHERE b.order_id=p_order AND b.status='issued' AND b.expires_at>clock_timestamp() ORDER BY b.created_at DESC LIMIT 1),
  'can_issue',eligible>0 AND active_bundles=0,'one_qr_one_member',true,
  'note','整单 QR 只给一名会员；需要分给不同会员请逐杯生成。Tower 未配置为一杯一次的系列不参与。');
END;$function$
;
CREATE OR REPLACE FUNCTION private.yt_pos_bundle_issue(p_order uuid, p_campaign uuid, p_token uuid, p_request uuid, p_minutes integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor uuid:=auth.uid();o public.yt_member_orders%rowtype;
 b public.yt_pos_pass_bundles%rowtype;v_row record;v_pass uuid;v_exp timestamptz;
 v_count int:=0;v_total int;
BEGIN
 IF NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 IF p_order IS NULL OR p_campaign IS NULL OR p_token IS NULL OR p_request IS NULL
  OR p_minutes NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION 'invalid_bundle_request';END IF;
 SELECT * INTO o FROM public.yt_member_orders WHERE id=p_order AND source='future_pos' FOR UPDATE;
 IF NOT FOUND OR o.payment_status<>'paid' OR o.status<>'fulfilled'
 THEN RAISE EXCEPTION 'benefits_after_payment_only';END IF;
 SELECT * INTO b FROM public.yt_pos_pass_bundles
 WHERE issued_by=actor AND request_id=p_request FOR UPDATE;
 IF FOUND THEN
   IF b.order_id<>p_order OR b.campaign_id<>p_campaign OR
    b.token_hash<>encode(sha256(convert_to(p_token::text,'UTF8')),'hex')
   THEN RAISE EXCEPTION 'bundle_request_conflict';END IF;
   RETURN jsonb_build_object('id',b.id,'expires_at',b.expires_at,'status',b.status,
    'pass_count',(SELECT count(*) FROM public.yt_pos_pass_bundle_items WHERE bundle_id=b.id),
    'idempotent',true);
 END IF;
 IF EXISTS(SELECT 1 FROM public.yt_pos_pass_bundles
 WHERE order_id=p_order AND status='issued' AND expires_at>clock_timestamp())
 THEN RAISE EXCEPTION 'active_order_bundle_exists';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=p_campaign AND c.active
 AND (c.starts_at IS NULL OR c.starts_at<=clock_timestamp())
 AND (c.ends_at IS NULL OR c.ends_at>clock_timestamp()))
 THEN RAISE EXCEPTION 'campaign_inactive';END IF;
 UPDATE public.yt_pos_pass_bundles SET status='expired'
 WHERE order_id=p_order AND status='issued' AND expires_at<=clock_timestamp();
 v_exp:=clock_timestamp()+make_interval(mins=>p_minutes);
 INSERT INTO public.yt_pos_pass_bundles(order_id,campaign_id,token_hash,issued_by,request_id,expires_at)
 VALUES(p_order,p_campaign,encode(sha256(convert_to(p_token::text,'UTF8')),'hex'),actor,p_request,v_exp)
 RETURNING * INTO b;
 FOR v_row IN
  SELECT i.id item_id,u.unit_number FROM public.yt_member_order_items i
   JOIN public.yt_pos_item_units u ON u.order_item_id=i.id
   LEFT JOIN public.yt_shop_products product ON product.id=i.product_id
   LEFT JOIN public.yt_pos_series s ON s.id=product.series_id
   LEFT JOIN public.game_passes gp ON gp.id=u.game_pass_id
  WHERE i.order_id=p_order AND u.reward_redemption_id IS NULL AND u.assigned_customer_id IS NULL
   AND s.active AND s.benefit_mode IN('games','choose') AND s.game_plays=1
   AND (u.game_pass_id IS NULL OR (gp.status='issued' AND gp.expires_at<=clock_timestamp()))
  ORDER BY i.id,u.unit_number
 LOOP
   SELECT pass_id,expires_at INTO v_pass,v_exp FROM private.yt_pos_issue_unit_pass(
    p_order,v_row.item_id,v_row.unit_number,p_campaign,gen_random_uuid(),gen_random_uuid(),p_minutes);
   INSERT INTO public.yt_pos_pass_bundle_items(bundle_id,pass_id,order_item_id,unit_number)
   VALUES(b.id,v_pass,v_row.item_id,v_row.unit_number);
   v_count:=v_count+1;
 END LOOP;
 IF v_count<1 THEN RAISE EXCEPTION 'no_eligible_bundle_units';END IF;
 SELECT count(*)::int INTO v_total FROM public.yt_pos_item_units u
 JOIN public.yt_member_order_items i ON i.id=u.order_item_id WHERE i.order_id=p_order;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 VALUES(actor,'pos.bundle_issued','pos_order',p_order,jsonb_build_object(
 'bundle_id',b.id,'passes',v_count,'units_total',v_total));
 RETURN jsonb_build_object('id',b.id,'expires_at',b.expires_at,'pass_count',v_count,
 'excluded_count',v_total-v_count,'status','issued','idempotent',false);
END;$function$
;

