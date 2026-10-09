-- GamePass lifecycle: QR 2 minutes, claimed 72 hours, current-business-day issuance.
alter table public.campaigns add column is_default boolean not null default false;
create unique index yt_campaign_one_default_idx on public.campaigns(is_default) where is_default;
alter table public.game_sessions add column progress jsonb not null default '{}'::jsonb;

CREATE OR REPLACE FUNCTION private.yt_issue_pass(p_campaign uuid, p_request uuid, p_token uuid, p_minutes integer)
 RETURNS TABLE(pass_id uuid, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor uuid:=auth.uid(); v_hash text; v_id uuid; v_expires timestamptz;
begin
 perform pg_advisory_xact_lock(781943081);
 if not private.yt_has_role('staff') then raise exception 'staff_only'; end if;
 if p_request is null or p_token is null or p_campaign is null then raise exception 'missing_argument'; end if;
 if p_minutes < 1 or p_minutes > 60 then raise exception 'invalid_minutes'; end if;
 if not exists(select 1 from public.campaigns c where c.id=p_campaign and c.active
   and (c.starts_at is null or c.starts_at<=now()) and (c.ends_at is null or c.ends_at>now()))
 then raise exception 'campaign_inactive'; end if;
 v_hash:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 insert into public.game_passes(campaign_id,issued_by,claim_token_hash,request_id,expires_at)
 values(p_campaign,v_actor,v_hash,p_request,clock_timestamp()+interval '2 minutes')
 on conflict do nothing returning id,game_passes.expires_at into v_id,v_expires;
 if v_id is null then
  select p.id,p.expires_at into v_id,v_expires from public.game_passes p
  where p.request_id=p_request and p.issued_by=v_actor and p.campaign_id=p_campaign and p.claim_token_hash=v_hash;
 end if;
 if v_id is null then raise exception 'request_conflict'; end if;
 return query select v_id,v_expires;
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_issue_unit_pass(p_order uuid, p_item uuid, p_unit integer, p_campaign uuid, p_token uuid, p_request uuid, p_minutes integer DEFAULT 2)
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
 v_allow_points boolean;v_new uuid;v_today date:=private.yt_business_day(clock_timestamp());
begin
 perform pg_advisory_xact_lock(781943081);
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_order is null or p_item is null or p_unit is null or p_token is null or p_request is null
  or p_campaign is null or p_minutes not between 1 and 60
 then raise exception 'invalid_benefit_request';end if;
 select * into v_order from public.yt_member_orders
  where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 if private.yt_business_day(v_order.created_at)<>private.yt_business_day(clock_timestamp()) then raise exception 'benefits_current_day_only';end if;
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
 v_expires:=clock_timestamp()+interval '2 minutes';
 if v_unit.game_pass_id is not null then
  select * into v_pass from public.game_passes where id=v_unit.game_pass_id for update;
  if not found then raise exception 'benefit_reference_missing';end if;
  if v_pass.request_id=p_request and (v_pass.claim_token_hash is distinct from v_hash or v_pass.campaign_id<>p_campaign) then raise exception 'request_conflict';end if;
  if v_pass.status='issued' and v_pass.claim_token_hash=v_hash and v_pass.expires_at>clock_timestamp()
  then return query select v_pass.id,v_pass.expires_at,v_pass.spend_amount_rm,coalesce(v_pass.points_cap_issued,0);return;end if;
  if v_pass.customer_id is not null or v_pass.claimed_at is not null or exists(select 1 from public.game_sessions gs where gs.pass_id=v_pass.id) or v_pass.status not in ('issued','expired') or v_pass.expires_at>clock_timestamp()
  then raise exception 'unit_already_issued';end if;
  -- Expired/unclaimed: reuse same pass row, never create a second benefit.
  update public.game_passes set status='issued',campaign_id=p_campaign,claim_token_hash=v_hash,expires_at=v_expires,spend_day=private.yt_business_day(clock_timestamp()),spend_amount_rm=v_amount,points_enabled_issued=v_allow_points,points_cap_issued=v_cap,points_rate_issued=cfg.points_per_rm,points_percent_issued=least(coalesce(v_series.point_percent,cfg.max_points_percent),cfg.max_points_percent),
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
 IF private.yt_business_day(o.created_at)<>private.yt_business_day(clock_timestamp()) THEN RAISE EXCEPTION 'benefits_current_day_only';END IF;
 IF o.settlement_due_since is not null or o.cancel_after_refund THEN RAISE EXCEPTION 'order_payment_adjustment_pending';END IF;
 IF o.payment_status<>'paid' OR o.status<>'fulfilled' THEN RAISE EXCEPTION 'benefits_after_payment_only';END IF;
 SELECT count(*)::int,
 count(*) FILTER(WHERE (u.game_pass_id IS NULL OR (gp.status IN('issued','expired') AND gp.customer_id IS NULL AND gp.claimed_at IS NULL AND gp.expires_at<=clock_timestamp()))
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

CREATE OR REPLACE FUNCTION private.yt_pos_bundle_issue(p_order uuid, p_campaign uuid, p_token uuid, p_request uuid, p_minutes integer DEFAULT 2)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor uuid:=auth.uid();o public.yt_member_orders%rowtype;
 b public.yt_pos_pass_bundles%rowtype;v_row record;v_pass uuid;v_exp timestamptz;
 v_count int:=0;v_total int;
BEGIN
 PERFORM pg_advisory_xact_lock(781943081);
 IF NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 IF p_order IS NULL OR p_campaign IS NULL OR p_token IS NULL OR p_request IS NULL
  OR p_minutes NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION 'invalid_bundle_request';END IF;
 SELECT * INTO o FROM public.yt_member_orders WHERE id=p_order AND source='future_pos' FOR UPDATE;
 IF NOT FOUND OR o.payment_status<>'paid' OR o.status<>'fulfilled'
 THEN RAISE EXCEPTION 'benefits_after_payment_only';END IF;
 IF private.yt_business_day(o.created_at)<>private.yt_business_day(clock_timestamp()) THEN RAISE EXCEPTION 'benefits_current_day_only';END IF;
 IF o.settlement_due_since IS NOT NULL OR o.cancel_after_refund THEN RAISE EXCEPTION 'order_payment_adjustment_pending';END IF;
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
 v_exp:=clock_timestamp()+interval '2 minutes';
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
   AND (u.game_pass_id IS NULL OR (gp.status IN('issued','expired') AND gp.customer_id IS NULL AND gp.claimed_at IS NULL AND gp.expires_at<=clock_timestamp()))
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
 IF private.yt_business_day(v.created_at)<>private.yt_business_day(clock_timestamp()) THEN RAISE EXCEPTION 'benefits_current_day_only';END IF;
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
   where i.order_id=v.id and not u.retired and u.unit_number<=i.quantity and u.assigned_customer_id is null and u.reward_redemption_id is null and (gp.id is null or (gp.customer_id is null and gp.claimed_at is null and gp.status in ('issued','expired')))
  ),'[]'::jsonb));
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_bundle_claim(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor uuid:=auth.uid();b public.yt_pos_pass_bundles%rowtype;
 p record;v_count int:=0;v_ids uuid[]:=array[]::uuid[];
BEGIN
 PERFORM pg_advisory_xact_lock(781943081);
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.pin_accounts a WHERE a.auth_user_id=actor)
 OR EXISTS(SELECT 1 FROM public.work_accounts a WHERE a.auth_user_id=actor)
 THEN RAISE EXCEPTION 'customer_only';END IF;
 IF p_token IS NULL THEN RAISE EXCEPTION 'invalid_bundle';END IF;
 SELECT * INTO b FROM public.yt_pos_pass_bundles
 WHERE token_hash=encode(sha256(convert_to(p_token::text,'UTF8')),'hex') FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'bundle_invalid_or_claimed';END IF;
 IF b.status='claimed' THEN
  IF b.customer_id<>actor THEN RAISE EXCEPTION 'bundle_invalid_or_claimed';END IF;
  RETURN jsonb_build_object('ok',true,'idempotent',true,'count',
   (SELECT count(*) FROM public.yt_pos_pass_bundle_items WHERE bundle_id=b.id),'pass_ids',(SELECT jsonb_agg(pass_id order by pass_id) FROM public.yt_pos_pass_bundle_items WHERE bundle_id=b.id));
 END IF;
 IF b.status<>'issued' OR b.expires_at<=clock_timestamp()
 THEN RAISE EXCEPTION 'bundle_invalid_or_claimed';END IF;
 FOR p IN SELECT x.pass_id FROM public.yt_pos_pass_bundle_items x
 WHERE x.bundle_id=b.id ORDER BY x.pass_id LOOP
  UPDATE public.game_passes gp
   SET customer_id=actor,status='claimed',claimed_at=clock_timestamp(),
    expires_at=clock_timestamp()+interval '72 hours'
  WHERE gp.id=p.pass_id AND gp.status='issued' AND gp.customer_id IS NULL
   AND gp.expires_at>clock_timestamp();
  IF NOT FOUND THEN RAISE EXCEPTION 'bundle_pass_not_available';END IF;
  v_count:=v_count+1;v_ids:=array_append(v_ids,p.pass_id);
 END LOOP;
 IF v_count<1 THEN RAISE EXCEPTION 'bundle_empty';END IF;
 UPDATE public.yt_pos_pass_bundles SET status='claimed',customer_id=actor,claimed_at=clock_timestamp()
 WHERE id=b.id;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 VALUES(actor,'pos.bundle_claimed','pos_pass_bundle',b.id,jsonb_build_object('count',v_count));
 RETURN jsonb_build_object('ok',true,'count',v_count,'pass_ids',to_jsonb(v_ids),'idempotent',false);
