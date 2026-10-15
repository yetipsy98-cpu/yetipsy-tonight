-- Yetipsy Play V1: additive tables and RPCs. Apply after 099.
-- Public tables are private to RPCs; browser roles receive no direct table grants.
create table if not exists public.yt_play_upgrade_settings (
 id boolean primary key default true check(id),
 launch_at timestamptz not null default clock_timestamp(),
 invite_min_spend_rm numeric(10,2) check(invite_min_spend_rm >= 0),
 bell_enabled boolean not null default true,
 bell_lat double precision check(bell_lat between -90 and 90),
 bell_lng double precision check(bell_lng between -180 and 180),
 bell_radius_m integer not null default 100 check(bell_radius_m between 30 and 300),
 bell_remind_seconds integer not null default 30 check(bell_remind_seconds between 10 and 300),
 bell_complete_seconds integer not null default 60 check(bell_complete_seconds between 10 and 3600)
);
insert into public.yt_play_upgrade_settings(id) values(true) on conflict do nothing;
create table if not exists public.yt_play_member_tokens(
 token_hash text primary key, customer_id uuid not null references auth.users(id),
 expires_at timestamptz not null, issued_at timestamptz not null default clock_timestamp()
);
create table if not exists public.yt_play_order_tokens(
 token_hash text primary key, order_id uuid not null references public.yt_member_orders(id),
 expires_at timestamptz not null, issued_at timestamptz not null default clock_timestamp()
);
create table if not exists public.yt_play_invite_tokens(
 token_hash text primary key, inviter_customer_id uuid not null references auth.users(id),
 expires_at timestamptz not null, issued_at timestamptz not null default clock_timestamp()
);
create table if not exists public.yt_play_consumption_bindings(
 order_id uuid not null references public.yt_member_orders(id),
 customer_id uuid not null references auth.users(id),
 source text not null check(source in ('customer_order','pos_qr','member_qr','gamepass','lucky_box')),
 bound_at timestamptz not null default clock_timestamp(),
 primary key(order_id,customer_id)
);
create table if not exists public.yt_play_first_purchases(
 customer_id uuid primary key references auth.users(id),
 order_id uuid not null references public.yt_member_orders(id),
 paid_at timestamptz not null,
 recorded_at timestamptz not null default clock_timestamp()
);
create table if not exists public.yt_play_referral_events(
 invited_customer_id uuid primary key references auth.users(id),
 inviter_customer_id uuid not null references auth.users(id),
 first_order_id uuid not null references public.yt_member_orders(id),
 status text not null check(status in ('awarded','pending_reward','no_reward','reversal_requested','retained','reversed')),
 decided_by uuid references auth.users(id), decision_note text,
 decided_at timestamptz, created_at timestamptz not null default clock_timestamp()
);
create table if not exists public.yt_play_bell_types(
 id text primary key, label_zh text not null, label_en text not null,
 sort_order integer not null default 0, enabled boolean not null default true
);
insert into public.yt_play_bell_types(id,label_zh,label_en,sort_order) values
 ('staff','呼叫店员','Call staff',1),('ice','需要加冰','More ice',2),
 ('water','需要饮用水','Drinking water',3),('other','其他协助','Other help',4)
on conflict(id) do nothing;
create table if not exists public.yt_play_bell_requests(
 id uuid primary key default gen_random_uuid(),customer_id uuid not null references auth.users(id),
 table_label text not null, type_id text not null references public.yt_play_bell_types(id),
 note text not null default '' check(char_length(note)<=50),
 created_at timestamptz not null default clock_timestamp(),
 acknowledged_at timestamptz, acknowledged_by uuid references auth.users(id),
 constraint bell_ack_pair check((acknowledged_at is null)=(acknowledged_by is null))
);
create unique index if not exists yt_play_one_pending_bell on public.yt_play_bell_requests(customer_id)
 where acknowledged_at is null;
