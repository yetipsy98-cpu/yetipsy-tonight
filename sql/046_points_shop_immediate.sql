-- Point-shop presentation and redemption should be independent from next-day reward delivery.
-- Also repairs the authenticated wrapper -> private function call used by POS order creation.
alter table public.yt_point_shop_items
  add column if not exists description text;

alter table public.yt_point_shop_items
  drop constraint if exists yt_point_shop_items_description_check;

alter table public.yt_point_shop_items
  add constraint yt_point_shop_items_description_check
  check(description is null or char_length(description)<=500);

create or replace function private.yt_point_shop_list() returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();b bigint;items jsonb;begin
 if actor is null or not exists(select 1 from public.pin_accounts where auth_user_id=actor) or exists(select 1 from public.work_accounts where auth_user_id=actor) then raise exception 'customer_only';end if;
 perform pg_advisory_xact_lock(781943081);b:=private.yt_points_sync(actor);
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into items from (select i.id,r.name,coalesce(nullif(btrim(i.description),''),r.description) description,r.category,i.points_cost,case when i.stock_limit is null then null else greatest(0,i.stock_limit-i.stock_used) end stock_remaining,i.per_member_limit,(select count(*) from public.yt_point_shop_exchanges e where e.item_id=i.id and e.customer_id=actor) claimed_count,r.validity_days,false next_day_only,r.redeem_start_at,r.redeem_end_at,r.daily_start_local,r.daily_end_local,rule.min_paid_drinks,rule.min_spend_rm,rule.discount_type,rule.discount_value from public.yt_point_shop_items i join public.rewards r on r.id=i.reward_id join public.yt_pos_reward_rules rule on rule.reward_id=r.id where i.active and r.active and rule.mode in('product','series','any_drink') and (i.starts_at is null or i.starts_at<=clock_timestamp()) and (i.ends_at is null or i.ends_at>clock_timestamp()) and (r.redeem_end_at is null or r.redeem_end_at>clock_timestamp()) order by i.sort_order,i.id limit 100)x;
 return jsonb_build_object('balance',b,'items',items,'expiring_points',(select coalesce(sum(remaining_points),0) from public.yt_point_entries where customer_id=actor and direction='earn' and remaining_points>0 and expires_at<=clock_timestamp()+interval '7 days'));
end $$;

