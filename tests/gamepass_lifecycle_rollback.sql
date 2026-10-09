BEGIN;
-- Fixture-only: must be run inside BEGIN / ROLLBACK.
do $$
declare owner_id uuid;staff_id uuid;member uuid;series uuid;product uuid;campaign uuid;campaign2 uuid;reward uuid;game uuid;o uuid;old_order uuid;item uuid;p uuid;p2 uuid;p3 uuid;session uuid;token uuid;oldtoken uuid;req uuid;bundle uuid;expiry timestamptz;r jsonb;rows jsonb;score numeric;started jsonb;count_before bigint;
begin
 select auth_user_id into owner_id from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 select auth_user_id into staff_id from public.work_accounts where role='cashier' and active and not must_change_password limit 1;
 select auth_user_id into member from public.pin_accounts where not exists(select 1 from public.work_accounts where auth_user_id=pin_accounts.auth_user_id) limit 1;
 if owner_id is null or staff_id is null or member is null then raise exception 'fixture_missing';end if;
 if has_function_privilege('anon','public.yt_pos_cancel_code(uuid,uuid,text,timestamptz)','execute') or has_function_privilege('anon','public.yt_game_checkpoint(uuid,text,integer,numeric)','execute') then raise exception 'writes_exposed';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 insert into public.yt_pos_series(name,benefit_mode,game_plays,active) values('rollback lifecycle','games',1,true) returning id into series;
 insert into public.yt_shop_products(title,price_rm,series_id,active) values('rollback lifecycle drink',20,series,true) returning id into product;
 insert into public.campaigns(name,active) values('rollback lifecycle',true) returning id into campaign;
 insert into public.campaigns(name,active) values('rollback default 2',true) returning id into campaign2;
 insert into public.campaign_games(campaign_id,game_id) select campaign,id from public.games where active;
 insert into public.campaign_games(campaign_id,game_id) select campaign2,id from public.games where active;
 insert into public.rewards(name,category,validity_days,active) values('rollback lifecycle prize','voucher',30,true) returning id into reward;
 insert into public.reward_pool_entries(campaign_id,game_id,result_key,reward_id,weight) select campaign,id,'R0',reward,1 from public.games where active;
 perform public.yt_owner_default_campaign(campaign);perform public.yt_owner_default_campaign(campaign2);
 if (select count(*) from public.campaigns where is_default)<>1 or not exists(select 1 from public.campaigns where id=campaign2 and is_default) then raise exception 'default_not_unique';end if;
 perform public.yt_owner_set_campaign(campaign2,false);if exists(select 1 from public.campaigns where id=campaign2 and is_default) then raise exception 'closed_default_retained';end if;
 insert into public.yt_member_orders(source,status,amount_rm,created_by) values('future_pos','fulfilled',80,owner_id) returning id into o;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) values(o,product,'lifecycle',4,20) returning id into item;
 insert into public.yt_pos_item_units(order_item_id,unit_number) select item,n from generate_series(1,4)n on conflict do nothing;
 update public.yt_member_orders set payment_status='paid',paid_at=now(),paid_by=owner_id,payment_method='cash' where id=o;
 insert into public.yt_member_orders(source,status,amount_rm,created_by,created_at) values('future_pos','fulfilled',20,owner_id,private.yt_business_start(private.yt_business_day(now()))-interval '1 second') returning id into old_order;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) values(old_order,product,'old lifecycle',1,20);
 update public.yt_member_orders set payment_status='paid',paid_at=now(),paid_by=owner_id,payment_method='cash' where id=old_order;
 r:=public.yt_pos_benefit_orders();if not exists(select 1 from jsonb_array_elements(r->'orders')x where x->>'id'=o::text) or exists(select 1 from jsonb_array_elements(r->'orders')x where x->>'id'=old_order::text) then raise exception 'business_day_options_wrong';end if;
 begin perform public.yt_pos_bundle_issue(old_order,campaign,gen_random_uuid(),gen_random_uuid());raise exception 'expected_failure';exception when others then if sqlerrm<>'benefits_current_day_only' then raise;end if;end;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 begin perform public.yt_owner_default_campaign(campaign);raise exception 'expected_failure';exception when others then if sqlerrm<>'owner_only' then raise;end if;end;
 token:=gen_random_uuid();req:=gen_random_uuid();select pass_id,expires_at into p,expiry from public.yt_pos_issue_unit_pass(o,item,1,campaign,token,req,60);
 if expiry<clock_timestamp()+interval '115 seconds' or expiry>clock_timestamp()+interval '120 seconds' then raise exception 'qr_must_be_2_minutes';end if;
 -- Cancelling before claim permits same-row reissue; stale QR can no longer claim.
 perform public.yt_pos_cancel_code(p,null,'reallocate',expiry);
 oldtoken:=token;token:=gen_random_uuid();select pass_id,expires_at into p2,expiry from public.yt_pos_issue_unit_pass(o,item,1,campaign,token,gen_random_uuid(),10);
 if p2<>p then raise exception 'cancel_reissued_duplicate_pass';end if;
 begin perform public.yt_pos_cancel_code(p,null,'stale cancellation',expiry-interval '1 second');raise exception 'expected_failure';exception when others then if sqlerrm<>'pass_changed_reload' then raise;end if;end;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
 begin perform public.yt_claim_pass(oldtoken);raise exception 'expected_failure';exception when others then if sqlerrm<>'pass_invalid_or_claimed' then raise;end if;end;
 if public.yt_claim_pass(token)<>p or public.yt_claim_pass(token)<>p then raise exception 'claim_retry_failed';end if;
 if (select expires_at-claimed_at from public.game_passes where id=p) not between interval '71 hours 59 minutes' and interval '72 hours 1 minute' then raise exception 'claim_must_be_72h';end if;
 if jsonb_array_length(public.yt_my_game_passes())<1 or exists(select 1 from public.game_sessions where pass_id=p) then raise exception 'claim_should_not_start_game';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 begin perform public.yt_pos_cancel_code(p,null,'after claim',expiry);raise exception 'expected_failure';exception when others then if sqlerrm not in('pass_already_claimed','pass_changed_reload') then raise;end if;end;
 begin perform public.yt_pos_issue_unit_pass(o,item,1,campaign,gen_random_uuid(),gen_random_uuid(),2);raise exception 'expected_failure';exception when others then if sqlerrm<>'unit_already_assigned' then raise;end if;end;
 r:=public.yt_pos_paid_units(o);if exists(select 1 from jsonb_array_elements(r->'units')x where (x->>'unit_number')::integer=1) then raise exception 'claimed_unit_not_removed';end if;
 -- Start draws once, another start returns the same session without inventory reroll.
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
 select id into game from public.games where slug='stop-the-bar';select to_jsonb(x) into started from public.yt_start_game(p,game)x;session:=(started->>'session_id')::uuid;
 select sum(issued_total) into count_before from public.reward_pool_entries where campaign_id=campaign;
 select to_jsonb(x) into r from public.yt_start_game(p,game)x;
 if r->>'status'<>'resumed' or r->>'session_id'<>session::text or (select sum(issued_total) from public.reward_pool_entries where campaign_id=campaign)<>count_before then raise exception 'resumed_game_rerolled';end if;
 perform public.yt_game_checkpoint(session,'begin',1);perform public.yt_game_checkpoint(session,'finish',1,100);perform public.yt_game_checkpoint(session,'finish',1,100);
 begin perform public.yt_game_checkpoint(session,'finish',1,99);raise exception 'expected_failure';exception when others then if sqlerrm<>'game_round_locked' then raise;end if;end;
 perform public.yt_game_checkpoint(session,'begin',2);r:=public.yt_game_checkpoint(session,'resume');
 if r->'rounds'<>'[100,0]'::jsonb then raise exception 'reload_did_not_preserve_attempts';end if;
 begin perform public.yt_game_checkpoint(session,'begin',1);raise exception 'expected_failure';exception when others then if sqlerrm<>'game_round_locked' then raise;end if;end;
 update public.game_sessions set started_at=now()-interval '5 seconds' where id=session;
 begin perform public.yt_game_result(session,100);raise exception 'expected_failure';exception when others then if sqlerrm<>'game_rounds_incomplete' then raise;end if;end;
 perform public.yt_game_checkpoint(session,'begin',3);perform public.yt_game_checkpoint(session,'finish',3,70);
 update public.game_sessions set started_at=now()-interval '5 seconds' where id=session;
 r:=public.yt_game_result(session,1);score:=(r->>'session_score')::numeric;if score<>100 then raise exception 'client_100_must_record_100';end if;
 perform public.yt_game_settle(session,'points');perform public.yt_game_settle(session,'points');if (select count(*) from public.yt_point_entries where game_pass_id=p and direction='earn')<>1 then raise exception 'game_paid_twice';end if;
 -- Whole-order cancellation cancels all constituent passes; reissue keeps their IDs.
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 token:=gen_random_uuid();r:=public.yt_pos_bundle_issue(o,campaign,token,gen_random_uuid(),60);bundle:=(r->>'id')::uuid;
 if (r->>'pass_count')::integer<>3 then raise exception 'bundle_should_exclude_claimed';end if;
 perform public.yt_pos_cancel_code(null,bundle,'before scan');oldtoken:=token;token:=gen_random_uuid();r:=public.yt_pos_bundle_issue(o,campaign,token,gen_random_uuid(),2);bundle:=(r->>'id')::uuid;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
 begin perform public.yt_pos_bundle_claim(oldtoken);raise exception 'expected_failure';exception when others then if sqlerrm<>'bundle_invalid_or_claimed' then raise;end if;end;
 r:=public.yt_pos_bundle_claim(token);if (r->>'count')::integer<>3 then raise exception 'bundle_claim_count_wrong';end if;
 rows:=public.yt_pos_bundle_claim(token);if jsonb_array_length(rows->'pass_ids')<>3 then raise exception 'bundle_retry_missing_passes';end if;
 select (r#>>'{pass_ids,0}')::uuid into p2;
 -- Fixed chance choice survives resume and cannot be replaced.
 select id into game from public.games where slug='mystery-card';select to_jsonb(x) into started from public.yt_start_game(p2,game)x;session:=(started->>'session_id')::uuid;
 perform public.yt_game_checkpoint(session,'pick',2);r:=public.yt_game_checkpoint(session,'resume');if r->>'choice'<>'2' then raise exception 'choice_lost';end if;
 begin perform public.yt_game_checkpoint(session,'pick',3);raise exception 'expected_failure';exception when others then if sqlerrm<>'game_choice_locked' then raise;end if;end;
 -- Expiry never frees the consumed POS entitlement or extends it on retry.
 update public.game_passes set expires_at=now()-interval '1 second' where id=p2;
 begin perform public.yt_start_game(p2,game);raise exception 'expected_failure';exception when others then if sqlerrm<>'pass_expired_or_used' then raise;end if;end;
 begin perform public.yt_game_settle(session,'reward');raise exception 'expected_failure';exception when others then if sqlerrm<>'pass_expired_or_used' then raise;end if;end;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 r:=public.yt_pos_benefit_orders();if exists(select 1 from jsonb_array_elements(r->'orders')x where x->>'id'=o::text) then raise exception 'all_claimed_order_not_removed';end if;
 begin perform public.yt_pos_cancel_code(null,bundle,'after claim');raise exception 'expected_failure';exception when others then if sqlerrm<>'pass_already_claimed' then raise;end if;end;
end $$;

ROLLBACK;