create index if not exists yt_play_bell_active on public.yt_play_bell_requests(created_at desc);
create index if not exists yt_play_member_tokens_customer on public.yt_play_member_tokens(customer_id);
create index if not exists yt_play_member_tokens_expiry on public.yt_play_member_tokens(expires_at);
create index if not exists yt_play_order_tokens_order on public.yt_play_order_tokens(order_id);
create index if not exists yt_play_order_tokens_expiry on public.yt_play_order_tokens(expires_at);
create index if not exists yt_play_invite_tokens_inviter on public.yt_play_invite_tokens(inviter_customer_id);
create index if not exists yt_play_invite_tokens_expiry on public.yt_play_invite_tokens(expires_at);
create index if not exists yt_play_bindings_customer on public.yt_play_consumption_bindings(customer_id);
create index if not exists yt_play_first_orders on public.yt_play_first_purchases(order_id);
create index if not exists yt_play_referrals_inviter on public.yt_play_referral_events(inviter_customer_id);
create index if not exists yt_play_referrals_order on public.yt_play_referral_events(first_order_id);
create index if not exists yt_play_bell_customer_history on public.yt_play_bell_requests(customer_id,created_at desc);
do $$ declare t text; begin
 foreach t in array array['yt_play_upgrade_settings','yt_play_member_tokens','yt_play_order_tokens','yt_play_invite_tokens',
 'yt_play_consumption_bindings','yt_play_first_purchases','yt_play_referral_events',
 'yt_play_bell_types','yt_play_bell_requests'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public, anon, authenticated',t);
 end loop;
end $$;

create or replace function private.yt_play_customer() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from public.pin_accounts where auth_user_id=auth.uid())
 and not exists(select 1 from public.work_accounts where auth_user_id=auth.uid())
$$;
create or replace function private.yt_play_hash(p_token uuid) returns text language sql immutable set search_path='' as $$
 select encode(sha256(convert_to(p_token::text,'UTF8')),'hex')
$$;
create or replace function private.yt_play_member_token() returns jsonb language plpgsql security definer set search_path='' as $$
declare v uuid:=gen_random_uuid(); begin
 if not private.yt_play_customer() then raise exception 'customer_only';end if;
 delete from public.yt_play_member_tokens where expires_at<clock_timestamp()-interval '1 day';
 insert into public.yt_play_member_tokens(token_hash,customer_id,expires_at)
 values(private.yt_play_hash(v),auth.uid(),clock_timestamp()+interval '60 seconds');
 return jsonb_build_object('token',v,'expires_at',clock_timestamp()+interval '60 seconds');
