-- Game settlement snapshots and a points shop. No random points without playing.
alter table public.games add column points_max integer not null default 100 check(points_max between 1 and 1000000), add column reaction_perfect_ms integer not null default 200 check(reaction_perfect_ms between 1 and 8999), add column reaction_zero_ms integer not null default 1000 check(reaction_zero_ms between 2 and 9000), add constraint yt_reaction_thresholds check(reaction_zero_ms>reaction_perfect_ms);
alter table public.rewards add column points_equivalent integer check(points_equivalent between 1 and 1000000);
alter table public.yt_loyalty_config add column points_validity_days integer not null default 365 check(points_validity_days between 0 and 3650);
alter table public.game_sessions add column points_max_snapshot integer, add column points_equivalent_snapshot integer, add column reaction_perfect_snapshot integer, add column reaction_zero_snapshot integer, add column achievement_percent integer check(achievement_percent between 0 and 100), add column points_awarded integer, add column settlement_choice text check(settlement_choice in('reward','points')), add column points_validity_snapshot integer;
alter table public.yt_point_entries add column expires_at timestamptz,add column remaining_points bigint not null default 0 check(remaining_points>=0 and remaining_points<=points),add column source text;
-- No existing points have been spent yet. Preserve any imported wallet balance by allocating it to its original earned entries.
with lots as(select e.id,e.points,w.balance,coalesce(sum(e.points) over(partition by e.customer_id order by e.created_at desc,e.id desc rows between unbounded preceding and 1 preceding),0) prior from public.yt_point_entries e join public.yt_point_wallets w on w.customer_id=e.customer_id where e.direction='earn') update public.yt_point_entries e set remaining_points=greatest(0,least(l.points,l.balance-l.prior)) from lots l where l.id=e.id;
create index yt_point_remaining_idx on public.yt_point_entries(customer_id,expires_at,created_at,id) where direction='earn' and remaining_points>0;
create table public.yt_point_shop_items(id uuid primary key default gen_random_uuid(),reward_id uuid not null references public.rewards(id),points_cost integer not null check(points_cost between 1 and 1000000),active boolean not null default false,stock_limit integer check(stock_limit>=0),stock_used integer not null default 0 check(stock_used>=0),per_member_limit integer check(per_member_limit>0),sort_order integer not null default 100 check(sort_order between 0 and 100000),starts_at timestamptz,ends_at timestamptz,updated_at timestamptz not null default now(),updated_by uuid references auth.users(id) on delete set null,check(ends_at is null or starts_at is null or ends_at>starts_at));
create index yt_point_shop_reward_idx on public.yt_point_shop_items(reward_id);
create table public.yt_point_shop_exchanges(id uuid primary key default gen_random_uuid(),customer_id uuid not null references public.pin_accounts(auth_user_id) on delete cascade,item_id uuid not null references public.yt_point_shop_items(id),request_id uuid not null,user_reward_id uuid not null references public.user_rewards(id),points_cost integer not null check(points_cost>0),created_at timestamptz not null default now(),unique(customer_id,request_id));
create index yt_point_exchange_item_idx on public.yt_point_shop_exchanges(item_id,customer_id);
create index yt_point_exchange_award_idx on public.yt_point_shop_exchanges(user_reward_id);
alter table public.yt_point_shop_items enable row level security;
alter table public.yt_point_shop_exchanges enable row level security;
revoke all on public.yt_point_shop_items,public.yt_point_shop_exchanges from anon,authenticated;
create or replace function private.yt_points_sync(p_customer uuid) returns bigint language plpgsql security definer set search_path='' as $$
declare e record;b bigint;begin
 if p_customer is null then raise exception 'customer_only';end if;
 insert into public.yt_point_wallets(customer_id) values(p_customer) on conflict do nothing;
 select balance into b from public.yt_point_wallets where customer_id=p_customer for update;
 for e in select * from public.yt_point_entries where customer_id=p_customer and direction='earn' and remaining_points>0 and expires_at<=clock_timestamp() order by expires_at,id for update loop
  if b<e.remaining_points then raise exception 'points_ledger_mismatch';end if;
  b:=b-e.remaining_points;
  insert into public.yt_point_entries(customer_id,direction,points,reference,source) values(p_customer,'adjust',e.remaining_points,'EXPIRY:'||e.id::text,'expiry');
  update public.yt_point_entries set remaining_points=0 where id=e.id;
 end loop;
 update public.yt_point_wallets set balance=b,updated_at=clock_timestamp() where customer_id=p_customer;
 return b;
end $$;
revoke all on function private.yt_points_sync(uuid) from public,anon,authenticated;
create unique index yt_points_owner_shop_request_idx on public.audit_logs(actor_id,(metadata#>>'{data,request}')) where action='points.owner_settings' and metadata->>'kind'='shop';
