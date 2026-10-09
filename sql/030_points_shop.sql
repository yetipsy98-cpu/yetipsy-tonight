create or replace function private.yt_point_shop_list() returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();b bigint;items jsonb;begin
 if actor is null or not exists(select 1 from public.pin_accounts where auth_user_id=actor) or exists(select 1 from public.work_accounts where auth_user_id=actor) then raise exception 'customer_only';end if;
 perform pg_advisory_xact_lock(781943081);b:=private.yt_points_sync(actor);
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into items from (select i.id,r.name,r.description,r.category,i.points_cost,case when i.stock_limit is null then null else greatest(0,i.stock_limit-i.stock_used) end stock_remaining,i.per_member_limit,(select count(*) from public.yt_point_shop_exchanges e where e.item_id=i.id and e.customer_id=actor) claimed_count,r.validity_days,r.next_day_only,r.redeem_start_at,r.redeem_end_at,r.daily_start_local,r.daily_end_local,rule.min_paid_drinks,rule.min_spend_rm,rule.discount_type,rule.discount_value from public.yt_point_shop_items i join public.rewards r on r.id=i.reward_id join public.yt_pos_reward_rules rule on rule.reward_id=r.id where i.active and r.active and rule.mode in('product','series','any_drink') and (i.starts_at is null or i.starts_at<=clock_timestamp()) and (i.ends_at is null or i.ends_at>clock_timestamp()) and (r.redeem_end_at is null or r.redeem_end_at>clock_timestamp()) order by i.sort_order,i.id limit 100)x;
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
 after_time:=case when r.next_day_only then (((clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date+1)::timestamp at time zone 'Asia/Kuala_Lumpur') else clock_timestamp() end;expiry:=clock_timestamp()+make_interval(days=>r.validity_days);
 after_time:=greatest(after_time,coalesce(r.redeem_start_at,after_time));expiry:=least(expiry,coalesce(r.redeem_end_at,expiry));if expiry<=after_time then raise exception 'reward_no_valid_window';end if;
 insert into public.user_rewards(customer_id,reward_id,redeem_after,expires_at) values(actor,r.id,after_time,expiry) returning id into award;
 insert into public.yt_point_shop_exchanges(customer_id,item_id,request_id,user_reward_id,points_cost) values(actor,i.id,p_request,award,i.points_cost) returning id into ex;
 insert into public.yt_point_entries(customer_id,direction,points,reference,source) values(actor,'spend',i.points_cost,'SHOP:'||ex::text,'mall_exchange');
 update public.yt_point_wallets set balance=balance-i.points_cost,lifetime_spent=lifetime_spent+i.points_cost,updated_at=clock_timestamp() where customer_id=actor;
 update public.yt_point_shop_items set stock_used=stock_used+1 where id=i.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'points.exchange','point_shop_exchange',ex,jsonb_build_object('item',i.id,'points',i.points_cost,'award',award));
 return jsonb_build_object('id',ex,'reward_id',award,'points_cost',i.points_cost,'reward_name',r.name,'idempotent',false);
end $$;
create or replace function public.yt_point_shop_list() returns jsonb language sql security invoker set search_path='' as $$select private.yt_point_shop_list()$$;
create or replace function public.yt_point_shop_exchange(p_item uuid,p_request uuid,p_expected_cost integer) returns jsonb language sql security invoker set search_path='' as $$select private.yt_point_shop_exchange(p_item,p_request,p_expected_cost)$$;
revoke all on function private.yt_point_shop_list(),public.yt_point_shop_list(),private.yt_point_shop_exchange(uuid,uuid,integer),public.yt_point_shop_exchange(uuid,uuid,integer) from public,anon;
grant execute on function private.yt_point_shop_list(),public.yt_point_shop_list(),private.yt_point_shop_exchange(uuid,uuid,integer),public.yt_point_shop_exchange(uuid,uuid,integer) to authenticated;
