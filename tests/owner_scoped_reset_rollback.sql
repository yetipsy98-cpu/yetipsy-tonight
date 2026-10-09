-- All reset validation is isolated in explicit BEGIN/ROLLBACK; API cleanup is mocked.
do $$
declare a uuid; c uuid; req uuid; sid text:=repeat('e',64); scope text; r jsonb;
 orders bigint; members bigint; products bigint; rewards bigint; team bigint; banners bigint; games bigint;
begin
 select auth_user_id into a from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 select count(*) into orders from public.yt_member_orders;select count(*) into members from public.pin_accounts;
 select count(*) into products from public.yt_shop_products;select count(*) into rewards from public.rewards;
 select count(*) into team from public.work_accounts;select count(*) into banners from public.yt_home_banners;select count(*) into games from public.games;
 if a is null then raise exception 'owner_missing';end if;
 if has_function_privilege('authenticated','public.yt_owner_reset_v8(uuid,text,text,uuid,uuid,bigint[],text[])','execute') or has_function_privilege('anon','public.yt_owner_reset_v8(uuid,text,text,uuid,uuid,bigint[],text[])','execute') then raise exception 'scoped_reset_exposed';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',a)::text,true);
 begin perform public.yt_owner_reset_v8(a,sid,'prepare',null,gen_random_uuid(),'{}',array['banners']);raise exception 'expected_failure';exception when others then if sqlerrm<>'owner_only' then raise;end if;end;
 perform set_config('request.jwt.claims','{"role":"service_role"}',true);
 begin perform public.yt_owner_reset_v8(a,sid,'prepare',null,gen_random_uuid(),'{}',array['invalid']);raise exception 'expected_failure';exception when others then if sqlerrm<>'invalid_reset_scope' then raise;end if;end;
 foreach scope in array array['banners','records','members','catalog','campaigns','team','all'] loop
  begin
   update public.reward_pool_entries set issued_total=1,issued_today=1,issued_day=current_date;
   req=gen_random_uuid();
   r=public.yt_owner_reset_v8(a,sid,'prepare',null,req,'{}',case when scope='all' then array['records','members','catalog','campaigns','team','banners'] else array[scope] end);c=(r->>'challenge')::uuid;
   if (select count(*) from public.yt_member_orders)<>orders then raise exception 'prepare_deleted_records';end if;
   if scope in ('members','catalog','campaigns','team') and not (r->'scopes'?'records') then raise exception 'dependency_missing';end if;
   begin perform public.yt_owner_reset_v8(a,sid,'prepare',null,req,'{}',array['banners','team']);raise exception 'expected_failure';exception when others then if sqlerrm<>'reset_scope_conflict' then raise;end if;end;
   begin perform public.yt_owner_reset_v8(a,repeat('f',64),'commit',c);raise exception 'expected_failure';exception when others then if sqlerrm<>'reset_confirmation_expired' then raise;end if;end;
   -- A forged extra scope on confirmation is ignored, never applied.
   r=public.yt_owner_reset_v8(a,sid,'commit',c,null,'{}',array['members','team','catalog','campaigns','banners']);
   if (select count(*) from public.games)<>games or not exists(select 1 from public.work_accounts where auth_user_id=a and role='owner') then raise exception 'owner_or_games_lost';end if;
   if scope='banners' then
    if exists(select 1 from public.yt_home_banners) or (select count(*) from public.yt_member_orders)<>orders or (select count(*) from public.pin_accounts)<>members or (select count(*) from public.rewards)<>rewards or (select count(*) from public.work_accounts)<>team then raise exception 'ads_only_deleted_other_data';end if;
    if exists(select 1 from private.yt_owner_reset_cleanup where challenge_id=c and kind='user') then raise exception 'ads_queued_accounts';end if;
   else
    if exists(select 1 from public.yt_member_orders) or exists(select 1 from public.game_passes) or exists(select 1 from public.user_rewards) or exists(select 1 from public.yt_point_wallets) then raise exception 'records_not_cleared';end if;
    if scope not in ('members','all') and (select count(*) from public.pin_accounts)<>members then raise exception 'members_not_preserved';end if;
    if scope not in ('catalog','all') and (select count(*) from public.yt_shop_products)<>products then raise exception 'catalog_not_preserved';end if;
    if scope not in ('campaigns','all') and (select count(*) from public.rewards)<>rewards then raise exception 'rewards_not_preserved';end if;
    if scope not in ('team','all') and (select count(*) from public.work_accounts)<>team then raise exception 'team_not_preserved';end if;
    if scope<>'all' and (select count(*) from public.yt_home_banners)<>banners then raise exception 'banners_not_preserved';end if;
   end if;
   if scope<>'banners' and exists(select 1 from public.reward_pool_entries where issued_total<>0 or issued_today<>0) then raise exception 'issuance_counters_not_reset';end if;
   if scope in ('members','all') and exists(select 1 from public.pin_accounts) then raise exception 'members_not_deleted';end if;
   if scope in ('catalog','all') and (exists(select 1 from public.yt_shop_products) or exists(select 1 from public.yt_pos_series)) then raise exception 'catalog_not_deleted';end if;
   if scope in ('team','all') and (select count(*) from public.work_accounts)<>1 then raise exception 'team_not_deleted';end if;
   if scope in ('campaigns','all') and (exists(select 1 from public.rewards) or (select count(*) from public.campaigns)<>1 or exists(select 1 from public.campaigns where active)) then raise exception 'campaign_defaults_wrong';end if;
   if exists(select 1 from private.yt_owner_reset_cleanup where challenge_id=c and target=a::text) then raise exception 'owner_queued';end if;
   r=public.yt_owner_reset_v8(a,repeat('f',64),'status');if (r->>'challenge')::uuid<>c or r->'scopes' is null then raise exception 'status_scope_missing';end if;
   loop r=public.yt_owner_reset_v8(a,sid,'batch',c);exit when (r->>'complete')::boolean;perform public.yt_owner_reset_v8(a,sid,'ack',c,null,array(select (x->>'id')::bigint from jsonb_array_elements(r->'batch') x));end loop;
   -- Retrying this commit must not delete a newly inserted menu item.
   insert into public.yt_shop_products(title,price_rm) values('scoped rollback sentinel',20);
   perform public.yt_owner_reset_v8(a,sid,'commit',c);
   if not exists(select 1 from public.yt_shop_products where title='scoped rollback sentinel') then raise exception 'retry_redeleted';end if;
   raise exception 'scope_validation_rollback';
  exception when others then if sqlerrm<>'scope_validation_rollback' then raise;end if;end;
 end loop;
end;$$;