END;$function$;

CREATE OR REPLACE FUNCTION private.yt_owner_set_campaign(p_campaign uuid, p_active boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 IF NOT private.yt_has_role('owner') THEN RAISE EXCEPTION 'owner_only'; END IF;
 IF p_campaign IS NULL OR p_active IS NULL THEN RAISE EXCEPTION 'invalid_campaign'; END IF;
 IF p_active AND NOT EXISTS(SELECT 1 FROM public.campaign_games WHERE campaign_id=p_campaign) THEN RAISE EXCEPTION 'campaign_has_no_games'; END IF;
 UPDATE public.campaigns SET active=p_active,is_default=case when p_active then is_default else false end WHERE id=p_campaign;
 IF NOT FOUND THEN RAISE EXCEPTION 'campaign_not_found'; END IF;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id) VALUES(auth.uid(),'campaign.toggle','campaign',p_campaign);
 RETURN p_active;
END $function$;

create or replace function private.yt_pos_owner_revision_apply(p_order uuid,p_items jsonb,p_reason text,p_table text,p_note text,p_expected_updated timestamptz,p_request uuid,p_revoke boolean default false,p_cancel boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_member_orders%rowtype;old jsonb;r jsonb;j jsonb;item uuid;idx integer;keep uuid[]:='{}';received numeric;balance numeric;payload jsonb;done public.yt_pos_order_revisions%rowtype;after_state jsonb;benefits jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_order is null or p_request is null or p_expected_updated is null or p_revoke is null or p_cancel is null or length(btrim(coalesce(p_reason,''))) not between 3 and 300 or length(coalesce(p_table,''))>32 or length(coalesce(p_note,''))>600 then raise exception 'invalid_order_revision';end if;
 payload:=jsonb_build_object('order',p_order,'items',p_items,'reason',p_reason,'table',p_table,'note',p_note,'expected',p_expected_updated,'revoke',p_revoke,'cancel',p_cancel);
 perform pg_advisory_xact_lock(781943081);
 select * into v from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 select * into done from public.yt_pos_order_revisions where request_id=p_request;
 if found then if done.request_payload<>payload then raise exception 'request_conflict';end if;return done.after_state||jsonb_build_object('ok',true,'retried',true);end if;
 if v.status in ('cancelled','refunded') then raise exception 'order_not_editable';end if;
 if v.updated_at<>p_expected_updated then raise exception 'order_changed_reload';end if;
 perform pg_advisory_xact_lock(781943080);
 if exists(select 1 from public.yt_pos_reward_holds where order_id=p_order and state in ('ready','reserved')) and not p_cancel then raise exception 'release_coupon_before_edit';end if;
 r:=private.yt_pos_revision_lines(p_order,p_items,p_cancel);received:=private.yt_pos_received(p_order);
 old:=to_jsonb(v)||jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(i) order by id),'[]') from public.yt_member_order_items i where order_id=p_order),'benefits',private.yt_pos_order_benefits(p_order),'received_rm',received);
 if p_revoke then benefits:=private.yt_pos_revoke_order_benefits(p_order);end if;
 if p_cancel then
  update public.yt_pos_reward_holds set state='released',updated_at=clock_timestamp() where order_id=p_order and state in ('ready','reserved');
  update public.yt_pos_preorder_holds set state='released',updated_at=clock_timestamp() where attached_order_id=p_order and state='attached';
 end if;
 for j in select value from jsonb_array_elements(r->'lines') loop
  item:=nullif(j->>'item_id','')::uuid;
  if item is null then
   insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
   values(p_order,(j->>'product_id')::uuid,j->>'name',(j->>'quantity')::integer,(j->>'unit_price_rm')::numeric) returning id into item;
  else
   update public.yt_member_order_items set product_id=(j->>'product_id')::uuid,item_name=j->>'name',quantity=(j->>'quantity')::integer,unit_price_rm=(j->>'unit_price_rm')::numeric,
   is_drink_at_order=(j->>'is_drink')::boolean,series_id_at_order=nullif(j->>'series_id','')::uuid where id=item;
  end if;
  keep:=array_append(keep,item);
  update public.yt_pos_item_units set retired=unit_number>(j->>'quantity')::integer,
   reward_discount_rm=case when unit_number<=(j->>'quantity')::integer then least(reward_discount_rm,(j->>'unit_price_rm')::numeric) else reward_discount_rm end where order_item_id=item;
  for idx in 1..(j->>'quantity')::integer loop insert into public.yt_pos_item_units(order_item_id,unit_number) values(item,idx) on conflict do nothing;end loop;
 end loop;
 update public.yt_member_order_items set quantity=0 where order_id=p_order and not(id=any(keep));
 update public.yt_pos_item_units u set retired=true from public.yt_member_order_items i where i.id=u.order_item_id and i.order_id=p_order and i.quantity=0;
 balance:=(r->>'net')::numeric-received;
 update public.yt_member_orders set amount_rm=(r->>'net')::numeric,table_label=nullif(btrim(coalesce(p_table,'')),''),notes=nullif(btrim(coalesce(p_note,'')),''),revision=v.revision+1,
 cancel_after_refund=p_cancel,settlement_due_since=case when v.payment_status='paid' and balance<>0 then coalesce(v.settlement_due_since,clock_timestamp()) else null end,
 status=case when p_cancel and v.payment_status='unpaid' then 'cancelled' when p_cancel and balance=0 then 'refunded' else v.status end,
 payment_status=case when p_cancel and v.payment_status='paid' and balance=0 then 'refunded' else v.payment_status end,updated_at=clock_timestamp() where id=p_order returning * into v;
 if p_cancel then update public.yt_pos_order_chits set status='cancelled' where order_id=p_order;end if;
 after_state:=to_jsonb(v)||jsonb_build_object('items',r->'lines','received_rm',received,'balance_rm',case when v.payment_status='unpaid' then v.amount_rm else balance end,'revoked_benefits',benefits);
 insert into public.yt_pos_order_revisions(order_id,revision,request_id,request_payload,reason,actor_id,before_state,after_state,revoke_benefits)
 values(p_order,v.revision,p_request,payload,p_reason,auth.uid(),old,after_state,p_revoke);
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note) values(p_order,auth.uid(),'edited','cashier',p_reason);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.owner_revision','pos_order',p_order,jsonb_build_object('revision',v.revision,'reason',p_reason,'before_amount',old->'amount_rm','after_amount',v.amount_rm,'balance_rm',balance,'revoke_benefits',p_revoke,'cancel',p_cancel));
 return after_state||jsonb_build_object('ok',true);
end $$;
