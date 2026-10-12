-- Lucky Box V1: additive GamePass mode and immutable order snapshots.
-- No existing data is deleted; existing GamePass remains the default mode.
create table public.yt_lucky_settings(
 id boolean primary key default true check(id),
 mode text not null default 'game' check(mode in ('game','lucky','off')),
 base_points_per_rm numeric(7,3) not null default 1.800 check(base_points_per_rm between 0.1 and 50),
 cap_points_per_rm numeric(7,3) not null default 5.000 check(cap_points_per_rm between 0.1 and 100),
 minimum_spend_rm numeric(9,2) not null default 15.00 check(minimum_spend_rm between 1 and 5000),
 claim_minutes integer not null default 20 check(claim_minutes between 3 and 120),
 weights integer[] not null default array[20,50,25,5] check(array_length(weights,1)=4),
 hidden_probabilities integer[] not null default array[1,2,3,5] check(array_length(hidden_probabilities,1)=4),
 version integer not null default 1,
 updated_at timestamptz not null default now(),
 updated_by uuid
);
insert into public.yt_lucky_settings(id,mode) values(true,'game') on conflict do nothing;
alter table public.yt_lucky_settings enable row level security;
revoke all on public.yt_lucky_settings from public,anon,authenticated;
alter table public.game_passes add column lucky_mode text not null default 'game' check(lucky_mode in ('game','lucky'));
alter table public.yt_pos_pass_bundles add column lucky_mode text not null default 'game' check(lucky_mode in ('game','lucky'));
create table public.yt_lucky_order_modes(
 order_id uuid primary key,
 mode text not null check(mode in ('game','lucky')),
 settings jsonb not null,
 created_at timestamptz not null default clock_timestamp()
);
create table public.yt_lucky_order_draws(
 order_id uuid primary key,
 eligible_total_rm numeric(12,2) not null,
 cap_points integer not null,
 hidden_item_id uuid,
 hidden_unit integer,
 created_at timestamptz not null default clock_timestamp()
);
create table public.yt_lucky_results(
 id uuid primary key default gen_random_uuid(),
 order_id uuid not null,
 pass_id uuid unique,
 bundle_id uuid unique,
 secret_hash text not null,
 points integer not null check(points between 0 and 1000000),
 grade text not null check(grade in ('ordinary','lucky','shining','gold','legendary')),
 box_amount_rm numeric(12,2) not null,
 revealed_at timestamptz not null default clock_timestamp(),
 claim_deadline timestamptz not null,
 claimed_at timestamptz,
 customer_id uuid,
 check((pass_id is not null) <> (bundle_id is not null)),
 check((claimed_at is null) = (customer_id is null))
);
create index yt_lucky_results_by_order on public.yt_lucky_results(order_id);
create unique index yt_lucky_results_unique_secret on public.yt_lucky_results(secret_hash);
alter table public.yt_lucky_order_modes enable row level security;
alter table public.yt_lucky_order_draws enable row level security;
alter table public.yt_lucky_results enable row level security;
revoke all on public.yt_lucky_order_modes, public.yt_lucky_order_draws, public.yt_lucky_results from public,anon,authenticated;

create function private.yt_lucky_current() returns jsonb
language sql stable security definer set search_path='' as $$
 select to_jsonb(s) from public.yt_lucky_settings s where id=true
$$;

create function private.yt_lucky_pass_stamp() returns trigger
language plpgsql security definer set search_path='' as $$
declare current_mode text; order_mode text;
begin
 select mode into current_mode from public.yt_lucky_settings where id=true;
 if tg_op='UPDATE' then
   if exists(select 1 from public.yt_lucky_results x where x.pass_id=old.id
     or (x.bundle_id is not null and exists(select 1 from public.yt_pos_pass_bundle_items z where z.bundle_id=x.bundle_id and z.pass_id=old.id)))
   then raise exception 'lucky_box_already_opened';end if;
   select om.mode into order_mode from public.yt_lucky_order_modes om
    join public.yt_member_order_items i on i.order_id=om.order_id
    join public.yt_pos_item_units u on u.order_item_id=i.id
    where u.game_pass_id=old.id limit 1;
 end if;
 if current_mode='off' then raise exception 'gamepass_mode_disabled';end if;
 if tg_op='INSERT' and current_mode='lucky' and coalesce(new.spend_ref,'') not like 'POS-%'
 then raise exception 'lucky_requires_paid_pos';end if;
 new.lucky_mode:=coalesce(order_mode,case when current_mode='lucky' then 'lucky' else 'game' end);
 return new;