end $$;
create or replace function private.yt_play_order_token(p_order uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v uuid:=gen_random_uuid();begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 delete from public.yt_play_order_tokens where expires_at<clock_timestamp()-interval '1 day';
 if not exists(select 1 from public.yt_member_orders where id=p_order and source='future_pos'
 and status not in ('cancelled','rejected') and payment_status in ('unpaid','paid')) then raise exception 'order_not_found';end if;
 insert into public.yt_play_order_tokens(token_hash,order_id,expires_at)
 values(private.yt_play_hash(v),p_order,clock_timestamp()+interval '10 minutes');
 return jsonb_build_object('token',v,'expires_at',clock_timestamp()+interval '10 minutes');
end $$;
create or replace function private.yt_play_invite_token() returns jsonb language plpgsql security definer set search_path='' as $$
declare v uuid:=gen_random_uuid();v_code text;begin
 if not private.yt_play_customer() then raise exception 'customer_only';end if;
 delete from public.yt_play_invite_tokens where expires_at<clock_timestamp()-interval '1 day';
 select code into v_code from public.yt_member_ref_codes where customer_id=auth.uid();
 if v_code is null then raise exception 'invite_unavailable';end if;
 insert into public.yt_play_invite_tokens(token_hash,inviter_customer_id,expires_at)
 values(private.yt_play_hash(v),auth.uid(),clock_timestamp()+interval '30 days');
 return jsonb_build_object('token',v,'code',v_code);
end $$;
create or replace function private.yt_play_invite_token_check(p_token uuid,p_code text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.yt_play_invite_tokens t join public.yt_member_ref_codes c
 on c.customer_id=t.inviter_customer_id where t.token_hash=private.yt_play_hash(p_token)
 and t.expires_at>clock_timestamp() and c.code=upper(btrim(p_code)))
$$;
create or replace function private.yt_play_finalize_binding(p_order uuid,p_customer uuid,p_source text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.yt_member_orders%rowtype; cfg public.yt_play_upgrade_settings%rowtype;
 r public.yt_referral_links%rowtype; inserted integer; rewarded boolean:=false;v_pending boolean:=false;v_reward uuid;v_enabled boolean;
begin
 if p_customer is null or not exists(select 1 from public.pin_accounts where auth_user_id=p_customer)
 or exists(select 1 from public.work_accounts where auth_user_id=p_customer) then raise exception 'customer_only';end if;
 select * into o from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found or o.status in ('cancelled','rejected') or o.payment_status='refunded'
 or coalesce(o.cancel_after_refund,false) then raise exception 'order_not_eligible';end if;
 if o.payment_status='paid' and private.yt_business_day(o.paid_at)<>private.yt_business_day(clock_timestamp())
 and not exists(select 1 from public.yt_play_consumption_bindings where order_id=p_order and customer_id=p_customer)
 then
  if p_source not in ('gamepass','lucky_box') then raise exception 'binding_business_day_closed';end if;
  insert into public.yt_play_consumption_bindings(order_id,customer_id,source)
  values(p_order,p_customer,p_source) on conflict(order_id,customer_id) do nothing;
  return jsonb_build_object('bound',true,'valid_purchase',false);
 end if;
 insert into public.yt_play_consumption_bindings(order_id,customer_id,source)
 values(p_order,p_customer,p_source) on conflict(order_id,customer_id) do nothing;
 if o.payment_status<>'paid' or o.paid_at is null or coalesce(o.settlement_due_since is not null,false)
 then return jsonb_build_object('bound',true,'valid_purchase',false);end if;
 select * into cfg from public.yt_play_upgrade_settings where id=true;
 if o.amount_rm<=0
 then return jsonb_build_object('bound',true,'valid_purchase',false);end if;
 -- The first qualifying paid order is immutable even for members without an inviter.
 insert into public.yt_play_first_purchases(customer_id,order_id,paid_at)
 values(p_customer,p_order,o.paid_at) on conflict(customer_id) do nothing;
 get diagnostics inserted=row_count;
 if inserted=1 then
  select * into r from public.yt_referral_links where invited_customer_id=p_customer for update;
  if found and (cfg.invite_min_spend_rm is null or o.amount_rm>=cfg.invite_min_spend_rm)
     and r.invited_at>=cfg.launch_at and o.paid_at>=r.invited_at
     and o.paid_at<=r.invited_at+interval '168 hours'
     and exists(select 1 from public.yt_member_enrollments e where e.customer_id=p_customer
        and e.referred_code is not null and e.created_at>=cfg.launch_at)
  then
   select referral_enabled,inviter_reward_id into v_enabled,v_reward from public.yt_loyalty_config where id=true;
   if v_enabled and v_reward is not null then
    -- Existing promo engine remains the sole issuer; the unique grant prevents double awards.
    begin
     perform private.yt_referral_purchase_activated(p_customer);
     rewarded:=true;
    exception when others then
     v_pending:=true;
    end;
   end if;
   insert into public.yt_play_referral_events(invited_customer_id,inviter_customer_id,first_order_id,status)
   values(p_customer,r.inviter_customer_id,p_order,case when rewarded then 'awarded' when v_pending then 'pending_reward' else 'no_reward' end) on conflict do nothing;
  end if;
 end if;
 return jsonb_build_object('bound',true,'valid_purchase',true,'first_purchase',inserted=1,'referral_awarded',rewarded);
end $$;
create or replace function private.yt_play_referral_pending() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('customer_id',invited_customer_id,'order_id',first_order_id,
 'created_at',created_at) order by created_at desc),'[]'::jsonb)
 from public.yt_play_referral_events where status='pending_reward' and private.yt_work_owner()
