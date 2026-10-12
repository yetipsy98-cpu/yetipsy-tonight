-- Integrate Moon guest reservations with POS quotes, payment trigger, receipts and scoped reset. No data deletes.
CREATE OR REPLACE FUNCTION private.yt_pos_cart_summary(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_member_orders%rowtype;v_holds jsonb;v_discount numeric(12,2);v_broken int;v_store_box_only boolean;v_moon numeric:=0;v_moon_bad int:=0;v_moon_codes jsonb:='[]'::jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found';end if;
 v_store_box_only:=private.yt_store_box_order_only(p_order);
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',h.id,'reward_name',r.name,'state',h.state,'discount_type',h.discount_type,
  'discount_rm',h.discount_rm,'expires_at',h.expires_at,
  'item_name',i.item_name,'unit_number',h.unit_number,
  'can_checkout',h.state='ready' and h.expires_at>clock_timestamp()
 ) order by h.created_at),'[]'::jsonb),
 coalesce(sum(case when h.state='ready' and h.expires_at>clock_timestamp() then h.discount_rm else 0 end),0),
 count(*) filter (where h.state='reserved' or h.expires_at<=clock_timestamp())
 into v_holds,v_discount,v_broken
 from public.yt_pos_reward_holds h
 join public.rewards r on r.id=h.reward_id
 left join public.yt_member_order_items i on i.id=h.order_item_id
 where h.order_id=v.id and h.state in ('reserved','ready');
 SELECT coalesce(sum(CASE WHEN kind='R0' THEN 5 ELSE 0 END),0),
 count(*) FILTER (WHERE valid_until<(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date),
 coalesce(jsonb_agg(jsonb_build_object('id',id,'code',code,'kind',kind,'discount_rm',CASE WHEN kind='R0' THEN 5 ELSE 0 END,
 'status',status,'can_checkout',valid_until>=(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date)
 ORDER BY created_at),'[]'::jsonb)
 INTO v_moon,v_moon_bad,v_moon_codes FROM public.yt_moon_guest_codes WHERE reserved_order_id=p_order AND status='reserved';
 return private.yt_pos_order_minimum(p_order)||jsonb_build_object('order_id',v.id,'order_no',v.order_no,'status',v.status,
  'payment_status',v.payment_status,'checkout_mode',v.checkout_mode,'gross_rm',v.amount_rm,
  'reserved_discount_rm',v_discount+v_moon,'payable_rm',greatest(0,v.amount_rm-v_discount-v_moon),
  'unresolved_count',v_broken+v_moon_bad,'holds',v_holds,'moon_codes',v_moon_codes,'store_box_only',v_store_box_only,
  'can_pay',v.payment_status='unpaid' and v.status in ('confirmed','fulfilled') and v_broken=0
   and v_discount+v_moon<=v.amount_rm and (v_moon=0 or v.amount_rm>v_discount+v_moon) and v_moon_bad=0 and (private.yt_pos_order_minimum(p_order)->>'minimum_met')::boolean);
end $function$
;

CREATE OR REPLACE FUNCTION private.yt_pos_checkout_quote()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE n_bad integer;v_discount numeric;v_moon numeric:=0;v_moon_bad integer:=0;
BEGIN
 IF OLD.payment_status='unpaid' AND NEW.payment_status='paid'
    AND OLD.source='future_pos' THEN
  SELECT count(*) FILTER (WHERE state<>'ready' OR expires_at<=clock_timestamp()),
   coalesce(sum(CASE WHEN state='ready' AND expires_at>clock_timestamp()
              THEN discount_rm ELSE 0 END),0)
   INTO n_bad,v_discount
  FROM public.yt_pos_reward_holds WHERE order_id=NEW.id AND state IN ('reserved','ready');
  IF n_bad>0 THEN RAISE EXCEPTION 'coupon_hold_not_ready_or_expired';END IF;
  SELECT coalesce(sum(CASE WHEN kind='R0' THEN 5 ELSE 0 END),0),
 count(*) FILTER (WHERE valid_until<(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date)
 INTO v_moon,v_moon_bad FROM public.yt_moon_guest_codes WHERE reserved_order_id=NEW.id AND status='reserved';
 IF v_moon_bad>0 THEN RAISE EXCEPTION 'moon_expired';END IF;
 IF v_discount+v_moon>OLD.amount_rm THEN RAISE EXCEPTION 'discount_exceeds_bill';END IF;
 IF v_moon>0 AND OLD.amount_rm<=v_discount+v_moon THEN RAISE EXCEPTION 'moon_minimum_payable';END IF;
  IF NOT (private.yt_pos_order_minimum(NEW.id)->>'minimum_met')::boolean THEN RAISE EXCEPTION 'minimum_one_paid_drink';END IF;
  NEW.amount_rm:=OLD.amount_rm-v_discount-v_moon;
 END IF;
 RETURN NEW;
END;$function$
;

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
    from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id
    where i.order_id=v.id and i.quantity>0 and not u.retired),0)+5*(select count(*) from public.yt_moon_guest_codes c where c.kind='R0' and c.redeemed_order_id=v.id and c.status='redeemed'),
  'moon_codes',coalesce((select jsonb_agg(jsonb_build_object('kind',c.kind,'code',c.code,'item_id',c.reserved_item_id)) from public.yt_moon_guest_codes c where (c.reserved_order_id=v.id or c.redeemed_order_id=v.id) and c.status in ('reserved','redeemed')),'[]'::jsonb),
  'gross_total_rm',coalesce((select sum(i.quantity*i.unit_price_rm)
    from public.yt_member_order_items i where i.order_id=v.id and i.quantity>0),0),
  'amount_rm',v.amount_rm,
  'created_by',(select a.username from public.work_accounts a where a.auth_user_id=v.created_by),
  'items',coalesce((select jsonb_agg(jsonb_build_object(
    'item_name',i.item_name,'quantity',i.quantity,'unit_price_rm',i.unit_price_rm,
    'line_total_rm',i.quantity*i.unit_price_rm-coalesce((select sum(u.reward_discount_rm) from public.yt_pos_item_units u where u.order_item_id=i.id and not u.retired),0),
    'discount_rm',coalesce((select sum(u.reward_discount_rm) from public.yt_pos_item_units u where u.order_item_id=i.id and not u.retired),0)) order by i.item_name,i.id)
    from public.yt_member_order_items i where i.order_id=v.id and i.quantity>0),'[]'::jsonb),
  'document_type',case when v.payment_status='paid' then 'PAYMENT RECEIPT' else 'UNPAID BILL - NOT A RECEIPT' end,
  'disclaimer','Internal Yetipsy order record. Foodcourt payment method is recorded by cashier; not a tax invoice.',
  'receipt_settings',private.yt_receipt_settings_get()
 );
