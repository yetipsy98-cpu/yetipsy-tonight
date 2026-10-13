-- Lucky Box V2 promotion: additive POS QR path, audited wallet, no old Game Mode changes.
-- Current Gift QR/secret flow unchanged. Stored order snapshots are retained.
alter table public.yt_lucky_settings alter column base_points_per_rm set default 3.500;
alter table public.yt_lucky_settings alter column cap_points_per_rm set default 10.000;
alter table public.yt_lucky_settings alter column weights set default array[15,55,25,5];
alter table public.yt_lucky_settings add column if not exists daily_budget_rm numeric(10,2) check(daily_budget_rm is null or daily_budget_rm between 1 and 100000);
create table if not exists public.yt_lucky_day_reservations(
 order_id uuid primary key references public.yt_member_orders(id),
 business_day date not null,
 eligible_rm numeric(12,2) not null check(eligible_rm>=0),
 reserved_points integer not null check(reserved_points>=0),
 created_at timestamptz not null default clock_timestamp()
);
create index if not exists yt_lucky_day_reservations_day on public.yt_lucky_day_reservations(business_day);
alter table public.yt_lucky_day_reservations enable row level security;
revoke all on public.yt_lucky_day_reservations from public,anon,authenticated;
-- Do not change the existing mode; Owner already enabled LUCKY.
update public.yt_lucky_settings set base_points_per_rm=3.5,cap_points_per_rm=10,
 weights=array[15,55,25,5],hidden_probabilities=array[1,2,3,5],
 version=version+1,updated_at=clock_timestamp()