$$;
create or replace function private.yt_play_referral_retry(p_customer uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e public.yt_play_referral_events%rowtype;begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select * into e from public.yt_play_referral_events where invited_customer_id=p_customer for update;
 if not found or e.status<>'pending_reward' then raise exception 'reward_not_pending';end if;
 perform private.yt_referral_purchase_activated(p_customer);
 if not exists(select 1 from public.yt_promo_grants g where g.kind='inviter'
 and g.customer_id=e.inviter_customer_id and g.source_customer_id=e.invited_customer_id)
 then raise exception 'reward_still_pending';end if;
 update public.yt_play_referral_events set status='awarded' where invited_customer_id=p_customer;
 return jsonb_build_object('status','awarded');
end $$;
-- Preserve the old referral rule for pre-launch memberships. New registrations earn
-- invite rewards only from the paid-order path above.
create or replace function private.yt_referral_sale_trigger() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.customer_id is not null and old.customer_id is distinct from new.customer_id
 and exists(select 1 from public.yt_referral_links l
  cross join public.yt_play_upgrade_settings s
  where l.invited_customer_id=new.customer_id and l.invited_at<s.launch_at)
 then perform private.yt_referral_purchase_activated(new.customer_id);end if;
 return new;
end $$;
create or replace function private.yt_play_paid_order_trigger() returns trigger language plpgsql security definer set search_path='' as $$
declare b record;begin
 if new.payment_status='paid' and old.payment_status is distinct from 'paid' then
  if new.customer_id is not null then perform private.yt_play_finalize_binding(new.id,new.customer_id,'customer_order');end if;
  for b in select customer_id from public.yt_play_consumption_bindings where order_id=new.id loop
   perform private.yt_play_finalize_binding(new.id,b.customer_id,'customer_order');
  end loop;
 end if;return new;
end $$;
drop trigger if exists yt_play_paid_order on public.yt_member_orders;
create trigger yt_play_paid_order after update of payment_status on public.yt_member_orders
for each row execute function private.yt_play_paid_order_trigger();
create or replace function private.yt_play_pass_claim_trigger() returns trigger language plpgsql security definer set search_path='' as $$
declare v_order uuid;begin
 if new.customer_id is null or old.customer_id is not distinct from new.customer_id then return new;end if;
 select i.order_id into v_order from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id
 where u.game_pass_id=new.id limit 1;
 if v_order is not null then perform private.yt_play_finalize_binding(v_order,new.customer_id,
  case when new.lucky_mode='lucky' then 'lucky_box' else 'gamepass' end);end if;
 return new;
end $$;
drop trigger if exists yt_play_pass_claim on public.game_passes;
create trigger yt_play_pass_claim after update of customer_id on public.game_passes
for each row execute function private.yt_play_pass_claim_trigger();
create or replace function private.yt_play_bind_member(p_order uuid,p_token uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_customer uuid;begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 select customer_id into v_customer from public.yt_play_member_tokens
 where token_hash=private.yt_play_hash(p_token) and expires_at>clock_timestamp();
 if v_customer is null then raise exception 'member_code_expired';end if;
 return private.yt_play_finalize_binding(p_order,v_customer,'member_qr');
end $$;
create or replace function private.yt_play_bind_order(p_token uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_order uuid;begin
 if not private.yt_play_customer() then raise exception 'customer_only';end if;
 select order_id into v_order from public.yt_play_order_tokens
 where token_hash=private.yt_play_hash(p_token) and expires_at>clock_timestamp();
 if v_order is null then raise exception 'order_code_expired';end if;
 return private.yt_play_finalize_binding(v_order,auth.uid(),'pos_qr');
end $$;
create or replace function private.yt_play_invites() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('nickname',p.display_name,
 'registered_at',l.invited_at,'expires_at',l.invited_at+interval '168 hours',
 'first_paid_at',f.paid_at,'rewarded',coalesce(l.inviter_bonus_processed,false),
 'reward_status',r.status) order by l.invited_at desc),'[]'::jsonb)
 from public.yt_referral_links l left join public.profiles p on p.id=l.invited_customer_id
 left join public.yt_play_first_purchases f on f.customer_id=l.invited_customer_id
 left join public.yt_play_referral_events r on r.invited_customer_id=l.invited_customer_id
 where l.inviter_customer_id=auth.uid() and private.yt_play_customer()
$$;

create or replace function private.yt_play_bell_call(p_table text,p_type text,p_note text,p_lat double precision,p_lng double precision)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.yt_play_upgrade_settings%rowtype;v_id uuid;v_distance double precision;begin
 if not private.yt_play_customer() then raise exception 'customer_only';end if;
 select * into s from public.yt_play_upgrade_settings where id=true;
 if s.bell_lat is null or s.bell_lng is null then raise exception 'bell_disabled';end if;
 if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180
 then raise exception 'location_required';end if;
 v_distance:=6371000*2*asin(sqrt(power(sin(radians(p_lat-s.bell_lat)/2),2)+
 cos(radians(s.bell_lat))*cos(radians(p_lat))*power(sin(radians(p_lng-s.bell_lng)/2),2)));
 if v_distance>s.bell_radius_m then raise exception 'outside_service_area';end if;
 if char_length(btrim(coalesce(p_table,''))) not between 1 and 32
 or not exists(select 1 from public.yt_play_bell_types where id=p_type and enabled)
 or char_length(coalesce(p_note,''))>50 then raise exception 'invalid_bell_request';end if;
 if exists(select 1 from public.yt_play_bell_requests where customer_id=auth.uid() and
 (acknowledged_at is null or acknowledged_at+make_interval(secs=>s.bell_complete_seconds)>clock_timestamp()))
 then raise exception 'bell_already_active';end if;
 insert into public.yt_play_bell_requests(customer_id,table_label,type_id,note)
 values(auth.uid(),btrim(p_table),p_type,coalesce(p_note,'')) returning id into v_id;
 return jsonb_build_object('id',v_id,'status','pending');
end $$;
create or replace function private.yt_play_bell_list() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare s public.yt_play_upgrade_settings%rowtype;v jsonb;begin
 select * into s from public.yt_play_upgrade_settings where id=true;
 if private.yt_pos_work_cashier() then
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'table',r.table_label,'type',r.type_id,
  'label_zh',t.label_zh,'label_en',t.label_en,'note',r.note,'created_at',r.created_at,
  'acknowledged_at',r.acknowledged_at,'status',case when r.acknowledged_at is null then 'pending'
  when r.acknowledged_at+make_interval(secs=>s.bell_complete_seconds)>clock_timestamp() then 'acknowledged' else 'completed' end)
  order by r.created_at desc),'[]'::jsonb) into v from public.yt_play_bell_requests r
  join public.yt_play_bell_types t on t.id=r.type_id
  where r.created_at>clock_timestamp()-interval '24 hours';
 elsif private.yt_play_customer() then
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'table',r.table_label,'type',r.type_id,
  'created_at',r.created_at,'status',case when r.acknowledged_at is null then 'pending'
  when r.acknowledged_at+make_interval(secs=>s.bell_complete_seconds)>clock_timestamp() then 'acknowledged' else 'completed' end)
  order by r.created_at desc),'[]'::jsonb) into v from public.yt_play_bell_requests r
  where r.customer_id=auth.uid() and r.created_at>clock_timestamp()-interval '24 hours';
 else raise exception 'not_authenticated';end if;
 return v;