end $$;
create trigger yt_lucky_pass_stamp before insert or update of claim_token_hash on public.game_passes
for each row execute function private.yt_lucky_pass_stamp();

create function private.yt_lucky_bundle_stamp() returns trigger
language plpgsql security definer set search_path='' as $$
declare current_mode text;found_mode text;
begin
 select mode into current_mode from public.yt_lucky_settings where id=true;
 if current_mode='off' then raise exception 'gamepass_mode_disabled';end if;
 insert into public.yt_lucky_order_modes(order_id,mode,settings)
 values(new.order_id,case when current_mode='lucky' then 'lucky' else 'game' end,private.yt_lucky_current())
 on conflict(order_id) do nothing;
 select mode into found_mode from public.yt_lucky_order_modes where order_id=new.order_id;
 new.lucky_mode:=found_mode;
 return new;
end $$;
create trigger yt_lucky_bundle_stamp before insert on public.yt_pos_pass_bundles
for each row execute function private.yt_lucky_bundle_stamp();

create function private.yt_lucky_capture_unit() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_order uuid;current_mode text;
begin
 if new.game_pass_id is null then return new;end if;
 select i.order_id into v_order from public.yt_member_order_items i where i.id=new.order_item_id;
 if v_order is null then return new;end if;
 select mode into current_mode from public.yt_lucky_settings where id=true;
 if current_mode='off' and not exists(select 1 from public.yt_lucky_order_modes where order_id=v_order)
 then raise exception 'gamepass_mode_disabled';end if;
 insert into public.yt_lucky_order_modes(order_id,mode,settings)
 values(v_order,case when current_mode='lucky' then 'lucky' else 'game' end,private.yt_lucky_current())
 on conflict(order_id) do nothing;
 update public.game_passes p set lucky_mode=m.mode from public.yt_lucky_order_modes m
 where p.id=new.game_pass_id and m.order_id=v_order and p.lucky_mode<>m.mode;
 return new;
end $$;
create trigger yt_lucky_capture_unit after insert or update of game_pass_id on public.yt_pos_item_units
for each row when (new.game_pass_id is not null) execute function private.yt_lucky_capture_unit();

create function private.yt_lucky_result_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if (new.status in ('expired','revoked') and old.status<>new.status
   or new.claim_token_hash is distinct from old.claim_token_hash)
 and exists(select 1 from public.yt_lucky_results x where x.pass_id=old.id
  or (x.bundle_id is not null and exists(select 1 from public.yt_pos_pass_bundle_items z where z.bundle_id=x.bundle_id and z.pass_id=old.id)))
 then raise exception 'lucky_box_already_opened';end if;
 return new;
end $$;
create trigger yt_lucky_result_guard before update of status,claim_token_hash on public.game_passes
for each row execute function private.yt_lucky_result_guard();
create function private.yt_lucky_bundle_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.status in ('revoked','expired') and new.status<>old.status and
 exists(select 1 from public.yt_lucky_results where bundle_id=old.id)
 then raise exception 'lucky_box_already_opened';end if;
 return new;
end $$;
create trigger yt_lucky_bundle_guard before update of status on public.yt_pos_pass_bundles
for each row execute function private.yt_lucky_bundle_guard();

create function private.yt_lucky_reset_settings() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 update public.yt_lucky_settings set mode='game',base_points_per_rm=1.8,cap_points_per_rm=5,
  minimum_spend_rm=15,claim_minutes=20,weights=array[20,50,25,5],
  hidden_probabilities=array[1,2,3,5],version=version+1,updated_at=now(),updated_by=null where id=true;
 return private.yt_lucky_current();
end $$;

-- Factory reset restores only the Lucky configuration. Historical Lucky result
-- records are not deleted by the Lucky subsystem reset.
create function private.yt_lucky_factory_restore() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state='committed' and old.state is distinct from new.state
  and new.scopes && array['records','campaigns']::text[]
 then perform private.yt_lucky_reset_settings();end if;
 return new;
end $$;
create trigger yt_lucky_factory_restore after update of state on private.yt_owner_reset_challenges
for each row execute function private.yt_lucky_factory_restore();