create or replace function private.yt_point_shop_exchange(p_item uuid,p_request uuid,p_expected_cost integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();i public.yt_point_shop_items%rowtype;r public.rewards%rowtype;old public.yt_point_shop_exchanges%rowtype;b bigint;need bigint;lot record;take bigint;award uuid;after_time timestamptz;expiry timestamptz;ex uuid;
begin
 if actor is null or not exists(select 1 from public.pin_accounts where auth_user_id=actor) or exists(select 1 from public.work_accounts where auth_user_id=actor) then raise exception 'customer_only';end if;
 if p_item is null or p_request is null then raise exception 'invalid_exchange';end if;
 perform pg_advisory_xact_lock(781943081);
 select * into old from public.yt_point_shop_exchanges where customer_id=actor and request_id=p_request;
 if found then if old.item_id<>p_item or old.points_cost is distinct from p_expected_cost then raise exception 'request_conflict';end if;return jsonb_build_object('id',old.id,'reward_id',old.user_reward_id,'points_cost',old.points_cost,'idempotent',true);end if;
 b:=private.yt_points_sync(actor);
 select * into i from public.yt_point_shop_items where id=p_item for update;
 if not found or not i.active or i.starts_at>clock_timestamp() or i.ends_at<=clock_timestamp() then raise exception 'shop_item_unavailable';end if;
 select * into r from public.rewards where id=i.reward_id for share;
 if not found or not r.active or r.redeem_end_at<=clock_timestamp() or not exists(select 1 from public.yt_pos_reward_rules where reward_id=r.id and mode in('product','series','any_drink')) then raise exception 'reward_not_pos_bound';end if;
 if i.stock_limit is not null and i.stock_used>=i.stock_limit then raise exception 'shop_sold_out';end if;
 if i.per_member_limit is not null and (select count(*) from public.yt_point_shop_exchanges where customer_id=actor and item_id=i.id)>=i.per_member_limit then raise exception 'shop_member_limit';end if;
 if p_expected_cost is distinct from i.points_cost then raise exception 'shop_price_changed';end if;
 if b<i.points_cost then raise exception 'points_insufficient';end if;
 need:=i.points_cost;
 for lot in select * from public.yt_point_entries where customer_id=actor and direction='earn' and remaining_points>0 and (expires_at is null or expires_at>clock_timestamp()) order by expires_at asc nulls last,created_at,id for update loop
  take:=least(need,lot.remaining_points);update public.yt_point_entries set remaining_points=remaining_points-take where id=lot.id;need:=need-take;exit when need=0;
 end loop;
 if need<>0 then raise exception 'points_ledger_mismatch';end if;
 after_time:=clock_timestamp();expiry:=after_time+make_interval(days=>r.validity_days);
 expiry:=least(expiry,coalesce(r.redeem_end_at,expiry));if expiry<=after_time then raise exception 'reward_no_valid_window';end if;
 insert into public.user_rewards(customer_id,reward_id,redeem_after,expires_at) values(actor,r.id,after_time,expiry) returning id into award;
 insert into public.yt_point_shop_exchanges(customer_id,item_id,request_id,user_reward_id,points_cost) values(actor,i.id,p_request,award,i.points_cost) returning id into ex;
 insert into public.yt_point_entries(customer_id,direction,points,reference,source) values(actor,'spend',i.points_cost,'SHOP:'||ex::text,'mall_exchange');
 update public.yt_point_wallets set balance=balance-i.points_cost,lifetime_spent=lifetime_spent+i.points_cost,updated_at=clock_timestamp() where customer_id=actor;
 update public.yt_point_shop_items set stock_used=stock_used+1 where id=i.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'points.exchange','point_shop_exchange',ex,jsonb_build_object('item',i.id,'points',i.points_cost,'award',award));
 return jsonb_build_object('id',ex,'reward_id',award,'points_cost',i.points_cost,'reward_name',r.name,'idempotent',false);
end $$;

create or replace function private.yt_owner_points_settings() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 return jsonb_build_object('actor_id',auth.uid(),'validity_days',(select points_validity_days from public.yt_loyalty_config where id=true),'games',(select jsonb_agg(jsonb_build_object('id',id,'slug',slug,'title',title,'mode',mode,'points_max',points_max,'perfect_ms',reaction_perfect_ms,'zero_ms',reaction_zero_ms) order by slug) from public.games where mode='skill'),'rewards',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'description',r.description,'points',r.points_equivalent,'bound',exists(select 1 from public.yt_pos_reward_rules where reward_id=r.id and mode in('product','series','any_drink'))) order by r.name) from public.rewards r where r.active),'[]'),'items',coalesce((select jsonb_agg(to_jsonb(i)||jsonb_build_object('name',r.name,'reward_description',r.description) order by i.sort_order,i.id) from public.yt_point_shop_items i join public.rewards r on r.id=i.reward_id),'[]'));
end $$;

