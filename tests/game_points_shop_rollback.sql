BEGIN;
-- All fixtures and settings are rolled back, including wallet balances and stock.
do $$
declare owner_id uuid;staff_id uuid;member uuid;camp uuid;reward uuid;product uuid;series uuid;o uuid;item uuid;gp uuid;session uuid;game uuid;token uuid;req uuid;shop uuid;shop2 uuid;lot1 uuid;lot2 uuid;r jsonb;again jsonb;ids uuid[];before_count bigint;percent_test integer;ms numeric;
begin
 select auth_user_id into owner_id from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 select auth_user_id into staff_id from public.work_accounts where role='cashier' and active and not must_change_password limit 1;
 select auth_user_id into member from public.pin_accounts where not exists(select 1 from public.work_accounts where auth_user_id=pin_accounts.auth_user_id) limit 1;
 if owner_id is null or staff_id is null or member is null then raise exception 'fixture_missing';end if;
 if has_function_privilege('anon','public.yt_game_settle(uuid,text)','execute') or has_table_privilege('authenticated','public.yt_point_shop_items','UPDATE') then raise exception 'write_exposed';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 insert into public.yt_pos_series(name,benefit_mode,game_plays,active) values('rollback point shop','games',1,true) returning id into series;
 insert into public.yt_shop_products(title,price_rm,series_id,active) values('rollback points drink',20,series,true) returning id into product;
 insert into public.campaigns(name,active) values('rollback point settlement',true) returning id into camp;
 insert into public.campaign_games(campaign_id,game_id) select camp,id from public.games where active;
 insert into public.rewards(name,category,validity_days,next_day_only,active,points_equivalent) values('rollback mall reward','voucher',30,false,true,75) returning id into reward;
 insert into public.yt_pos_reward_rules(reward_id,mode,discount_type,discount_value,min_paid_drinks,min_spend_rm) values(reward,'any_drink','fixed',5,1,0);
 insert into public.reward_pool_entries(campaign_id,game_id,result_key,reward_id,weight) select camp,id,'R0',reward,1 from public.games where mode='chance' and active;
 insert into public.yt_member_orders(source,status,amount_rm,created_by) values('future_pos','fulfilled',60,owner_id) returning id into o;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) values(o,product,'points drink',3,20) returning id into item;
 insert into public.yt_pos_item_units(order_item_id,unit_number) select item,n from generate_series(1,3)n on conflict do nothing;
 update public.yt_member_orders set payment_status='paid',paid_at=now(),paid_by=owner_id,payment_method='cash' where id=o;
 token:=gen_random_uuid();r:=public.yt_pos_bundle_issue(o,camp,token,gen_random_uuid());
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
 r:=public.yt_pos_bundle_claim(token);select array_agg(value::uuid) into ids from jsonb_array_elements_text(r->'pass_ids');
 -- Chance: preparing reveals the fixed prize but issues nothing before final choice.
 select id into game from public.games where slug='moon-dice';select session_id into session from public.yt_start_game(ids[1],game);
 update public.game_sessions set started_at=now()-interval '3 seconds' where id=session;
 r:=public.yt_game_result(session,1);if r->>'reward_name'<>'rollback mall reward' or (r->>'points')::integer<>75 or exists(select 1 from public.user_rewards where session_id=session) then raise exception 'reward_issued_before_choice';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 perform public.yt_owner_points_save('reward',jsonb_build_object('id',reward,'points',99));
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
 r:=public.yt_game_settle(session,'points');again:=public.yt_game_settle(session,'points');if (r->>'points')::integer<>75 or not (again->>'idempotent')::boolean or exists(select 1 from public.user_rewards where session_id=session) then raise exception 'chance_points_not_atomic';end if;
 begin perform public.yt_game_settle(session,'reward');raise exception 'expected_failure';exception when others then if sqlerrm<>'game_settlement_locked' then raise;end if;end;
 begin perform public.yt_claim_random_points(ids[2]);raise exception 'expected_failure';exception when others then if sqlerrm<>'points_after_game_only' then raise;end if;end;
 -- Skill starts without a prize pool. Three saved attempts, 100% earns its frozen MAX.
 select id into game from public.games where slug='stop-the-bar';select session_id into session from public.yt_start_game(ids[2],game);
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 perform public.yt_owner_points_save('game',jsonb_build_object('id',game,'points_max',200,'perfect_ms',200,'zero_ms',1000));
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
 perform public.yt_game_checkpoint(session,'begin',1);perform public.yt_game_checkpoint(session,'finish',1,100);perform public.yt_game_checkpoint(session,'begin',2);perform public.yt_game_checkpoint(session,'finish',2,80);perform public.yt_game_checkpoint(session,'begin',3);perform public.yt_game_checkpoint(session,'finish',3,60);
 update public.game_sessions set started_at=now()-interval '3 seconds' where id=session;
 r:=public.yt_game_result(session,0);if (r->>'achievement_percent')::integer<>100 or (r->>'points')::integer<>100 or r->>'reward_name' is not null then raise exception 'perfect_must_earn_frozen_max';end if;
 perform public.yt_game_result(session,10);perform public.yt_game_settle(session,'points');
 begin perform public.yt_game_settle(session,'reward');raise exception 'expected_failure';exception when others then if sqlerrm<>'game_settlement_locked' then raise;end if;end;
 -- Reward final choice is irreversible, including after its award is stored.
 select id into game from public.games where slug='moon-dice';select session_id into session from public.yt_start_game(ids[3],game);update public.game_sessions set started_at=now()-interval '3 seconds' where id=session;
 perform public.yt_game_result(session,0);r:=public.yt_game_settle(session,'reward');if r->>'reward_id' is null then raise exception 'reward_not_stored';end if;
 begin perform public.yt_game_settle(session,'points');raise exception 'expected_failure';exception when others then if sqlerrm<>'game_settlement_locked' then raise;end if;end;
 -- Owner sets shop price/limits. Cashier and members cannot administer it.
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 again:=jsonb_build_object('request',gen_random_uuid(),'reward',reward,'cost',50,'active',true,'stock',2,'member_limit',1);r:=public.yt_owner_points_save('shop',again);shop:=(r->>'id')::uuid;r:=public.yt_owner_points_save('shop',again);if r->>'id'<>shop::text or not (r->>'idempotent')::boolean then raise exception 'owner_shop_retry_failed';end if;
 begin perform public.yt_owner_points_save('shop',again||jsonb_build_object('cost',51));raise exception 'expected_failure';exception when others then if sqlerrm<>'request_conflict' then raise;end if;end;
 r:=public.yt_owner_points_save('shop',jsonb_build_object('request',gen_random_uuid(),'reward',reward,'cost',20,'active',true,'stock',1));shop2:=(r->>'id')::uuid;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 begin perform public.yt_owner_points_settings();raise exception 'expected_failure';exception when others then if sqlerrm<>'owner_only' then raise;end if;end;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
 begin perform public.yt_owner_points_save('expiry','{"days":3}');raise exception 'expected_failure';exception when others then if sqlerrm<>'owner_only' then raise;end if;end;
 -- Expiry removes only unused points; FEFO consumes the soonest-expiring lot.
 insert into public.yt_point_entries(customer_id,direction,points,reference,remaining_points,expires_at) values(member,'earn',10,'rollback expired',10,now()-interval '1 minute') returning id into lot1;
 insert into public.yt_point_entries(customer_id,direction,points,reference,remaining_points,expires_at) values(member,'earn',30,'rollback soon',30,now()+interval '1 day') returning id into lot2;
 update public.yt_point_wallets set balance=balance+40,lifetime_earned=lifetime_earned+40 where customer_id=member;
 r:=public.yt_point_shop_list();if (r->>'balance')::integer<>205 or (select remaining_points from public.yt_point_entries where id=lot1)<>0 then raise exception 'expired_points_still_spendable';end if;
 begin perform public.yt_point_shop_exchange(shop,gen_random_uuid(),49);raise exception 'expected_failure';exception when others then if sqlerrm<>'shop_price_changed' then raise;end if;end;
 req:=gen_random_uuid();r:=public.yt_point_shop_exchange(shop,req,50);again:=public.yt_point_shop_exchange(shop,req,50);
 if r->>'id'<>again->>'id' or (select stock_used from public.yt_point_shop_items where id=shop)<>1 or (select remaining_points from public.yt_point_entries where id=lot2)<>0 then raise exception 'shop_retry_or_fefo_failed';end if;
 if not exists(select 1 from public.user_rewards where id=(r->>'reward_id')::uuid and reward_id=reward and session_id is null) then raise exception 'mall_not_usable_in_wallet';end if;
 begin perform public.yt_point_shop_exchange(shop2,req,20);raise exception 'expected_failure';exception when others then if sqlerrm<>'request_conflict' then raise;end if;end;
 begin perform public.yt_point_shop_exchange(shop,gen_random_uuid(),50);raise exception 'expected_failure';exception when others then if sqlerrm<>'shop_member_limit' then raise;end if;end;
 perform public.yt_point_shop_exchange(shop2,gen_random_uuid(),20);
 begin perform public.yt_point_shop_exchange(shop2,gen_random_uuid(),20);raise exception 'expected_failure';exception when others then if sqlerrm<>'shop_sold_out' then raise;end if;end;
 insert into public.yt_point_entries(customer_id,direction,points,reference,remaining_points) values(member,'earn',100,'rollback unrelated points',100);update public.yt_point_wallets set balance=balance+100,lifetime_earned=lifetime_earned+100 where customer_id=member;
 -- Spending game earnings prevents order edits from taking those same points again.
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 begin perform private.yt_pos_revoke_order_benefits(o);raise exception 'expected_failure';exception when others then if sqlerrm<>'game_points_already_used' then raise;end if;end;

 -- Reaction boundaries use the same canonical percentage that the customer displays.
 select id into game from public.games where slug='reaction-test';
 perform public.yt_owner_points_save('game',jsonb_build_object('id',game,'points_max',150,'perfect_ms',200,'zero_ms',1000));
 for percent_test in 0..2 loop
  ms:=case percent_test when 0 then 200 when 1 then 600 else null end;
  insert into public.game_passes(campaign_id,issued_by,customer_id,status,claimed_at,expires_at) values(camp,owner_id,member,'claimed',now(),now()+interval '72 hours') returning id into gp;
  perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
  select session_id into session from public.yt_start_game(gp,game);
  perform public.yt_game_checkpoint(session,'begin',1);perform public.yt_game_checkpoint(session,'finish',1,ms);perform public.yt_game_checkpoint(session,'begin',2);perform public.yt_game_checkpoint(session,'finish',2,ms);perform public.yt_game_checkpoint(session,'begin',3);perform public.yt_game_checkpoint(session,'finish',3,ms);
  update public.game_sessions set started_at=now()-interval '3 seconds' where id=session;r:=public.yt_game_result(session,9000);
  if (r->>'achievement_percent')::integer<>(case percent_test when 0 then 100 when 1 then 50 else 0 end) or (r->>'points')::integer<>(case percent_test when 0 then 150 when 1 then 75 else 0 end) then raise exception 'reaction_boundaries_wrong';end if;
  perform public.yt_game_settle(session,'points');
  perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 end loop;
 -- New exchange records participate in records-only reset; catalog settings remain.
 perform set_config('request.jwt.claims','{"role":"service_role"}',true);
 r:=public.yt_owner_reset_v8(owner_id,repeat('d',64),'prepare',null,gen_random_uuid(),'{}',array['records']);
 perform public.yt_owner_reset_v8(owner_id,repeat('d',64),'commit',(r->>'challenge')::uuid);
 if exists(select 1 from public.yt_point_shop_exchanges) or exists(select 1 from public.yt_point_entries) or not exists(select 1 from public.yt_point_shop_items where id=shop and stock_used=0 and active) then raise exception 'points_reset_did_not_preserve_settings';end if;
end $$;
ROLLBACK;
