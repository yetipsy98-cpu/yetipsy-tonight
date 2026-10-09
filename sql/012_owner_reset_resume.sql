create or replace function private.yt_owner_reset_v7(p_actor uuid,p_session text,p_action text,p_challenge uuid default null,p_request uuid default null,p_done bigint[] default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v private.yt_owner_reset_challenges%rowtype; n integer; c uuid; counts jsonb; batch jsonb;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'owner_only'; end if;
 if p_session is null or p_session !~ '^[0-9a-f]{64}$' then raise exception 'not_authenticated';end if;
 if not exists(select 1 from public.work_accounts a join public.staff_roles r on r.user_id=a.auth_user_id
  where a.auth_user_id=p_actor and a.role='owner' and a.active and not a.must_change_password and r.role='owner' and r.active)
 then raise exception 'owner_only';end if;
 if p_action='status' then
  select * into v from private.yt_owner_reset_challenges where actor_id=p_actor and state='committed' order by created_at desc limit 1;
  return jsonb_build_object('challenge',v.id);
 end if;
 if p_action='prepare' then
  if p_request is null then raise exception 'invalid_reset_request';end if;
  if exists(select 1 from private.yt_owner_reset_challenges where state='committed') then raise exception 'reset_cleanup_pending';end if;
  counts=jsonb_build_object('订单',(select count(*) from public.yt_member_orders),'会员',(select count(*) from public.pin_accounts),
   '钱包奖励',(select count(*) from public.user_rewards),'积分记录',(select count(*) from public.yt_point_entries),
   '商品',(select count(*) from public.yt_shop_products),'奖励种类',(select count(*) from public.rewards),
   '广告文件',(select count(*) from storage.objects where bucket_id='yetipsy-home-banners'),
   '其他账号',(select count(*) from auth.users where id<>p_actor));
  insert into private.yt_owner_reset_challenges(actor_id,session_key,request_id,counts)
   values(p_actor,p_session,p_request,counts) on conflict(actor_id,session_key,request_id) do nothing;
  select * into v from private.yt_owner_reset_challenges where actor_id=p_actor and session_key=p_session and request_id=p_request;
  if v.state<>'pending' or v.expires_at<=now() then raise exception 'reset_confirmation_expired';end if;
  return jsonb_build_object('challenge',v.id,'counts',v.counts,'expires_at',v.expires_at);
 end if;
 if p_action not in ('commit','batch','ack') or p_challenge is null then raise exception 'invalid_reset_request';end if;
 if p_action='commit' then perform pg_advisory_xact_lock(781943071);end if;
 select * into v from private.yt_owner_reset_challenges where id=p_challenge and actor_id=p_actor and (session_key=p_session or p_action in ('batch','ack')) for update;
 if not found then raise exception 'reset_confirmation_expired';end if;
 if p_action='commit' then
  if v.state in ('committed','complete') then return jsonb_build_object('challenge',v.id,'state',v.state);end if;
  if v.state<>'pending' or v.expires_at<=now() then raise exception 'reset_confirmation_expired';end if;
  if exists(select 1 from private.yt_owner_reset_challenges where state='committed' and id<>v.id) then raise exception 'reset_cleanup_pending';end if;
  -- Queue external cleanup before clearing application references. Never write auth/storage system tables.
  insert into private.yt_owner_reset_cleanup(challenge_id,kind,target)
   select v.id,'asset',name from storage.objects where bucket_id='yetipsy-home-banners';
  insert into private.yt_owner_reset_cleanup(challenge_id,kind,target)
   select v.id,'user',id::text from auth.users where id<>p_actor;
  -- Fixed application table list; intentionally no CASCADE beyond this reviewed scope.
  truncate table private.yt_offer_code_attempts,private.yt_offer_short_codes,private.yt_pos_draft_submissions,
   private.yt_redeem_code_attempts,private.yt_redeem_short_codes,
   public.audit_logs,public.campaign_games,public.campaigns,public.game_passes,public.game_sessions,
   public.idempotency_keys,public.member_details,public.pin_accounts,public.pin_auth_limits,public.pin_lookup_limits,
   public.pin_reset_tokens,public.redeem_tokens,public.redemptions,public.reward_offer_claims,public.reward_offers,
   public.reward_pool_entries,public.rewards,public.user_rewards,public.work_auth_limits,
   public.yt_game_best_records,public.yt_game_leaderboard_preferences,public.yt_home_banners,public.yt_integration_events,
   public.yt_loyalty_config,public.yt_member_enrollments,public.yt_member_order_items,public.yt_member_orders,
   public.yt_member_ref_codes,public.yt_point_entries,public.yt_point_tiers,public.yt_point_wallets,
   public.yt_pos_item_units,public.yt_pos_order_chits,public.yt_pos_order_events,public.yt_pos_pass_bundle_items,
   public.yt_pos_pass_bundles,public.yt_pos_preorder_holds,public.yt_pos_reward_holds,public.yt_pos_reward_rules,
   public.yt_pos_series,public.yt_promo_grants,public.yt_referral_links,public.yt_shop_products restart identity;
  delete from public.work_accounts where auth_user_id<>p_actor;
  update public.work_accounts set created_by=null,can_cashier=true,can_edit_orders=true,updated_at=now() where auth_user_id=p_actor;
  delete from public.staff_roles where user_id<>p_actor;
  delete from public.profiles where id<>p_actor;
  insert into public.yt_loyalty_config(id) values(true);
  insert into public.campaigns(name,active) values('默认活动',false) returning id into c;
  insert into public.campaign_games(campaign_id,game_id) select c,id from public.games where active;
  update private.yt_owner_reset_challenges set state='cancelled' where state='pending' and id<>v.id;
  update private.yt_owner_reset_challenges set state='committed' where id=v.id;
  return jsonb_build_object('challenge',v.id,'state','committed');
 end if;
 if v.state not in ('committed','complete') then raise exception 'reset_not_committed';end if;
 if p_action='ack' then
  if cardinality(p_done)>20 then raise exception 'invalid_reset_request';end if;
  update private.yt_owner_reset_cleanup set done=true where challenge_id=v.id and id=any(p_done);
 end if;
 select count(*) into n from private.yt_owner_reset_cleanup where challenge_id=v.id and not done;
 if n=0 then
  update private.yt_owner_reset_challenges set state='complete',completed_at=coalesce(completed_at,now()) where id=v.id;
  delete from private.yt_owner_reset_cleanup where challenge_id=v.id;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'kind',kind,'target',target) order by kind,id),'[]'::jsonb) into batch
  from(select id,kind,target from private.yt_owner_reset_cleanup where challenge_id=v.id and not done order by kind,id limit 20) q;
 return jsonb_build_object('challenge',v.id,'complete',n=0,'remaining',n,'batch',batch);
end;$$;