where id=true;
CREATE OR REPLACE FUNCTION private.yt_lucky_reveal(p_token uuid, p_kind text, p_secret uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare h text;secret_h text; v_ref uuid;v_pass uuid;v_order uuid;v_mode text;v_status text;v_exp timestamptz;
 v_order_row public.yt_member_orders%rowtype;v_result public.yt_lucky_results%rowtype;
 v_order_mode public.yt_lucky_order_modes%rowtype;v_draw public.yt_lucky_order_draws%rowtype;
 v_gross numeric:=0;v_eligible_gross numeric:=0;v_fraction numeric:=0;v_total numeric:=0;v_box_gross numeric:=0;v_box_amount numeric:=0;
 v_pick numeric;v_rnd numeric;v_chance integer;v_w integer[];v_h integer[];v_base numeric;v_cap numeric;v_min numeric;v_claim_minutes integer;
 v_pts integer;v_box_cap integer;v_grade text;v_legendary boolean:=false;v_hidden_item uuid;v_hidden_unit int;
 v_unit record;v_first uuid;
begin
 if p_token is null or p_secret is null or p_kind not in ('claim','bundle') then raise exception 'invalid_lucky_code';end if;
 perform pg_advisory_xact_lock(781943081);
 h:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 secret_h:=encode(sha256(convert_to(p_secret::text,'UTF8')),'hex');
 if p_kind='claim' then
  select id,lucky_mode,status,expires_at into v_ref,v_mode,v_status,v_exp from public.game_passes where claim_token_hash=h for update;
  select i.order_id into v_order from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id where u.game_pass_id=v_ref;
 else
  select id,lucky_mode,status,expires_at,order_id into v_ref,v_mode,v_status,v_exp,v_order from public.yt_pos_pass_bundles where token_hash=h for update;
 end if;
 if v_ref is null or v_mode<>'lucky' or v_order is null then raise exception 'invalid_lucky_code';end if;
 select * into v_result from public.yt_lucky_results
 where (p_kind='claim' and pass_id=v_ref) or (p_kind='bundle' and bundle_id=v_ref) for update;
 if found then
  if v_result.secret_hash<>secret_h then raise exception 'lucky_already_opened';end if;
  return jsonb_build_object('id',v_result.id,'points',v_result.points,'grade',v_result.grade,'amount_rm',v_result.box_amount_rm,
   'claim_deadline',v_result.claim_deadline,'claimed',v_result.claimed_at is not null,'idempotent',true);
 end if;
 if v_status<>'issued' or v_exp<=clock_timestamp() then raise exception 'lucky_code_expired';end if;
 select * into v_order_row from public.yt_member_orders where id=v_order and source='future_pos' for update;
 if not found or v_order_row.payment_status<>'paid' or v_order_row.status<>'fulfilled' or v_order_row.cancel_after_refund
  or v_order_row.settlement_due_since is not null then raise exception 'lucky_order_not_eligible';end if;
 select * into v_order_mode from public.yt_lucky_order_modes where order_id=v_order;
 if not found or v_order_mode.mode<>'lucky' then raise exception 'lucky_mode_mismatch';end if;
 v_base:=(v_order_mode.settings->>'base_points_per_rm')::numeric;
 v_cap:=(v_order_mode.settings->>'cap_points_per_rm')::numeric;
 v_min:=(v_order_mode.settings->>'minimum_spend_rm')::numeric;
 v_claim_minutes:=(v_order_mode.settings->>'claim_minutes')::integer;
 select array_agg(x::integer) into v_w from jsonb_array_elements_text(v_order_mode.settings->'weights') x;
 select array_agg(x::integer) into v_h from jsonb_array_elements_text(v_order_mode.settings->'hidden_probabilities') x;
 select coalesce(sum(i.quantity*i.unit_price_rm),0) into v_gross from public.yt_member_order_items i where i.order_id=v_order;
 select coalesce(sum(i.unit_price_rm),0) into v_eligible_gross from public.yt_member_order_items i
 join public.yt_pos_item_units u on u.order_item_id=i.id
 where i.order_id=v_order and i.is_drink_at_order and i.unit_price_rm>0 and not u.retired and u.unit_number<=i.quantity
 and u.reward_redemption_id is null;
 if v_gross<=0 or v_eligible_gross<=0 then raise exception 'lucky_order_not_eligible';end if;
 v_fraction:=least(1,v_order_row.amount_rm/v_gross);
 v_total:=round(v_eligible_gross*v_fraction,2);
 if v_total<v_min then raise exception 'lucky_minimum_spend';end if;
 if p_kind='claim' then
  if exists(select 1 from public.yt_pos_pass_bundle_items x join public.yt_pos_pass_bundles b on b.id=x.bundle_id
     where x.pass_id=v_ref and b.status='issued' and b.expires_at>clock_timestamp())
   then raise exception 'use_whole_order_claim';end if;
  if exists(select 1 from public.yt_lucky_results r join public.yt_pos_pass_bundle_items x on x.bundle_id=r.bundle_id where x.pass_id=v_ref)
   then raise exception 'lucky_already_opened';end if;
  select i.unit_price_rm into v_box_gross from public.yt_pos_item_units u
   join public.yt_member_order_items i on i.id=u.order_item_id
   where u.game_pass_id=v_ref and i.is_drink_at_order and i.unit_price_rm>0 and not u.retired and u.unit_number<=i.quantity
    and u.reward_redemption_id is null;
  v_first:=v_ref;
 else
  if exists(select 1 from public.yt_pos_pass_bundle_items x join public.yt_lucky_results r on r.pass_id=x.pass_id where x.bundle_id=v_ref)
   then raise exception 'lucky_already_opened';end if;
  select coalesce(sum(i.unit_price_rm),0),(array_agg(x.pass_id order by x.pass_id))[1] into v_box_gross,v_first
   from public.yt_pos_pass_bundle_items x join public.game_passes p on p.id=x.pass_id
   join public.yt_pos_item_units u on u.order_item_id=x.order_item_id and u.unit_number=x.unit_number and u.game_pass_id=p.id
   join public.yt_member_order_items i on i.id=x.order_item_id
   where x.bundle_id=v_ref and i.order_id=v_order and i.is_drink_at_order and i.unit_price_rm>0
    and p.lucky_mode='lucky' and p.status='issued' and p.customer_id is null and not u.retired and u.reward_redemption_id is null;
 end if;
 if v_box_gross is null or v_box_gross<=0 or v_first is null then raise exception 'lucky_box_not_eligible';end if;
 v_box_amount:=round(v_box_gross*v_fraction,2);
 v_box_cap:=least(1000000,floor(v_box_gross*v_fraction*v_cap)::integer);
 if v_box_cap<1 then raise exception 'lucky_box_not_eligible';end if;
 select * into v_draw from public.yt_lucky_order_draws where order_id=v_order for update;
 if not found then
  v_chance:=case when v_total<50 then v_h[1] when v_total<100 then v_h[2] when v_total<200 then v_h[3] else v_h[4] end;
  if random()*100 < v_chance then
   v_pick:=random()*v_eligible_gross;
   for v_unit in select i.id item_id,u.unit_number,i.unit_price_rm price from public.yt_member_order_items i
     join public.yt_pos_item_units u on u.order_item_id=i.id
     where i.order_id=v_order and i.is_drink_at_order and i.unit_price_rm>0 and not u.retired
      and u.unit_number<=i.quantity and u.reward_redemption_id is null order by i.id,u.unit_number
   loop
    v_pick:=v_pick-v_unit.price;
    if v_pick<=0 then v_hidden_item:=v_unit.item_id;v_hidden_unit:=v_unit.unit_number;exit;end if;
   end loop;
  end if;
  insert into public.yt_lucky_order_draws(order_id,eligible_total_rm,cap_points,hidden_item_id,hidden_unit)
   values(v_order,v_total,least(1000000,floor(v_eligible_gross*v_fraction*v_cap)::integer),v_hidden_item,v_hidden_unit)
   returning * into v_draw;
 end if;
 if v_draw.hidden_item_id is not null then
  if p_kind='claim' then
    select exists(select 1 from public.yt_pos_item_units u where u.game_pass_id=v_ref and
     u.order_item_id=v_draw.hidden_item_id and u.unit_number=v_draw.hidden_unit) into v_legendary;
  else
    select exists(select 1 from public.yt_pos_pass_bundle_items x where x.bundle_id=v_ref
      and x.order_item_id=v_draw.hidden_item_id and x.unit_number=v_draw.hidden_unit) into v_legendary;
  end if;
 end if;
 v_rnd:=random()*100;
 if v_rnd<v_w[1] then v_grade:='ordinary';v_pts:=floor(v_box_gross*v_fraction*v_base*0.8);
 elsif v_rnd<v_w[1]+v_w[2] then v_grade:='lucky';v_pts:=floor(v_box_gross*v_fraction*v_base);
 elsif v_rnd<v_w[1]+v_w[2]+v_w[3] then v_grade:='shining';v_pts:=floor(v_box_gross*v_fraction*v_base*1.4);
 else v_grade:='gold';v_pts:=floor(v_box_gross*v_fraction*v_base*2);end if;
 if v_legendary then v_grade:='legendary';v_pts:=floor(v_box_gross*v_fraction*v_base*2.8);end if;
 v_pts:=greatest(0,least(v_pts,v_box_cap));
 insert into public.yt_lucky_results(order_id,pass_id,bundle_id,secret_hash,points,grade,box_amount_rm,claim_deadline)
  values(v_order,case when p_kind='claim' then v_ref else null end,
   case when p_kind='bundle' then v_ref else null end,
   secret_h,v_pts,v_grade,v_box_amount,clock_timestamp()+make_interval(mins=>v_claim_minutes))
 returning * into v_result;
 return jsonb_build_object('id',v_result.id,'points',v_pts,'grade',v_grade,'amount_rm',v_box_amount,
  'claim_deadline',v_result.claim_deadline,'claimed',false,'idempotent',false);
end $function$
;

CREATE OR REPLACE FUNCTION private.yt_lucky_owner_save(p_settings jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_s public.yt_lucky_settings%rowtype; m text; bp numeric; cp numeric; ms numeric; cm integer; w integer[]; h integer[]; daily_budget numeric;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select * into current_s from public.yt_lucky_settings where id=true for update;
 m:=coalesce(p_settings->>'mode',current_s.mode);
 bp:=coalesce((p_settings->>'base_points_per_rm')::numeric,current_s.base_points_per_rm);
 cp:=coalesce((p_settings->>'cap_points_per_rm')::numeric,current_s.cap_points_per_rm);
 ms:=coalesce((p_settings->>'minimum_spend_rm')::numeric,current_s.minimum_spend_rm);
 cm:=coalesce((p_settings->>'claim_minutes')::integer,current_s.claim_minutes);
 w:=coalesce((select array_agg((v.value)::integer order by v.ordinality)
   from jsonb_array_elements_text(p_settings->'weights') with ordinality v(value,ordinality)),current_s.weights);
 daily_budget:=case when p_settings ? 'daily_budget_rm' then (p_settings->>'daily_budget_rm')::numeric else current_s.daily_budget_rm end;
 h:=coalesce((select array_agg((v.value)::integer order by v.ordinality)
   from jsonb_array_elements_text(p_settings->'hidden_probabilities') with ordinality v(value,ordinality)),current_s.hidden_probabilities);
 if m not in ('game','lucky','off') or bp not between 0.1 and 50 or cp not between 0.1 and 100
  or bp>cp or ms not between 1 and 5000 or cm not between 3 and 120
  or (daily_budget is not null and (daily_budget<1 or daily_budget>100000))
  or cardinality(w)<>4 or cardinality(h)<>4 or exists(select 1 from unnest(w) t where t<0 or t>100)
  or (select sum(t) from unnest(w) t)<>100 or exists(select 1 from unnest(h) t where t<0 or t>10)
  or not (h[1]<=h[2] and h[2]<=h[3] and h[3]<=h[4])
 then raise exception 'lucky_invalid_settings';end if;
 update public.yt_lucky_settings set mode=m,base_points_per_rm=bp,cap_points_per_rm=cp,minimum_spend_rm=ms,
 claim_minutes=cm,weights=w,hidden_probabilities=h,daily_budget_rm=daily_budget,version=version+1,updated_at=now(),updated_by=auth.uid()
 where id=true;
 return private.yt_lucky_owner_settings();
end $function$
;

CREATE OR REPLACE FUNCTION private.yt_lucky_owner_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select to_jsonb(c) into s from public.yt_lucky_settings c where id=true;
 return s||jsonb_build_object('opened',(select count(*) from public.yt_lucky_results),
  'claimed',(select count(*) from public.yt_lucky_results where claimed_at is not null),
  'points_credited',(select coalesce(sum(points),0) from public.yt_lucky_results where claimed_at is not null),
  'today_reserved_points',(select coalesce(sum(reserved_points),0) from public.yt_lucky_day_reservations where business_day=private.yt_business_day(clock_timestamp())),
  'today_awarded_points',(select coalesce(sum(r.points),0) from public.yt_lucky_results r join public.yt_lucky_day_reservations d on d.order_id=r.order_id where d.business_day=private.yt_business_day(clock_timestamp())),
  'today_eligible_rm',(select coalesce(sum(eligible_rm),0) from public.yt_lucky_day_reservations where business_day=private.yt_business_day(clock_timestamp())));
end $function$
;

CREATE OR REPLACE FUNCTION private.yt_lucky_reset_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 update public.yt_lucky_settings set mode='game',base_points_per_rm=3.5,cap_points_per_rm=10,
  minimum_spend_rm=15,claim_minutes=20,weights=array[15,55,25,5],
  hidden_probabilities=array[1,2,3,5],daily_budget_rm=null,version=version+1,updated_at=now(),updated_by=null where id=true;
 return private.yt_lucky_current();
end $function$
;

CREATE OR REPLACE FUNCTION private.yt_lucky_capture_unit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order uuid;current_mode text;v_saved_mode text;v_cfg jsonb;
 v_gross numeric;v_eligible numeric;v_paid numeric;v_amount numeric;v_reserved integer;v_daily numeric;v_day date;
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
 select mode,settings into v_saved_mode,v_cfg from public.yt_lucky_order_modes where order_id=v_order;
 if v_saved_mode='lucky' then
   select amount_rm into v_paid from public.yt_member_orders where id=v_order;
   select coalesce(sum(i.quantity*i.unit_price_rm),0) into v_gross from public.yt_member_order_items i where order_id=v_order;
   select coalesce(sum(i.unit_price_rm),0) into v_eligible from public.yt_member_order_items i
      join public.yt_pos_item_units u on u.order_item_id=i.id
      where i.order_id=v_order and i.is_drink_at_order and i.unit_price_rm>0
       and not u.retired and u.unit_number<=i.quantity and u.reward_redemption_id is null;
   if v_gross<=0 or round(v_eligible*least(1,v_paid/v_gross),2)<
       (v_cfg->>'minimum_spend_rm')::numeric then raise exception 'lucky_minimum_spend';end if;
   v_amount:=round(v_eligible*least(1,v_paid/v_gross),2);
   v_day:=private.yt_business_day(clock_timestamp());
   v_reserved:=least(1000000,floor(v_amount*(v_cfg->>'cap_points_per_rm')::numeric)::integer);
   if not exists(select 1 from public.yt_lucky_day_reservations where order_id=v_order) then
     select daily_budget_rm into v_daily from public.yt_lucky_settings where id=true;
     if v_daily is not null and
      (select coalesce(sum(reserved_points),0) from public.yt_lucky_day_reservations where business_day=v_day)+v_reserved>floor(v_daily*100)
     then raise exception 'lucky_daily_budget_reached';end if;
     insert into public.yt_lucky_day_reservations(order_id,business_day,eligible_rm,reserved_points)
       values(v_order,v_day,v_amount,v_reserved) on conflict(order_id) do nothing;
   end if;
 end if;
 update public.game_passes p set lucky_mode=v_saved_mode where p.id=new.game_pass_id and p.lucky_mode<>v_saved_mode;
 return new;
end $function$
;

CREATE OR REPLACE FUNCTION private.yt_point_shop_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid:=auth.uid();b bigint;items jsonb;begin
 if actor is null or not exists(select 1 from public.pin_accounts where auth_user_id=actor) or exists(select 1 from public.work_accounts where auth_user_id=actor) then raise exception 'customer_only';end if;
 perform pg_advisory_xact_lock(781943081);b:=private.yt_points_sync(actor);
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into items from (select i.id,r.name,coalesce(nullif(btrim(i.description),''),r.description) description,r.category,i.points_cost,case when i.stock_limit is null then null else greatest(0,i.stock_limit-i.stock_used) end stock_remaining,i.per_member_limit,(select count(*) from public.yt_point_shop_exchanges e where e.item_id=i.id and e.customer_id=actor) claimed_count,r.validity_days,r.next_day_only next_day_only,r.redeem_start_at,r.redeem_end_at,r.daily_start_local,r.daily_end_local,rule.min_paid_drinks,rule.min_spend_rm,rule.discount_type,rule.discount_value from public.yt_point_shop_items i join public.rewards r on r.id=i.reward_id join public.yt_pos_reward_rules rule on rule.reward_id=r.id where i.active and r.active and rule.mode in('product','series','any_drink') and (i.starts_at is null or i.starts_at<=clock_timestamp()) and (i.ends_at is null or i.ends_at>clock_timestamp()) and (r.redeem_end_at is null or r.redeem_end_at>clock_timestamp()) order by i.sort_order,i.id limit 100)x;
 return jsonb_build_object('balance',b,'items',items,'expiring_points',(select coalesce(sum(remaining_points),0) from public.yt_point_entries where customer_id=actor and direction='earn' and remaining_points>0 and expires_at<=clock_timestamp()+interval '7 days'));
end $function$
;

CREATE OR REPLACE FUNCTION private.yt_point_shop_exchange(p_item uuid, p_request uuid, p_expected_cost integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 after_time:=case when r.next_day_only then private.yt_business_start(private.yt_business_day(clock_timestamp())+1) else clock_timestamp() end;expiry:=after_time+make_interval(days=>r.validity_days);
 expiry:=least(expiry,coalesce(r.redeem_end_at,expiry));if expiry<=after_time then raise exception 'reward_no_valid_window';end if;
 insert into public.user_rewards(customer_id,reward_id,redeem_after,expires_at) values(actor,r.id,after_time,expiry) returning id into award;
 insert into public.yt_point_shop_exchanges(customer_id,item_id,request_id,user_reward_id,points_cost) values(actor,i.id,p_request,award,i.points_cost) returning id into ex;
 insert into public.yt_point_entries(customer_id,direction,points,reference,source) values(actor,'spend',i.points_cost,'SHOP:'||ex::text,'mall_exchange');
 update public.yt_point_wallets set balance=balance-i.points_cost,lifetime_spent=lifetime_spent+i.points_cost,updated_at=clock_timestamp() where customer_id=actor;
 update public.yt_point_shop_items set stock_used=stock_used+1 where id=i.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'points.exchange','point_shop_exchange',ex,jsonb_build_object('item',i.id,'points',i.points_cost,'award',award));
 return jsonb_build_object('id',ex,'reward_id',award,'points_cost',i.points_cost,'reward_name',r.name,'idempotent',false);
end $function$
;
