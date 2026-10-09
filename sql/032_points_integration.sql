-- Preserve daily closing, Owner revision and scoped reset behavior.
CREATE OR REPLACE FUNCTION private.yt_loyalty_member_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor uuid:=auth.uid();v_code text;cfg public.yt_loyalty_config%rowtype;i integer;v_wallet public.yt_point_wallets%rowtype;
begin
 if v_actor is null or not exists(select 1 from public.pin_accounts where auth_user_id=v_actor)
   or exists(select 1 from public.work_accounts where auth_user_id=v_actor)
 then raise exception 'customer_only';end if;
 select * into cfg from public.yt_loyalty_config where id=true;
 select code into v_code from public.yt_member_ref_codes where customer_id=v_actor;
 if v_code is null then
  for i in 1..8 loop
    v_code:='YT'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
    insert into public.yt_member_ref_codes(customer_id,code)
    values(v_actor,v_code) on conflict do nothing;
    select code into v_code from public.yt_member_ref_codes where customer_id=v_actor;
    exit when v_code is not null;
  end loop;
  if v_code is null then raise exception 'code_generation_failed';end if;
 end if;
 perform pg_advisory_xact_lock(781943081);perform private.yt_points_sync(v_actor);
 select * into v_wallet from public.yt_point_wallets where customer_id=v_actor;
 return jsonb_build_object(
  'referral_code',v_code,
  'referral_enabled',cfg.referral_enabled,
  'welcome_enabled',cfg.welcome_enabled,
  'points_enabled',cfg.points_enabled,
  'points_per_rm',cfg.points_per_rm,
  'max_points_percent',cfg.max_points_percent,
  'min_spend_rm',cfg.min_spend_rm,
  'points_balance',coalesce(v_wallet.balance,0),
  'points_earned',coalesce(v_wallet.lifetime_earned,0),
  'points_history',coalesce((
    select jsonb_agg(to_jsonb(hist)) from (
      select direction,points,reference,created_at,source,expires_at
      from public.yt_point_entries where customer_id=v_actor
      order by created_at desc limit 30
    ) hist
  ),'[]'::jsonb)
 );
end;$function$
;

CREATE OR REPLACE FUNCTION private.yt_loyalty_owner_save(p_welcome_enabled boolean, p_welcome_reward uuid, p_referral_enabled boolean, p_friend_reward uuid, p_inviter_reward uuid, p_stack boolean, p_points_enabled boolean, p_points_per_rm integer, p_cap_percent numeric, p_min_spend numeric, p_max_spend numeric)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not private.yt_has_role('owner') then raise exception 'owner_only';end if;
 if p_welcome_enabled is null or p_referral_enabled is null or p_points_enabled is null
   or p_stack is null or p_points_per_rm not between 1 and 10000
   or p_cap_percent not between 0.01 and 30 or p_min_spend not between .01 and 10000
   or p_max_spend not between p_min_spend and 100000
 then raise exception 'invalid_loyalty_settings';end if;
 if p_welcome_enabled and not exists(select 1 from public.rewards where id=p_welcome_reward and active)
 then raise exception 'select_welcome_reward';end if;
 if p_referral_enabled and not exists(select 1 from public.rewards where id=p_friend_reward and active)
 then raise exception 'select_referral_reward';end if;
 if p_inviter_reward is not null and not exists(select 1 from public.rewards where id=p_inviter_reward and active)
 then raise exception 'invalid_inviter_reward';end if;
 update public.yt_loyalty_config set welcome_enabled=p_welcome_enabled,
 welcome_reward_id=p_welcome_reward,referral_enabled=p_referral_enabled,
 friend_reward_id=p_friend_reward,inviter_reward_id=p_inviter_reward,
 rewards_stack=p_stack,points_enabled=p_points_enabled,
 points_per_rm=p_points_per_rm,max_points_percent=p_cap_percent,
 min_spend_rm=p_min_spend,max_spend_rm=p_max_spend,updated_at=clock_timestamp(),updated_by=auth.uid()
 where id=true;
 insert into public.audit_logs(actor_id,action,entity_type,metadata)
 values(auth.uid(),'loyalty.settings_updated','loyalty_config',
 jsonb_build_object('welcome',p_welcome_enabled,'referral',p_referral_enabled,
 'points',p_points_enabled,'cap_percent',p_cap_percent));
 return true;