create or replace function private.yt_owner_points_save(p_kind text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid;n integer;perfect integer;zero_ms integer;lim integer;old public.yt_point_shop_items%rowtype;prior jsonb;prior_id uuid;begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if jsonb_typeof(p_data) is distinct from 'object' then raise exception 'invalid_points_settings';end if;
 perform pg_advisory_xact_lock(781943081);
 target:=nullif(p_data->>'id','')::uuid;
 if p_kind='shop' then
  if p_data->>'request' is null then raise exception 'invalid_exchange';end if;
  perform (p_data->>'request')::uuid;
  select entity_id,metadata->'data' into prior_id,prior from public.audit_logs where actor_id=auth.uid() and action='points.owner_settings' and metadata->>'kind'='shop' and metadata#>>'{data,request}'=p_data->>'request';
  if found then if prior<>p_data then raise exception 'request_conflict';end if;return jsonb_build_object('ok',true,'id',prior_id,'idempotent',true);end if;
 end if;
 if p_kind='game' then
  n:=(p_data->>'points_max')::integer;perfect:=(p_data->>'perfect_ms')::integer;zero_ms:=(p_data->>'zero_ms')::integer;
  if n is null or n not between 1 and 1000000 or perfect is null or perfect not between 1 and 8999 or zero_ms is null or zero_ms not between perfect+1 and 9000 then raise exception 'invalid_points_settings';end if;
  update public.games set points_max=n,reaction_perfect_ms=perfect,reaction_zero_ms=zero_ms where id=target and mode='skill';if not found then raise exception 'game_not_supported';end if;
 elsif p_kind='reward' then
  n:=nullif(p_data->>'points','')::integer;if n is not null and n not between 1 and 1000000 then raise exception 'invalid_points_settings';end if;
  update public.rewards set points_equivalent=n where id=target;if not found then raise exception 'reward_missing';end if;
 elsif p_kind='expiry' then
  n:=(p_data->>'days')::integer;if n is null or n not between 0 and 3650 then raise exception 'invalid_points_settings';end if;
  update public.yt_loyalty_config set points_validity_days=n,updated_by=auth.uid(),updated_at=clock_timestamp() where id=true;
 elsif p_kind='shop' then
  n:=(p_data->>'cost')::integer;lim:=nullif(p_data->>'stock','')::integer;
  if n is null or n not between 1 and 1000000 or p_data->>'reward' is null or p_data->>'active' is null then raise exception 'invalid_points_settings';end if;
  if not exists(select 1 from public.rewards r join public.yt_pos_reward_rules q on q.reward_id=r.id where r.id=(p_data->>'reward')::uuid and r.active and q.mode in('product','series','any_drink')) then raise exception 'reward_not_pos_bound';end if;
  if target is not null then select * into old from public.yt_point_shop_items where id=target for update;if not found then raise exception 'shop_item_unavailable';end if;if lim is not null and lim<old.stock_used then raise exception 'stock_below_used';end if;end if;
  insert into public.yt_point_shop_items(id,reward_id,description,points_cost,active,stock_limit,per_member_limit,sort_order,starts_at,ends_at,updated_by) values(coalesce(target,gen_random_uuid()),(p_data->>'reward')::uuid,nullif(btrim(p_data->>'description'),''),n,(p_data->>'active')::boolean,lim,nullif(p_data->>'member_limit','')::integer,coalesce((p_data->>'sort')::integer,100),nullif(p_data->>'starts_at','')::timestamptz,nullif(p_data->>'ends_at','')::timestamptz,auth.uid()) on conflict(id) do update set reward_id=excluded.reward_id,description=excluded.description,points_cost=excluded.points_cost,active=excluded.active,stock_limit=excluded.stock_limit,per_member_limit=excluded.per_member_limit,sort_order=excluded.sort_order,starts_at=excluded.starts_at,ends_at=excluded.ends_at,updated_by=auth.uid(),updated_at=clock_timestamp() returning id into target;
 else raise exception 'invalid_points_settings';end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'points.owner_settings','points_settings',target,jsonb_build_object('kind',p_kind,'data',p_data));
 return jsonb_build_object('ok',true,'id',target);
end $$;

revoke all on function private.yt_point_shop_list(),private.yt_point_shop_exchange(uuid,uuid,integer),private.yt_owner_points_settings(),private.yt_owner_points_save(text,jsonb) from public,anon;
grant execute on function private.yt_point_shop_list(),private.yt_point_shop_exchange(uuid,uuid,integer),private.yt_owner_points_settings(),private.yt_owner_points_save(text,jsonb) to authenticated;

revoke all on function private.yt_pos_create_order_with_rewards_v2(uuid,text,text,jsonb,text,uuid,text) from public,anon;
grant execute on function private.yt_pos_create_order_with_rewards_v2(uuid,text,text,jsonb,text,uuid,text) to authenticated;