end $$;
create or replace function private.yt_play_bell_config() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('enabled',s.bell_enabled,'bell_complete_seconds',s.bell_complete_seconds,'types',
   (select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'zh',t.label_zh,'en',t.label_en) order by t.sort_order),'[]'::jsonb)
    from public.yt_play_bell_types t where t.enabled))
 from public.yt_play_upgrade_settings s where s.id=true and private.yt_play_customer()
$$;
create or replace function private.yt_play_bell_staff_config() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('bell_remind_seconds',bell_remind_seconds,'bell_complete_seconds',bell_complete_seconds)
 from public.yt_play_upgrade_settings where id=true and private.yt_pos_work_cashier()
$$;
create or replace function private.yt_play_bell_history() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('table',q.table_label,'type',t.label_zh,
 'created_at',q.created_at,'acknowledged_at',q.acknowledged_at,'acknowledged_by',q.acknowledged_by)
 order by q.created_at desc),'[]'::jsonb)
 from (select * from public.yt_play_bell_requests order by created_at desc limit 200) q
 join public.yt_play_bell_types t on t.id=q.type_id where private.yt_work_owner()
$$;
create or replace function private.yt_play_bell_ack(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_play_bell_requests%rowtype;begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 update public.yt_play_bell_requests set acknowledged_at=clock_timestamp(),acknowledged_by=auth.uid()
 where id=p_id and acknowledged_at is null returning * into v;
 if not found then raise exception 'bell_already_acknowledged';end if;
 return jsonb_build_object('id',v.id,'status','acknowledged');
end $$;
create or replace function private.yt_play_bell_settings(p_data jsonb default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.yt_play_upgrade_settings%rowtype;begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_data is not null then
  update public.yt_play_upgrade_settings set
   invite_min_spend_rm=case when p_data ? 'invite_min_spend_rm' then nullif(p_data->>'invite_min_spend_rm','')::numeric else invite_min_spend_rm end,
   bell_enabled=true,
   bell_lat=case when p_data ? 'bell_lat' then (p_data->>'bell_lat')::double precision else bell_lat end,
   bell_lng=case when p_data ? 'bell_lng' then (p_data->>'bell_lng')::double precision else bell_lng end,
   bell_radius_m=coalesce((p_data->>'bell_radius_m')::integer,bell_radius_m),
   bell_remind_seconds=coalesce((p_data->>'bell_remind_seconds')::integer,bell_remind_seconds),
   bell_complete_seconds=coalesce((p_data->>'bell_complete_seconds')::integer,bell_complete_seconds)
  where id=true;
 end if;
 select * into s from public.yt_play_upgrade_settings where id=true;
 return to_jsonb(s)||jsonb_build_object('types',(select coalesce(jsonb_agg(to_jsonb(t) order by sort_order),'[]'::jsonb) from public.yt_play_bell_types t));
end $$;
create or replace function private.yt_play_bell_type_save(p_id text,p_zh text,p_en text,p_sort integer,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_id !~ '^[a-z0-9_]{1,32}$' or char_length(btrim(p_zh)) not between 1 and 50
 or char_length(btrim(p_en)) not between 1 and 50 then raise exception 'invalid_bell_type';end if;
 insert into public.yt_play_bell_types(id,label_zh,label_en,sort_order,enabled)
 values(p_id,btrim(p_zh),btrim(p_en),coalesce(p_sort,0),coalesce(p_enabled,true))
 on conflict(id) do update set label_zh=excluded.label_zh,label_en=excluded.label_en,
 sort_order=excluded.sort_order,enabled=excluded.enabled;
 return private.yt_play_bell_settings(null);
end $$;
create or replace function private.yt_play_refund_decide(p_order uuid,p_revoke boolean,p_note text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.yt_play_referral_events%rowtype;v_reward uuid;v_status text;begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if char_length(btrim(coalesce(p_note,'')))<2 then raise exception 'reason_required';end if;
 if not exists(select 1 from public.yt_pos_payment_entries where order_id=p_order and kind='refund')
 and not exists(select 1 from public.yt_member_orders where id=p_order and payment_status='refunded')
 then raise exception 'refund_not_recorded';end if;
 select * into e from public.yt_play_referral_events where first_order_id=p_order for update;
 if not found then return jsonb_build_object('status','no_invitation_reward');end if;
 if e.decided_at is not null then return jsonb_build_object('status',e.status,'idempotent',true);end if;
 if not p_revoke then v_status:='retained';
 else
  select g.user_reward_id into v_reward from public.yt_promo_grants g
   where g.kind='inviter' and g.customer_id=e.inviter_customer_id
   and g.source_customer_id=e.invited_customer_id order by g.granted_at desc limit 1;
  update public.user_rewards set status='revoked' where id=v_reward and status='available';
  v_status:=case when found then 'reversed' else 'reversal_requested' end;
 end if;
 update public.yt_play_referral_events set status=v_status,decided_by=auth.uid(),
 decision_note=btrim(p_note),decided_at=clock_timestamp() where invited_customer_id=e.invited_customer_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(auth.uid(),'play.invite_refund_decision','pos_order',p_order,jsonb_build_object('revoke',p_revoke,'status',v_status,'note',p_note));
 return jsonb_build_object('status',v_status);
end $$;
create or replace function private.yt_play_refund_pending() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('order_id',e.first_order_id,
 'customer_id',e.invited_customer_id,'status',e.status) order by e.created_at desc),'[]'::jsonb)
 from public.yt_play_referral_events e
 where private.yt_work_owner() and e.decided_at is null
 and (exists(select 1 from public.yt_pos_payment_entries p where p.order_id=e.first_order_id and p.kind='refund')
 or exists(select 1 from public.yt_member_orders o where o.id=e.first_order_id and o.payment_status='refunded'))
$$;

create or replace function public.yt_play_member_token() returns jsonb language sql set search_path='' as $$select private.yt_play_member_token()$$;
create or replace function public.yt_play_invite_token() returns jsonb language sql set search_path='' as $$select private.yt_play_invite_token()$$;
create or replace function public.yt_play_invite_token_check(p_token uuid,p_code text) returns boolean language sql set search_path='' as $$select private.yt_play_invite_token_check(p_token,p_code)$$;
create or replace function public.yt_play_order_token(p_order uuid) returns jsonb language sql set search_path='' as $$select private.yt_play_order_token(p_order)$$;
create or replace function public.yt_play_bind_member(p_order uuid,p_token uuid) returns jsonb language sql set search_path='' as $$select private.yt_play_bind_member(p_order,p_token)$$;
create or replace function public.yt_play_bind_order(p_token uuid) returns jsonb language sql set search_path='' as $$select private.yt_play_bind_order(p_token)$$;
create or replace function public.yt_play_invites() returns jsonb language sql set search_path='' as $$select private.yt_play_invites()$$;
create or replace function public.yt_play_referral_pending() returns jsonb language sql set search_path='' as $$select private.yt_play_referral_pending()$$;
create or replace function public.yt_play_referral_retry(p_customer uuid) returns jsonb language sql set search_path='' as $$select private.yt_play_referral_retry(p_customer)$$;
create or replace function public.yt_play_bell_call(p_table text,p_type text,p_note text,p_lat double precision,p_lng double precision) returns jsonb language sql set search_path='' as $$select private.yt_play_bell_call(p_table,p_type,p_note,p_lat,p_lng)$$;
create or replace function public.yt_play_bell_list() returns jsonb language sql set search_path='' as $$select private.yt_play_bell_list()$$;
create or replace function public.yt_play_bell_config() returns jsonb language sql set search_path='' as $$select private.yt_play_bell_config()$$;
create or replace function public.yt_play_bell_staff_config() returns jsonb language sql set search_path='' as $$select private.yt_play_bell_staff_config()$$;
create or replace function public.yt_play_bell_history() returns jsonb language sql set search_path='' as $$select private.yt_play_bell_history()$$;
create or replace function public.yt_play_bell_ack(p_id uuid) returns jsonb language sql set search_path='' as $$select private.yt_play_bell_ack(p_id)$$;
create or replace function public.yt_play_bell_settings(p_data jsonb default null) returns jsonb language sql set search_path='' as $$select private.yt_play_bell_settings(p_data)$$;
create or replace function public.yt_play_bell_type_save(p_id text,p_zh text,p_en text,p_sort integer,p_enabled boolean) returns jsonb language sql set search_path='' as $$select private.yt_play_bell_type_save(p_id,p_zh,p_en,p_sort,p_enabled)$$;
create or replace function public.yt_play_refund_decide(p_order uuid,p_revoke boolean,p_note text) returns jsonb language sql set search_path='' as $$select private.yt_play_refund_decide(p_order,p_revoke,p_note)$$;
create or replace function public.yt_play_refund_pending() returns jsonb language sql set search_path='' as $$select private.yt_play_refund_pending()$$;
grant execute on function public.yt_play_member_token(),public.yt_play_invite_token(),public.yt_play_order_token(uuid),public.yt_play_bind_member(uuid,uuid),
 public.yt_play_bind_order(uuid),public.yt_play_invites(),public.yt_play_referral_pending(),public.yt_play_referral_retry(uuid),public.yt_play_bell_call(text,text,text,double precision,double precision),
 public.yt_play_bell_list(),public.yt_play_bell_config(),public.yt_play_bell_staff_config(),public.yt_play_bell_history(),public.yt_play_bell_ack(uuid),public.yt_play_bell_settings(jsonb),
 public.yt_play_bell_type_save(text,text,text,integer,boolean),public.yt_play_refund_decide(uuid,boolean,text),public.yt_play_refund_pending() to authenticated;
revoke all on function public.yt_play_invite_token_check(uuid,text) from public,anon,authenticated;
grant execute on function public.yt_play_invite_token_check(uuid,text) to service_role;
