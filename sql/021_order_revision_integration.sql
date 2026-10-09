CREATE OR REPLACE FUNCTION private.yt_pos_receipt(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_member_orders%rowtype;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found';end if;
 return jsonb_build_object(
  'id',v.id,'order_no',v.order_no,'table_label',v.table_label,
  'notes',v.notes,'status',v.status,'payment_status',v.payment_status,
  'payment_method',v.payment_method,'paid_at',v.paid_at,'paid_by',v.paid_by,
  'created_at',v.created_at,'updated_at',v.updated_at,
  'discount_total_rm',coalesce((select sum(u.reward_discount_rm)
    from public.yt_pos_item_units u
    join public.yt_member_order_items i on i.id=u.order_item_id where i.order_id=v.id and i.quantity>0 and not u.retired),0),
  'gross_total_rm',coalesce((select sum(i.quantity*i.unit_price_rm)
    from public.yt_member_order_items i where i.order_id=v.id and i.quantity>0),0),
  'amount_rm',v.amount_rm,
  'created_by',(select a.username from public.work_accounts a where a.auth_user_id=v.created_by),
  'items',coalesce((
    select jsonb_agg(jsonb_build_object(
     'item_name',i.item_name,'quantity',i.quantity,'unit_price_rm',i.unit_price_rm,
     'line_total_rm',i.quantity*i.unit_price_rm-
   coalesce((select sum(u.reward_discount_rm) from public.yt_pos_item_units u where u.order_item_id=i.id and not u.retired),0),
   'discount_rm',coalesce((select sum(u.reward_discount_rm) from public.yt_pos_item_units u where u.order_item_id=i.id and not u.retired),0)) order by i.item_name,i.id)
    from public.yt_member_order_items i where i.order_id=v.id and i.quantity>0),'[]'::jsonb),
  'document_type',case when v.payment_status='paid' then 'PAYMENT RECEIPT' else 'UNPAID BILL - NOT A RECEIPT' end,
  'disclaimer','Internal Yetipsy order record. Foodcourt payment method is recorded by cashier; not a tax invoice.'
 );
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_bill_v8(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b jsonb; q jsonb; paid boolean; items jsonb; discounts jsonb; amount numeric;
begin
 b=private.yt_pos_receipt(p_order);q=private.yt_pos_cart_summary(p_order);paid=b->>'payment_status' in ('paid','refunded');
 amount=case when paid then (b->>'amount_rm')::numeric else (q->>'payable_rm')::numeric end;
 select coalesce(jsonb_agg(jsonb_build_object('item_name',i.item_name,'quantity',i.quantity,'unit_price_rm',i.unit_price_rm,
  'discount_rm',d.final+d.held,'line_total_rm',i.quantity*i.unit_price_rm-d.final-d.held) order by i.item_name,i.id),'[]'::jsonb)
 into items from public.yt_member_order_items i
 cross join lateral(select
  coalesce((select sum(u.reward_discount_rm) from public.yt_pos_item_units u where u.order_item_id=i.id and not u.retired),0) final,
  case when paid then 0 else coalesce((select sum(h.discount_rm) from public.yt_pos_reward_holds h
    where h.order_item_id=i.id and h.order_id=p_order and h.state='ready' and h.expires_at>clock_timestamp()),0) end held) d
 where i.order_id=p_order and i.quantity>0;
 select coalesce(jsonb_agg(jsonb_build_object('reward_name',x.reward_name,'item_name',x.item_name,'discount_rm',x.discount_rm)),'[]'::jsonb)
 into discounts from (
  select r.name reward_name,i.item_name,sum(u.reward_discount_rm) discount_rm
  from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id
  join public.redemptions rd on rd.id=u.reward_redemption_id join public.user_rewards ur on ur.id=rd.user_reward_id
  join public.rewards r on r.id=ur.reward_id where i.order_id=p_order and not u.retired group by rd.id,r.name,i.id,i.item_name
  union all
  select r.name,i.item_name,h.discount_rm from public.yt_pos_reward_holds h join public.rewards r on r.id=h.reward_id
   left join public.yt_member_order_items i on i.id=h.order_item_id
   where h.order_id=p_order and not paid and h.state='ready' and h.expires_at>clock_timestamp()
 ) x;
 return b||jsonb_build_object('received_rm',private.yt_pos_received(p_order),'balance_rm',case when paid then amount-private.yt_pos_received(p_order) else amount end,'payment_entries',coalesce((select jsonb_agg(jsonb_build_object('method',method,'amount_rm',amount_rm,'kind',kind,'received_at',received_at) order by id) from public.yt_pos_payment_entries where order_id=p_order),'[]'::jsonb),'items',items,'discounts',discounts,'amount_rm',amount,
  'discount_total_rm',greatest(0,(b->>'gross_total_rm')::numeric-amount),
  'discount_pending',not paid and (q->>'reserved_discount_rm')::numeric>0,
  'unresolved_count',(q->>'unresolved_count')::integer,'minimum_met',q->'minimum_met');
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_orders(p_scope text DEFAULT 'active'::text, p_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_result jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_scope not in ('active','pending','paid','all','mine')
  or p_limit is null or p_limit<1 or p_limit>150 then raise exception 'invalid_filter';end if;
 if p_scope='pending' and not private.yt_pos_work_cashier()
  then raise exception 'cashier_only';end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc),'[]'::jsonb)
 into v_result from (
  select x.id,x.order_no,x.table_label,x.notes,x.status,x.payment_status,
   x.amount_rm,x.revision,x.settlement_due_since,private.yt_pos_received(x.id) as received_rm,case when x.payment_status in ('paid','refunded') then x.amount_rm-private.yt_pos_received(x.id) else x.amount_rm end as balance_rm,x.created_at,x.updated_at,x.created_by,
   wa.username as created_by_name,x.accepted_at,x.fulfilled_at,x.paid_at,x.payment_method,
   exists(select 1 from public.yt_pos_order_chits chit where chit.order_id=x.id and chit.status='queued') as has_chit,
   coalesce((select jsonb_agg(jsonb_build_object(
     'id',i.id,'product_id',i.product_id,'name',i.item_name,
     'quantity',i.quantity,'price_rm',i.unit_price_rm) order by i.item_name)
    from public.yt_member_order_items i where i.order_id=x.id and i.quantity>0),'[]'::jsonb) as items
  from public.yt_member_orders x
  left join public.work_accounts wa on wa.auth_user_id=x.created_by
  where x.source='future_pos'
  and (
   (p_scope='active' and x.status in ('pending','confirmed','fulfilled') and x.payment_status='unpaid')
    or (p_scope='pending' and x.status='pending')
    or (p_scope='paid' and x.payment_status in ('paid','refunded'))
    or (p_scope='all')
    or (p_scope='mine' and x.created_by=auth.uid())
  )
  order by x.created_at desc
  limit p_limit
 ) o;
 return v_result;
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_orders_day(p_scope text DEFAULT 'active'::text, p_day date DEFAULT NULL::date, p_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_result jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_scope not in ('active','pending','paid','all','mine')
  or p_limit is null or p_limit<1 or p_limit>150 then raise exception 'invalid_filter';end if;
 if p_scope='pending' and not private.yt_pos_work_cashier()
  then raise exception 'cashier_only';end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc),'[]'::jsonb)
 into v_result from (
  select x.id,x.order_no,x.table_label,x.notes,x.status,x.payment_status,
   x.amount_rm,x.revision,x.settlement_due_since,private.yt_pos_received(x.id) as received_rm,case when x.payment_status in ('paid','refunded') then x.amount_rm-private.yt_pos_received(x.id) else x.amount_rm end as balance_rm,x.created_at,x.updated_at,x.created_by,
   wa.username as created_by_name,x.accepted_at,x.fulfilled_at,x.paid_at,x.payment_method,
   exists(select 1 from public.yt_pos_order_chits chit where chit.order_id=x.id and chit.status='queued') as has_chit,
   coalesce((select jsonb_agg(jsonb_build_object(
     'id',i.id,'product_id',i.product_id,'name',i.item_name,
     'quantity',i.quantity,'price_rm',i.unit_price_rm) order by i.item_name)
    from public.yt_member_order_items i where i.order_id=x.id and i.quantity>0),'[]'::jsonb) as items
  from public.yt_member_orders x
  left join public.work_accounts wa on wa.auth_user_id=x.created_by
  where x.source='future_pos'
  and (
   (p_scope='active' and x.status in ('pending','confirmed','fulfilled') and x.payment_status='unpaid')
    or (p_scope='pending' and x.status='pending')
    or (p_scope='paid' and x.payment_status in ('paid','refunded') and x.paid_at>=private.yt_business_start(coalesce(p_day,private.yt_business_day(now()))) and x.paid_at<private.yt_business_start(coalesce(p_day,private.yt_business_day(now()))+1))
    or (p_scope='all')
    or (p_scope='mine' and x.created_by=auth.uid())
  )
  order by case when p_scope='paid' then x.paid_at else x.created_at end desc
  limit p_limit
 ) o;
 return v_result;
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_paid_units(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_member_orders%rowtype;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found';end if;
 if v.settlement_due_since is not null or v.cancel_after_refund then raise exception 'order_payment_adjustment_pending';end if;
 if v.payment_status<>'paid' then raise exception 'order_not_paid';end if;
 return jsonb_build_object('order_id',v.id,'order_no',v.order_no,
  'payment_method',v.payment_method,'paid_at',v.paid_at,'amount_rm',v.amount_rm,
  'units',coalesce((
   select jsonb_agg(jsonb_build_object(
    'order_item_id',i.id,'unit_number',u.unit_number,
    'product_name',i.item_name,'unit_price_rm',i.unit_price_rm,
    'series_name',s.name,'benefit_mode',s.benefit_mode,'game_plays',s.game_plays,
    'series_active',s.active,'can_split',s.can_split,
    'benefit_status',u.benefit_status,'assigned',u.assigned_customer_id is not null,
    'game_pass_id',u.game_pass_id,'reward_redeemed',u.reward_redemption_id IS NOT NULL,
    'pass_status',gp.status,'pass_expires_at',gp.expires_at
   ) order by i.item_name,i.id,u.unit_number)
   from public.yt_member_order_items i
   join public.yt_pos_item_units u on u.order_item_id=i.id
   left join public.yt_shop_products p on p.id=i.product_id
   left join public.yt_pos_series s on s.id=p.series_id
   left join public.game_passes gp on gp.id=u.game_pass_id
   where i.order_id=v.id and not u.retired and u.unit_number<=i.quantity
  ),'[]'::jsonb));
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_issue_unit_pass(p_order uuid, p_item uuid, p_unit integer, p_campaign uuid, p_token uuid, p_request uuid, p_minutes integer DEFAULT 10)
 RETURNS TABLE(pass_id uuid, expires_at timestamp with time zone, spend_amount_rm numeric, points_cap integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor uuid:=auth.uid();v_order public.yt_member_orders%rowtype;
 v_unit public.yt_pos_item_units%rowtype;v_item public.yt_member_order_items%rowtype;
 v_series public.yt_pos_series%rowtype;cfg public.yt_loyalty_config%rowtype;
 v_pass public.game_passes%rowtype;v_amount numeric;v_ref text;
 v_hash text;v_expires timestamptz;v_cap integer;
 v_allow_points boolean;v_new uuid;v_today date:=(clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_order is null or p_item is null or p_unit is null or p_token is null or p_request is null
  or p_campaign is null or p_minutes not between 1 and 60
 then raise exception 'invalid_benefit_request';end if;
 select * into v_order from public.yt_member_orders
  where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 if v_order.settlement_due_since is not null or v_order.cancel_after_refund then raise exception 'order_payment_adjustment_pending';end if;
 if v_order.status<>'fulfilled' or v_order.payment_status<>'paid' or v_order.paid_at is null
 then raise exception 'benefits_after_payment_only';end if;
 select * into v_item from public.yt_member_order_items
  where id=p_item and order_id=p_order;
 if not found then raise exception 'item_not_in_order';end if;
 select * into v_unit from public.yt_pos_item_units
  where order_item_id=p_item and unit_number=p_unit for update;
 if not found or v_unit.retired or p_unit>v_item.quantity then raise exception 'unit_not_in_order';end if;
 if v_unit.assigned_customer_id is not null or v_unit.reward_redemption_id is not null
   then raise exception 'unit_already_assigned';end if;
 select s.* into v_series from public.yt_shop_products p
 join public.yt_pos_series s on s.id=p.series_id
 where p.id=v_item.product_id;
 if not found or not v_series.active or v_series.benefit_mode in ('pending','none')
 then raise exception 'series_not_configured';end if;
 if v_series.benefit_mode not in ('games','choose') or v_series.game_plays<>1
 then raise exception 'series_rule_not_ready';end if;
 if not exists(select 1 from public.campaigns c where c.id=p_campaign and c.active
  and (c.starts_at is null or c.starts_at<=clock_timestamp())
  and (c.ends_at is null or c.ends_at>clock_timestamp()))
 then raise exception 'campaign_inactive';end if;
 select * into cfg from public.yt_loyalty_config where id=true;
 v_amount:=v_item.unit_price_rm;
 v_ref:='POS-'||replace(p_item::text,'-','')||'-'||p_unit::text;
 v_hash:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 v_allow_points:=v_series.benefit_mode='choose' and cfg.points_enabled
  and v_amount>=cfg.min_spend_rm;
 v_cap:=case when v_allow_points
  then least(1000000,floor(v_amount*least(coalesce(v_series.point_percent,cfg.max_points_percent),cfg.max_points_percent)*cfg.points_per_rm/100))::integer
  else 0 end;
 v_expires:=clock_timestamp()+make_interval(mins=>p_minutes);
 if v_unit.game_pass_id is not null then
  select * into v_pass from public.game_passes where id=v_unit.game_pass_id for update;
  if not found then raise exception 'benefit_reference_missing';end if;
  if v_pass.status='issued' and v_pass.claim_token_hash=v_hash and v_pass.expires_at>clock_timestamp()
  then return query select v_pass.id,v_pass.expires_at,v_pass.spend_amount_rm,coalesce(v_pass.points_cap_issued,0);return;end if;
  if v_pass.status<>'issued' or v_pass.expires_at>clock_timestamp()
  then raise exception 'unit_already_issued';end if;
  -- Expired/unclaimed: reuse same pass row, never create a second benefit.
  update public.game_passes set claim_token_hash=v_hash,expires_at=v_expires,
   request_id=p_request,issued_by=v_actor
  where id=v_pass.id;
  v_new:=v_pass.id;
 else
  insert into public.game_passes(
   campaign_id,issued_by,claim_token_hash,request_id,expires_at,
   spend_amount_rm,spend_ref,spend_day,
   points_enabled_issued,points_cap_issued,points_rate_issued,points_percent_issued
  )values(p_campaign,v_actor,v_hash,p_request,v_expires,
   v_amount,v_ref,v_today,v_allow_points,v_cap,cfg.points_per_rm,
   least(coalesce(v_series.point_percent,cfg.max_points_percent),cfg.max_points_percent))
  returning id into v_new;
  update public.yt_pos_item_units set game_pass_id=v_new,benefit_status='issued'
  where order_item_id=p_item and unit_number=p_unit;
 end if;
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note)
 values(p_order,v_actor,'benefit_issued','staff',v_ref);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(v_actor,'pos.unit_benefit_issued','pos_order',p_order,jsonb_build_object(
   'item_id',p_item,'unit',p_unit,'game_pass_id',v_new,
   'unit_price_rm',v_amount,'mode',v_series.benefit_mode));
 return query select v_new,v_expires,v_amount,v_cap;
end;$function$;

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
 IF o.settlement_due_since is not null or o.cancel_after_refund THEN RAISE EXCEPTION 'order_payment_adjustment_pending';END IF;
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
 WHERE i.order_id=p_order AND NOT u.retired AND u.unit_number<=i.quantity;
 SELECT count(*) INTO active_bundles FROM public.yt_pos_pass_bundles b
 WHERE b.order_id=p_order AND b.status='issued' AND b.expires_at>clock_timestamp();
 RETURN jsonb_build_object('order_id',p_order,'total_units',total,'eligible_units',eligible,
  'already_issued_units',issued,'unsupported_units',unsupported,'active_bundle_count',active_bundles,
  'active_bundle',(SELECT jsonb_build_object('id',b.id,'request_id',b.request_id,'expires_at',b.expires_at,'pass_count',(SELECT count(*) FROM public.yt_pos_pass_bundle_items x WHERE x.bundle_id=b.id)) FROM public.yt_pos_pass_bundles b WHERE b.order_id=p_order AND b.status='issued' AND b.expires_at>clock_timestamp() ORDER BY b.created_at DESC LIMIT 1),
  'can_issue',eligible>0 AND active_bundles=0,'one_qr_one_member',true,
  'note','整单 QR 只给一名会员；需要分给不同会员请逐杯生成。Tower 未配置为一杯一次的系列不参与。');
END;$function$;

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
  WHERE i.order_id=p_order AND NOT u.retired AND u.unit_number<=i.quantity AND u.reward_redemption_id IS NULL AND u.assigned_customer_id IS NULL
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
END;$function$;


CREATE OR REPLACE FUNCTION private.yt_pos_day_preview(p_day date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d date:=coalesce(p_day,private.yt_business_day(now()));s jsonb;c jsonb;pending jsonb;blockers bigint;n bigint;methods jsonb;fingerprint text;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if d<'2020-01-01' or d>private.yt_business_day(now()) then raise exception 'invalid_business_day';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.method),'[]') into methods from (
 select method,sum(amount_rm) net_rm,sum(greatest(amount_rm,0)) received_rm,-sum(least(amount_rm,0)) refunded_rm,count(distinct order_id) orders
 from public.yt_pos_payment_entries where business_day=d group by method)x;
 select jsonb_build_object('net_rm',coalesce(sum(amount_rm),0),'received_rm',coalesce(sum(greatest(amount_rm,0)),0),
 'refunded_rm',-coalesce(sum(least(amount_rm,0)),0),'cash_rm',coalesce(sum(amount_rm) filter(where method='cash'),0),
 'orders',count(distinct order_id),'entries',count(*),'last_entry',coalesce(max(id),0)) into s from public.yt_pos_payment_entries where business_day=d;
 select count(*),count(*) filter(where coalesce(settlement_due_since,created_at)<=now()-interval '72 hours') into n,blockers
 from public.yt_member_orders where source='future_pos' and ((status in ('pending','confirmed','fulfilled') and payment_status='unpaid') or (payment_status='paid' and settlement_due_since is not null));
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]') into pending from (
 select id,order_no,table_label,status,payment_status,case when payment_status='paid' then abs(amount_rm-private.yt_pos_received(id)) else amount_rm end as amount_rm,coalesce(settlement_due_since,created_at) as created_at,coalesce(settlement_due_since,created_at)<=now()-interval '72 hours' as overdue
 from public.yt_member_orders where source='future_pos' and ((status in ('pending','confirmed','fulfilled') and payment_status='unpaid') or (payment_status='paid' and settlement_due_since is not null))
 order by coalesce(settlement_due_since,created_at) limit 100)x;
 select to_jsonb(x) into c from public.yt_pos_day_closings x where business_day=d order by revision desc limit 1;
 fingerprint:=md5(s::text||methods::text||n::text||blockers::text||coalesce(c->>'id','')||coalesce(c->>'state',''));
 return jsonb_build_object('day',d,'context',private.yt_business_context(),'start_at',private.yt_business_start(d),'end_at',private.yt_business_start(d+1),
 'stats',s,'methods',methods,'pending',pending,'pending_count',n,'blocker_count',blockers,'closing',c,'fingerprint',fingerprint);