end;$function$
;

CREATE OR REPLACE FUNCTION private.yt_pos_revoke_order_benefits(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ids uuid[];e record;b bigint;report jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select array_agg(u.game_pass_id order by u.game_pass_id) into ids from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id where i.order_id=p_order and u.game_pass_id is not null;
 perform pg_advisory_xact_lock(781943081);
 if ids is null then return private.yt_pos_order_benefits(p_order);end if;
 perform 1 from public.game_sessions where pass_id=any(ids) order by id for update;
 perform 1 from public.game_passes where id=any(ids) order by id for update;
 perform 1 from public.user_rewards w join public.game_sessions s on s.id=w.session_id where s.pass_id=any(ids) order by w.id for update of w;
 report:=private.yt_pos_order_benefits(p_order);
 if exists(select 1 from jsonb_array_elements(report->'rewards') w where w->>'status'='redeemed') then raise exception 'issued_reward_already_redeemed';end if;
 if exists(select 1 from jsonb_array_elements(report->'rewards') w where (w->>'locked')::boolean) then raise exception 'issued_reward_locked';end if;
 perform 1 from public.yt_point_wallets where customer_id in(select customer_id from public.yt_point_entries where game_pass_id=any(ids) and direction='earn') order by customer_id for update;
 for e in select distinct customer_id from public.yt_point_entries where game_pass_id=any(ids) and direction='earn' loop perform private.yt_points_sync(e.customer_id);end loop;
 for e in select customer_id,sum(points) points from public.yt_point_entries x where x.game_pass_id=any(ids) and direction='earn' and not exists(select 1 from public.yt_point_entries a where a.customer_id=x.customer_id and a.direction='adjust' and a.reference='OWNER-REVOKE:'||x.game_pass_id::text) group by customer_id loop
  select balance into b from public.yt_point_wallets where customer_id=e.customer_id;
  if coalesce(b,0)<e.points then raise exception 'issued_points_balance_insufficient';end if;
 end loop;
 if exists(select 1 from public.yt_point_entries x where x.game_pass_id=any(ids) and x.direction='earn' and x.remaining_points<x.points and not exists(select 1 from public.yt_point_entries a where a.customer_id=x.customer_id and a.direction='adjust' and a.reference='OWNER-REVOKE:'||x.game_pass_id::text)) then raise exception 'game_points_already_used';end if;
 for e in select * from public.yt_point_entries x where x.game_pass_id=any(ids) and direction='earn' and not exists(select 1 from public.yt_point_entries a where a.customer_id=x.customer_id and a.direction='adjust' and a.reference='OWNER-REVOKE:'||x.game_pass_id::text) order by customer_id,id loop
  update public.yt_point_entries set remaining_points=0 where id=e.id;
  update public.yt_point_wallets set balance=balance-e.points,lifetime_spent=lifetime_spent+e.points,updated_at=clock_timestamp() where customer_id=e.customer_id;
  insert into public.yt_point_entries(customer_id,direction,points,reference) values(e.customer_id,'adjust',e.points,'OWNER-REVOKE:'||e.game_pass_id::text);
 end loop;
 update public.user_rewards w set status='revoked' from public.game_sessions s where w.session_id=s.id and s.pass_id=any(ids) and w.status in ('available','expired');
 update public.game_sessions set status='cancelled' where pass_id=any(ids) and status='started';
 update public.game_passes set status='revoked' where id=any(ids) and status<>'revoked';
 update public.yt_pos_pass_bundles set status='expired',expires_at=clock_timestamp() where order_id=p_order and status='issued';
 update public.yt_pos_item_units set benefit_status='void' where game_pass_id=any(ids);
 return report;
end $function$
;

CREATE OR REPLACE FUNCTION private.yt_owner_reset_v8(p_actor uuid, p_session text, p_action text, p_challenge uuid DEFAULT NULL::uuid, p_request uuid DEFAULT NULL::uuid, p_done bigint[] DEFAULT '{}'::bigint[], p_scopes text[] DEFAULT NULL::text[])
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
  if p_scopes is null or cardinality(p_scopes)=0 or cardinality(p_scopes)>6 or exists(
   select 1 from unnest(p_scopes) x where x is null or x not in ('records','members','catalog','campaigns','team','banners'))
  then raise exception 'invalid_reset_scope';end if;
  select array_agg(distinct x order by x) into s from unnest(p_scopes) x;
  if s&&array['members','catalog','campaigns','team']::text[] and not ('records'=any(s)) then s=array_append(s,'records');end if;
  select array_agg(x order by x) into s from unnest(s) x;
  if exists(select 1 from private.yt_owner_reset_challenges where state='committed') then raise exception 'reset_cleanup_pending';end if;
  if 'records'=any(s) then counts=counts||jsonb_build_object('订单',(select count(*) from public.yt_member_orders),'Game Pass',(select count(*) from public.game_passes),'钱包奖励',(select count(*) from public.user_rewards),'积分记录',(select count(*) from public.yt_point_entries));end if;
  if 'members'=any(s) then counts=counts||jsonb_build_object('会员账号',(select count(*) from public.pin_accounts where auth_user_id<>p_actor and not exists(select 1 from public.work_accounts w where w.auth_user_id=pin_accounts.auth_user_id)));end if;
  if 'catalog'=any(s) then counts=counts||jsonb_build_object('商品',(select count(*) from public.yt_shop_products),'权益系列',(select count(*) from public.yt_pos_series));end if;
  if 'campaigns'=any(s) then counts=counts||jsonb_build_object('活动',(select count(*) from public.campaigns),'奖励种类',(select count(*) from public.rewards));end if;
  if 'team'=any(s) then counts=counts||jsonb_build_object('其他工作账号',(select count(*) from public.work_accounts where auth_user_id<>p_actor));end if;
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
 s=v.scopes; if cardinality(s)=6 then delete from public.yt_business_cutoffs;insert into public.yt_business_cutoffs(effective_day,cutoff_minutes) values('1900-01-01',360);end if; -- Only this immutable first-confirmation snapshot controls deletion.
 if 'banners'=any(s) then
  insert into private.yt_owner_reset_cleanup(challenge_id,kind,target) select v.id,'asset',name from storage.objects where bucket_id='yetipsy-home-banners';
 end if;
 insert into private.yt_owner_reset_cleanup(challenge_id,kind,target)
 select v.id,'user',u.id::text from auth.users u where u.id<>p_actor and (
  ('members'=any(s) and 'team'=any(s))
  or ('members'=any(s) and exists(select 1 from public.pin_accounts a where a.auth_user_id=u.id) and not exists(select 1 from public.work_accounts a where a.auth_user_id=u.id))
  or ('team'=any(s) and exists(select 1 from public.work_accounts a where a.auth_user_id=u.id)));
 if 'records'=any(s) then
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
  update public.yt_point_shop_items set stock_used=0;
  update public.reward_pool_entries set issued_total=0,issued_today=0,issued_day=null;
  -- Deleted enrollment/grant history must not automatically grant old members new gifts.
  update public.yt_loyalty_config set welcome_enabled=false,referral_enabled=false,updated_at=now();
 end if;
 if 'campaigns'=any(s) then
  delete from public.yt_point_shop_items;
  update public.games set points_max=100,reaction_perfect_ms=200,reaction_zero_ms=1000;
  delete from public.yt_pos_reward_rules;delete from public.reward_pool_entries;delete from public.campaign_games;
  delete from public.yt_point_tiers;delete from public.yt_loyalty_config;
  delete from public.rewards;delete from public.campaigns;
  insert into public.yt_loyalty_config(id) values(true);
  insert into public.campaigns(name,active) values('默认活动',false) returning id into c;
  insert into public.campaign_games(campaign_id,game_id) select c,id from public.games where active;
 end if;
 if 'catalog'=any(s) then
  delete from public.yt_pos_reward_rules where product_id is not null or series_id is not null;
  delete from public.yt_shop_products;delete from public.yt_pos_series;
 end if;
 if 'banners'=any(s) then delete from public.yt_home_banners;end if;
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

CREATE OR REPLACE FUNCTION private.yt_owner_report_v8(p_start date, p_end date, p_member_page integer DEFAULT 1, p_search text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare today date:=private.yt_business_day(now());
 a timestamptz;z timestamptz;t timestamptz;m timestamptz; result jsonb; stats jsonb; days jsonb; pay jsonb; products jsonb; orders jsonb; members jsonb; member_total bigint;
begin
 if not private.yt_has_role('owner') or not private.yt_pos_work_staff() then raise exception 'owner_only';end if;
 if p_start is null or p_end is null or p_start>p_end or p_end-p_start>365 or p_member_page is null or p_member_page<1 or p_member_page>10000 or p_search is null or length(p_search)>80 then raise exception 'invalid_report_range';end if;
 a=private.yt_business_start(p_start);z=private.yt_business_start(p_end+1);
 t=private.yt_business_start(today);m=private.yt_business_start(date_trunc('month',today::timestamp)::date);
 select jsonb_build_object('today_amount',coalesce(sum(amount_rm) filter(where business_day=today),0),
  'today_orders',count(distinct order_id) filter(where business_day=today),
  'month_amount',coalesce(sum(amount_rm) filter(where business_day>=date_trunc('month',today::timestamp)::date and business_day<(date_trunc('month',today::timestamp)+interval '1 month')::date),0),
  'month_orders',count(distinct order_id) filter(where business_day>=date_trunc('month',today::timestamp)::date and business_day<(date_trunc('month',today::timestamp)+interval '1 month')::date))
 into stats from public.yt_pos_payment_entries where business_day>=date_trunc('month',today::timestamp)::date;
 select stats||jsonb_build_object('range_amount',coalesce(sum(e.amount_rm),0),'range_orders',count(distinct e.order_id),
  'average_order',case when count(distinct e.order_id)>0 then round(sum(e.amount_rm)/count(distinct e.order_id),2) else 0 end) into stats
 from public.yt_pos_payment_entries e where business_day between p_start and p_end;
 select stats||jsonb_build_object('range_gross',coalesce(sum(i.gross),0),'range_discount',coalesce(sum(i.gross-o.amount_rm),0),
  'range_items',coalesce(sum(i.quantity),0)) into stats
 from public.yt_member_orders o cross join lateral(select coalesce(sum(quantity*unit_price_rm),0) gross,coalesce(sum(quantity),0) quantity from public.yt_member_order_items where order_id=o.id and quantity>0) i
 where o.source='future_pos' and o.payment_status='paid' and o.status='fulfilled' and o.paid_at>=a and o.paid_at<z;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.day),'[]'::jsonb) into days from(
  select business_day as day,count(distinct order_id) orders,sum(amount_rm) amount_rm
  from public.yt_pos_payment_entries where business_day between p_start and p_end group by 1) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.amount_rm desc),'[]'::jsonb) into pay from(
  select method,count(distinct order_id) orders,sum(amount_rm) amount_rm
  from public.yt_pos_payment_entries where business_day between p_start and p_end group by 1) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.quantity desc,x.item_name),'[]'::jsonb) into products from(
  select i.product_id,i.item_name,sum(i.quantity) quantity,sum(i.quantity*i.unit_price_rm) gross_rm,
   sum(i.quantity*i.unit_price_rm-coalesce(u.discount,0)) net_rm
  from public.yt_member_order_items i join public.yt_member_orders o on o.id=i.order_id
  left join lateral(select sum(reward_discount_rm) discount from public.yt_pos_item_units where order_item_id=i.id and not retired and unit_number<=i.quantity) u on true
  where o.source='future_pos' and o.payment_status='paid' and o.status='fulfilled' and o.paid_at>=a and o.paid_at<z and i.quantity>0
  group by i.product_id,i.item_name order by quantity desc,i.item_name limit 20) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.paid_at desc),'[]'::jsonb) into orders from(
  select o.id,o.order_no,o.table_label,max(e.received_at) paid_at,string_agg(distinct e.method,', ' order by e.method) payment_method,sum(e.amount_rm) amount_rm
  from public.yt_pos_payment_entries e join public.yt_member_orders o on o.id=e.order_id
  where e.business_day between p_start and p_end group by o.id order by max(e.received_at) desc,o.id limit 50) x;
 select count(*) into member_total from public.pin_accounts p left join public.profiles f on f.id=p.auth_user_id
 where not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)
 and (p_search='' or position(lower(p_search) in lower(coalesce(f.display_name,'')||' '||p.phone))>0);
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id),'[]'::jsonb) into members from(
  select p.auth_user_id id,p.phone,coalesce(nullif(f.display_name,''),'会员') display_name,p.created_at,
   (select coalesce(sum(remaining_points),0) from public.yt_point_entries e where e.customer_id=p.auth_user_id and e.direction='earn' and (e.expires_at is null or e.expires_at>clock_timestamp())) points,
   (select count(*) from public.user_rewards r where r.customer_id=p.auth_user_id and r.status='available' and r.expires_at>now()) wallet_rewards,
   (select count(*) from public.game_passes g where g.customer_id=p.auth_user_id and g.status='claimed' and g.expires_at>now()) game_passes,
   (select coalesce(sum(i.unit_price_rm-u.reward_discount_rm),0) from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id join public.yt_member_orders o on o.id=i.order_id
     where u.assigned_customer_id=p.auth_user_id and not u.retired and u.unit_number<=i.quantity and o.payment_status='paid' and o.source='future_pos') attributed_amount,
   greatest((select max(claimed_at) from public.game_passes where customer_id=p.auth_user_id),
    (select max(started_at) from public.game_sessions where customer_id=p.auth_user_id),
    (select max(redeemed_at) from public.redemptions where customer_id=p.auth_user_id)) last_activity
  from public.pin_accounts p left join public.profiles f on f.id=p.auth_user_id left join public.yt_point_wallets w on w.customer_id=p.auth_user_id
  where not exists(select 1 from public.work_accounts wa where wa.auth_user_id=p.auth_user_id)
   and (p_search='' or position(lower(p_search) in lower(coalesce(f.display_name,'')||' '||p.phone))>0)
  order by p.created_at desc,p.auth_user_id limit 40 offset (p_member_page-1)*40) x;
 result=jsonb_build_object('financial_source','payment_ledger','generated_at',now(),'timezone','Asia/Kuala_Lumpur','start',p_start,'end',p_end,'stats',stats,'days',days,'payments',pay,'products',products,'orders',orders,
  'members',members,'member_page',p_member_page,'member_page_size',40,'member_filtered_total',member_total,
  'member_stats',jsonb_build_object(
   'total',(select count(*) from public.pin_accounts p where not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)),
   'month_new',(select count(*) from public.pin_accounts p where created_at>=m and created_at<private.yt_business_start(today+1) and not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)),
   'active_30d',(select count(distinct customer_id) from(
     select customer_id from public.game_passes where claimed_at>=now()-interval '30 days'
     union select customer_id from public.game_sessions where started_at>=now()-interval '30 days'
     union select customer_id from public.redemptions where redeemed_at>=now()-interval '30 days') q where customer_id is not null and exists(select 1 from public.pin_accounts pa where pa.auth_user_id=q.customer_id) and not exists(select 1 from public.work_accounts wa where wa.auth_user_id=q.customer_id)),
   'point_balance',(select coalesce(sum(remaining_points),0) from public.yt_point_entries where direction='earn' and (expires_at is null or expires_at>clock_timestamp()))),
  'live',jsonb_build_object(
   'active_point_shop_items',(select count(*) from public.yt_point_shop_items i join public.rewards r on r.id=i.reward_id where i.active and r.active and (i.starts_at is null or i.starts_at<=now()) and (i.ends_at is null or i.ends_at>now()) and (i.stock_limit is null or i.stock_used<i.stock_limit)),
   'pending_orders',(select count(*) from public.yt_member_orders where source='future_pos' and status='pending' and payment_status='unpaid'),
   'preparing_orders',(select count(*) from public.yt_member_orders where source='future_pos' and status='confirmed' and payment_status='unpaid'),
   'unpaid_orders',(select count(*) from public.yt_member_orders where source='future_pos' and status='fulfilled' and payment_status='unpaid'),
   'active_products',(select count(*) from public.yt_shop_products where active),
   'active_series',(select count(*) from public.yt_pos_series where active and benefit_mode in('games','choose') and game_plays=1),
   'active_campaigns',(select count(*) from public.campaigns where active and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>now())),
   'active_rewards',(select count(*) from public.rewards r where r.active and exists(select 1 from public.yt_pos_reward_rules b where b.reward_id=r.id and b.mode<>'disabled')),
   'unbound_rewards',(select count(*) from public.rewards r where r.active and not exists(select 1 from public.yt_pos_reward_rules b where b.reward_id=r.id and b.mode<>'disabled')),
   'active_banners',(select count(*) from public.yt_home_banners where enabled),
   'work_accounts',(select count(*) from public.work_accounts where active),
   'unclaimed_passes',(select count(*) from public.game_passes where status='issued' and expires_at>now()),
   'claimed_passes',(select count(*) from public.game_passes where status='claimed' and expires_at>now()),
   'open_game_sessions',(select count(*) from public.game_sessions where status='started' and started_at>=now()-interval '1 day'),
   'wallet_rewards',(select count(*) from public.user_rewards where status='available' and expires_at>now()),
   'expiring_rewards',(select count(*) from public.user_rewards where status='available' and expires_at>now() and expires_at<=now()+interval '7 days'),
   'active_offers',(select count(*) from public.reward_offers where active and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>now()) and (max_claims is null or claimed_count<max_claims)),
   'held_rewards',(select count(*) from public.yt_pos_reward_holds where state in('reserved','ready') and expires_at>now()),
   'low_stock_pool_entries',(select count(*) from public.reward_pool_entries p join public.campaigns c on c.id=p.campaign_id where c.active and p.weight>0 and p.max_total is not null and p.max_total-p.issued_total<=5)),
  'reward_activity',jsonb_build_object(
   'point_exchanges',(select count(*) from public.yt_point_shop_exchanges where created_at>=a and created_at<z),
   'issued',(select count(*) from public.user_rewards where created_at>=a and created_at<z),
   'redeemed',(select count(*) from public.redemptions where redeemed_at>=a and redeemed_at<z),
   'passes_claimed',(select count(*) from public.game_passes where claimed_at>=a and claimed_at<z),
   'games_completed',(select count(*) from public.game_sessions where status='completed' and completed_at>=a and completed_at<z),
   'points_earned',(select coalesce(sum(points),0) from public.yt_point_entries where direction='earn' and created_at>=a and created_at<z),
   'points_spent',(select coalesce(sum(points),0) from public.yt_point_entries where direction='spend' and created_at>=a and created_at<z)));
 result=result||jsonb_build_object(
  'months',coalesce((select jsonb_agg(to_jsonb(x) order by x.month) from(
   select to_char(business_day,'YYYY-MM') as month,count(distinct order_id) orders,sum(amount_rm) amount_rm
   from public.yt_pos_payment_entries where business_day between p_start and p_end group by 1) x),'[]'::jsonb),
  'cashiers',coalesce((select jsonb_agg(to_jsonb(x) order by x.amount_rm desc) from(
   select coalesce(w.username,'原工作账号') username,count(distinct e.order_id) orders,sum(e.amount_rm) amount_rm
   from public.yt_pos_payment_entries e left join public.work_accounts w on w.auth_user_id=e.actor_id
   where e.business_day between p_start and p_end group by w.username) x),'[]'::jsonb),
  'reward_types',coalesce((select jsonb_agg(to_jsonb(x) order by x.reward_name) from(
   select r.name reward_name,
    (select count(*) from public.user_rewards u where u.reward_id=r.id and u.created_at>=a and u.created_at<z) issued,
    (select count(*) from public.user_rewards u join public.redemptions d on d.user_reward_id=u.id where u.reward_id=r.id and d.redeemed_at>=a and d.redeemed_at<z) redeemed,
    (select count(*) from public.user_rewards u where u.reward_id=r.id and u.status='available' and u.expires_at>now()) outstanding,
    (select count(*) from public.user_rewards u where u.reward_id=r.id and u.status='available' and u.expires_at>now() and u.expires_at<=now()+interval '7 days') expiring
   from public.rewards r order by r.name,r.id limit 100) x),'[]'::jsonb));
 return result||jsonb_build_object('business_day',today);
end;$function$
;