end;$function$
;

CREATE OR REPLACE FUNCTION private.yt_owner_reset_v9(p_actor uuid, p_session text, p_action text, p_challenge uuid DEFAULT NULL::uuid, p_request uuid DEFAULT NULL::uuid, p_done bigint[] DEFAULT '{}'::bigint[], p_scopes text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v private.yt_owner_reset_challenges%rowtype; s text[]; counts jsonb:='{}'; result jsonb; c uuid;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'owner_only';end if;
 if p_session is null or p_session !~ '^[0-9a-f]{64}$' then raise exception 'not_authenticated';end if;
 if not exists(select 1 from public.work_accounts a join public.staff_roles r on r.user_id=a.auth_user_id
  where a.auth_user_id=p_actor and a.role='owner' and a.active and not a.must_change_password and r.role='owner' and r.active)
 then raise exception 'owner_only';end if;
 if p_action in ('status','batch','ack') then
  result=private.yt_owner_reset_v7(p_actor,p_session,p_action,p_challenge,p_request,p_done);
  select * into v from private.yt_owner_reset_challenges where id=(result->>'challenge')::uuid and actor_id=p_actor;
  return result||jsonb_build_object('scopes',coalesce(v.scopes,'{}'::text[]));
 end if;
 if p_action='prepare' then
  if p_request is null then raise exception 'invalid_reset_request';end if;
  if p_scopes is null or cardinality(p_scopes)=0 or cardinality(p_scopes)>7 or exists(
   select 1 from unnest(p_scopes) x where x is null or x not in ('records','members','catalog','campaigns','team','banners','storebox'))
  then raise exception 'invalid_reset_scope';end if;
  select array_agg(distinct x order by x) into s from unnest(p_scopes) x;
  if s&&array['members','catalog','campaigns','team']::text[] and not ('records'=any(s)) then s=array_append(s,'records');end if;
  select array_agg(x order by x) into s from unnest(s) x;
  if exists(select 1 from private.yt_owner_reset_challenges where state='committed') then raise exception 'reset_cleanup_pending';end if;
  if 'members'=any(s) and not ('storebox'=any(s)) and exists (select 1 from public.yt_store_boxes where customer_id is not null) then raise exception 'storebox_member_reset_blocked';end if;
   if 'records'=any(s) then counts=counts||jsonb_build_object('订单',(select count(*) from public.yt_member_orders),'Game Pass',(select count(*) from public.game_passes),'钱包奖励',(select count(*) from public.user_rewards),'积分记录',(select count(*) from public.yt_point_entries));end if;
  if 'members'=any(s) then counts=counts||jsonb_build_object('会员账号',(select count(*) from public.pin_accounts where auth_user_id<>p_actor and not exists(select 1 from public.work_accounts w where w.auth_user_id=pin_accounts.auth_user_id)));end if;
  if 'catalog'=any(s) then counts=counts||jsonb_build_object('商品',(select count(*) from public.yt_shop_products),'权益系列',(select count(*) from public.yt_pos_series));end if;
  if 'campaigns'=any(s) then counts=counts||jsonb_build_object('活动',(select count(*) from public.campaigns),'奖励种类',(select count(*) from public.rewards));end if;
  if 'team'=any(s) then counts=counts||jsonb_build_object('其他工作账号',(select count(*) from public.work_accounts where auth_user_id<>p_actor));end if;
  if 'storebox'=any(s) then counts=counts||jsonb_build_object('存酒箱',(select count(*) from public.yt_store_boxes),'未完成叫酒',(select count(*) from public.yt_store_box_requests where status not in ('served','cancelled','rejected')));end if;
   if 'banners'=any(s) then counts=counts||jsonb_build_object('广告',(select count(*) from public.yt_home_banners),'广告文件',(select count(*) from storage.objects where bucket_id='yetipsy-home-banners'));end if;
  insert into private.yt_owner_reset_challenges(actor_id,session_key,request_id,counts,scopes)
   values(p_actor,p_session,p_request,counts,s) on conflict(actor_id,session_key,request_id) do nothing;
  select * into v from private.yt_owner_reset_challenges where actor_id=p_actor and session_key=p_session and request_id=p_request;
  if v.scopes<>s then raise exception 'reset_scope_conflict';end if;
  if v.state<>'pending' or v.expires_at<=now() then raise exception 'reset_confirmation_expired';end if;
  return jsonb_build_object('challenge',v.id,'counts',v.counts,'scopes',v.scopes,'expires_at',v.expires_at);
 end if;
 if p_action<>'commit' or p_challenge is null then raise exception 'invalid_reset_request';end if;
 perform pg_advisory_xact_lock(781943071);
 select * into v from private.yt_owner_reset_challenges where id=p_challenge and actor_id=p_actor and session_key=p_session for update;
 if not found then raise exception 'reset_confirmation_expired';end if;
 if v.state in ('committed','complete') then return jsonb_build_object('challenge',v.id,'state',v.state,'scopes',v.scopes);end if;
 if v.state<>'pending' or v.expires_at<=now() then raise exception 'reset_confirmation_expired';end if;
 if exists(select 1 from private.yt_owner_reset_challenges where state='committed' and id<>v.id) then raise exception 'reset_cleanup_pending';end if;
 s=v.scopes;
  if 'members'=any(s) and not ('storebox'=any(s)) and exists (select 1 from public.yt_store_boxes where customer_id is not null) then raise exception 'storebox_member_reset_blocked';end if;
  if cardinality(s)=7 then delete from public.yt_business_cutoffs where true;insert into public.yt_business_cutoffs(effective_day,cutoff_minutes) values('1900-01-01',360);end if; -- Only this immutable first-confirmation snapshot controls deletion.
 if 'banners'=any(s) then
  insert into private.yt_owner_reset_cleanup(challenge_id,kind,target) select v.id,'asset',name from storage.objects where bucket_id='yetipsy-home-banners';
 end if;
 insert into private.yt_owner_reset_cleanup(challenge_id,kind,target)
 select v.id,'user',u.id::text from auth.users u where u.id<>p_actor and (
  ('members'=any(s) and 'team'=any(s))
  or ('members'=any(s) and exists(select 1 from public.pin_accounts a where a.auth_user_id=u.id) and not exists(select 1 from public.work_accounts a where a.auth_user_id=u.id))
  or ('team'=any(s) and exists(select 1 from public.work_accounts a where a.auth_user_id=u.id)));
 if 'storebox'=any(s) then
   truncate table public.yt_store_box_events,public.yt_store_box_requests,public.yt_store_box_claims,public.yt_store_boxes restart identity;
  end if;
  if 'records'=any(s) then
   UPDATE public.yt_moon_guest_codes SET status='available',reserved_order_id=NULL,reserved_item_id=NULL WHERE status='reserved';
   update public.yt_store_boxes b
   set source_order_snapshot=coalesce(b.source_order_snapshot,jsonb_build_object('id',o.id,'order_no',o.order_no,'created_at',o.created_at,'table_label',o.table_label,'amount_rm',o.amount_rm)),
       source_item_snapshot=coalesce(b.source_item_snapshot,jsonb_build_object('id',i.id,'item_name',i.item_name,'quantity',i.quantity,'unit_price_rm',i.unit_price_rm))
   from public.yt_member_orders o join public.yt_member_order_items i on i.order_id=o.id
   where b.source_order_id=o.id and b.source_order_item_id=i.id;
  -- Fixed transaction tables; configuration and account tables are retained.
  truncate table private.yt_offer_code_attempts,private.yt_offer_short_codes,private.yt_pos_draft_submissions,
   private.yt_redeem_code_attempts,private.yt_redeem_short_codes,
   public.audit_logs,public.game_passes,public.game_sessions,public.idempotency_keys,
   public.pin_auth_limits,public.pin_lookup_limits,public.pin_reset_tokens,public.redeem_tokens,public.redemptions,
   public.reward_offer_claims,public.reward_offers,public.user_rewards,public.work_auth_limits,
   public.yt_game_best_records,public.yt_game_leaderboard_preferences,public.yt_integration_events,
   public.yt_member_enrollments,public.yt_member_order_items,public.yt_member_orders,public.yt_point_shop_exchanges,public.yt_point_entries,public.yt_point_wallets,
   public.yt_pos_order_revisions,public.yt_pos_payment_entries,public.yt_pos_day_closings,public.yt_pos_item_units,public.yt_pos_order_chits,public.yt_pos_order_events,public.yt_pos_pass_bundle_items,public.yt_pos_pass_bundles,
   public.yt_pos_preorder_holds,public.yt_pos_reward_holds,public.yt_promo_grants,public.yt_referral_links restart identity;
  update public.yt_point_shop_items set stock_used=0 where true;
  update public.reward_pool_entries set issued_total=0,issued_today=0,issued_day=null where true;
  -- Deleted enrollment/grant history must not automatically grant old members new gifts.
  update public.yt_loyalty_config set welcome_enabled=false,referral_enabled=false,updated_at=now() where true;
 end if;
 if 'campaigns'=any(s) then
  delete from public.yt_point_shop_items where true;
  update public.games set points_max=100,reaction_perfect_ms=200,reaction_zero_ms=1000 where true;
  delete from public.yt_pos_reward_rules where true;delete from public.reward_pool_entries where true;delete from public.campaign_games where true;
  delete from public.yt_point_tiers where true;delete from public.yt_loyalty_config where true;
  delete from public.rewards where true;delete from public.campaigns where true;
  insert into public.yt_loyalty_config(id) values(true);
  insert into public.campaigns(name,active) values('默认活动',false) returning id into c;
  insert into public.campaign_games(campaign_id,game_id) select c,id from public.games where active;
 end if;
 if 'catalog'=any(s) then
  delete from public.yt_pos_reward_rules where product_id is not null or series_id is not null;
  delete from public.yt_shop_products where true;delete from public.yt_pos_series where true;
 end if;
 if 'banners'=any(s) then delete from public.yt_home_banners where true;end if;
 if s&&array['members','team']::text[] then
  update public.yt_home_banners set updated_by=null where updated_by::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  update public.yt_loyalty_config set updated_by=null where updated_by::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  update public.yt_pos_reward_rules set updated_by=null where updated_by::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  update public.work_accounts set created_by=null where created_by::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.pin_accounts where auth_user_id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.member_details where user_id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.work_accounts where auth_user_id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.staff_roles where user_id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.profiles where id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
 end if;
 update private.yt_owner_reset_challenges set state='cancelled' where state='pending' and id<>v.id;
 update private.yt_owner_reset_challenges set state='committed' where id=v.id;
 return jsonb_build_object('challenge',v.id,'state','committed','scopes',v.scopes);
end;$function$
;