end $function$;

CREATE OR REPLACE FUNCTION private.yt_finish_game(p_session uuid)
 RETURNS TABLE(user_reward_id uuid, reward_name text, redeem_after timestamp with time zone, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor uuid:=auth.uid();v_session public.game_sessions%rowtype;
 v_reward public.rewards%rowtype;v_id uuid;v_after timestamptz;v_expires timestamptz;
begin
 if v_actor is null then raise exception 'not_authenticated'; end if;
 select * into v_session from public.game_sessions where id=p_session for update;
 if not found or v_session.customer_id<>v_actor then raise exception 'session_not_owned'; end if;
 if exists(select 1 from public.game_passes where id=v_session.pass_id and status='revoked') then raise exception 'pass_revoked';end if;
 if v_session.status='completed' then
   return query select w.id,r.name,w.redeem_after,w.expires_at
   from public.user_rewards w join public.rewards r on r.id=w.reward_id
   where w.session_id=p_session and w.customer_id=v_actor;
   return;
 end if;
 if v_session.status<>'started' or v_session.started_at>clock_timestamp()-interval '2 seconds'
 then raise exception 'game_not_finished'; end if;
 select * into v_reward from public.rewards where id=v_session.planned_reward_id;
 if not found then raise exception 'reward_missing'; end if;
 v_after:=case when v_reward.next_day_only then
 (((clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date+1)::timestamp at time zone 'Asia/Kuala_Lumpur')
 else clock_timestamp() end;
 v_expires:=clock_timestamp()+make_interval(days=>v_reward.validity_days);
 insert into public.user_rewards(customer_id,reward_id,session_id,redeem_after,expires_at)
 values(v_actor,v_reward.id,p_session,v_after,v_expires)
 on conflict(session_id) do nothing returning id into v_id;
 if v_id is null then select id into v_id from public.user_rewards
 where session_id=p_session and customer_id=v_actor;end if;
 if v_id is null then raise exception 'reward_not_issued'; end if;
 update public.game_sessions set status='completed',completed_at=clock_timestamp() where id=p_session;
 update public.game_passes set status='used',used_at=clock_timestamp() where id=v_session.pass_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id)
 values(v_actor,'game.finish','game_session',p_session);
 return query select v_id,v_reward.name,v_after,v_expires;
end;$function$;
