-- Run only inside an explicit BEGIN/ROLLBACK. No Auth or Storage API mutations here.
do $$
declare a uuid; sid text:=repeat('a',64); c uuid; c2 uuid; expired uuid; r jsonb; before_orders bigint; before_games bigint; sentinel uuid; reward uuid; game uuid; campaign uuid; total integer;
begin
 select auth_user_id into a from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 if a is null then raise exception 'fixture_owner_missing';end if;
 select count(*) into before_orders from public.yt_member_orders;select count(*) into before_games from public.games;
 if has_function_privilege('anon','public.yt_owner_reset_v7(uuid,text,text,uuid,uuid,bigint[])','execute')
  or has_function_privilege('authenticated','public.yt_owner_reset_v7(uuid,text,text,uuid,uuid,bigint[])','execute')
  or has_table_privilege('authenticated','private.yt_owner_reset_challenges','select') then raise exception 'reset_exposed';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',a)::text,true);
 begin
  perform public.yt_owner_reset_v7(a,sid,'prepare',null,gen_random_uuid());raise exception 'test_expected_failure';
 exception when others then if sqlerrm<>'owner_only' then raise;end if;end;
 perform set_config('request.jwt.claims','{"role":"service_role"}',true);
 begin
  perform public.yt_owner_reset_v7(gen_random_uuid(),sid,'prepare',null,gen_random_uuid());raise exception 'test_expected_failure';
 exception when others then if sqlerrm<>'owner_only' then raise;end if;end;
 r=public.yt_owner_reset_v7(a,sid,'prepare',null,gen_random_uuid());expired=(r->>'challenge')::uuid;
 update private.yt_owner_reset_challenges set expires_at=now()-interval '1 second' where id=expired;
 begin
  perform public.yt_owner_reset_v7(a,sid,'commit',expired);raise exception 'test_expected_failure';
 exception when others then if sqlerrm<>'reset_confirmation_expired' then raise;end if;end;
 r=public.yt_owner_reset_v7(a,sid,'prepare',null,gen_random_uuid());c=(r->>'challenge')::uuid;
 r=public.yt_owner_reset_v7(a,sid,'prepare',null,gen_random_uuid());c2=(r->>'challenge')::uuid;
 begin
  perform public.yt_owner_reset_v7(a,repeat('b',64),'commit',c);raise exception 'test_expected_failure';
 exception when others then if sqlerrm<>'reset_confirmation_expired' then raise;end if;end;
 begin
  perform public.yt_owner_reset_v7(a,sid,'batch',c);raise exception 'test_expected_failure';
 exception when others then if sqlerrm<>'reset_not_committed' then raise;end if;end;
 if (select count(*) from public.yt_member_orders)<>before_orders then raise exception 'prepare_deleted_data';end if;
 r=public.yt_owner_reset_v7(a,sid,'commit',c);
 if (select count(*) from public.games)<>before_games or (select count(*) from public.work_accounts)<>1
  or not exists(select 1 from public.work_accounts where auth_user_id=a and role='owner') then raise exception 'owner_or_games_lost';end if;
 if exists(select 1 from public.yt_member_orders) or exists(select 1 from public.user_rewards) or exists(select 1 from public.pin_accounts)
  or exists(select 1 from public.yt_shop_products) or exists(select 1 from public.rewards) then raise exception 'reset_incomplete';end if;
 if (select count(*) from public.campaigns)<>1 or exists(select 1 from public.campaigns where active)
  or not exists(select 1 from public.yt_loyalty_config where id and not welcome_enabled and not referral_enabled and not points_enabled)
  then raise exception 'defaults_incorrect';end if;
 if exists(select 1 from private.yt_owner_reset_cleanup where challenge_id=c and kind='user' and target=a::text) then raise exception 'owner_queued_for_delete';end if;
 insert into public.yt_shop_products(title,category,price_rm) values('rollback sentinel','drinks',20) returning id into sentinel;
 perform public.yt_owner_reset_v7(a,sid,'commit',c);
 if not exists(select 1 from public.yt_shop_products where id=sentinel) then raise exception 'duplicate_commit_deleted_new_data';end if;
 begin
  perform public.yt_owner_reset_v7(a,sid,'commit',c2);raise exception 'test_expected_failure';
 exception when others then if sqlerrm<>'reset_confirmation_expired' then raise;end if;end;
 begin
  perform public.yt_owner_reset_v7(a,sid,'prepare',null,gen_random_uuid());raise exception 'test_expected_failure';
 exception when others then if sqlerrm<>'reset_cleanup_pending' then raise;end if;end;
 r=public.yt_owner_reset_v7(a,repeat('c',64),'status');if (r->>'challenge')::uuid<>c then raise exception 'cannot_resume_new_session';end if;
 perform public.yt_owner_reset_v7(a,repeat('c',64),'batch',c);
 -- Acknowledge mocks only; never call external cleanup during this rollback test.
 loop
  r=public.yt_owner_reset_v7(a,sid,'batch',c);exit when (r->>'complete')::boolean;
  r=public.yt_owner_reset_v7(a,sid,'ack',c,null,array(select (x->>'id')::bigint from jsonb_array_elements(r->'batch') x));
 end loop;
 if exists(select 1 from private.yt_owner_reset_cleanup where challenge_id=c) then raise exception 'cleanup_not_finished';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',a)::text,true);
 reward=public.yt_owner_create_bound_reward_v6(jsonb_build_object('name','rollback reward','description','rollback','category','voucher','validity_days',30,'next_day_only',false),jsonb_build_object('mode','any_drink','discount_type','fixed','discount_value',5,'min_paid_drinks',1,'min_spend_rm',0),gen_random_uuid());
 select id into campaign from public.campaigns limit 1;select id into game from public.games where active limit 1;
 perform public.yt_owner_add_pool_v7(campaign,game,'R0',reward);
 if not exists(select 1 from public.reward_pool_entries where reward_id=reward) then raise exception 'fresh_campaign_cannot_configure';end if;
end;$$;
