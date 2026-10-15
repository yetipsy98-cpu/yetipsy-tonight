-- A POS purchase can belong to one member only. Existing same-member scans stay idempotent.
create unique index if not exists yt_play_one_member_per_order
  on public.yt_play_consumption_bindings(order_id);

-- A single purchase must never become more than one customer's "first purchase".
create unique index if not exists yt_play_first_purchase_order_uidx
  on public.yt_play_first_purchases(order_id);

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
 if o.customer_id is not null and o.customer_id<>p_customer then raise exception 'order_already_bound';end if;
 if exists(select 1 from public.yt_play_consumption_bindings where order_id=p_order and customer_id<>p_customer) then
  raise exception 'order_already_bound';
 end if;
 if o.payment_status='paid' and private.yt_business_day(o.paid_at)<>private.yt_business_day(clock_timestamp())
 and not exists(select 1 from public.yt_play_consumption_bindings where order_id=p_order and customer_id=p_customer)
 then
  if p_source not in ('gamepass','lucky_box') then raise exception 'binding_business_day_closed';end if;
  insert into public.yt_play_consumption_bindings(order_id,customer_id,source)
  values(p_order,p_customer,p_source) on conflict(order_id) do nothing;
  return jsonb_build_object('bound',true,'valid_purchase',false);
 end if;
 insert into public.yt_play_consumption_bindings(order_id,customer_id,source)
 values(p_order,p_customer,p_source) on conflict(order_id) do nothing;
 if o.payment_status<>'paid' or o.paid_at is null or coalesce(o.settlement_due_since is not null,false)
 then return jsonb_build_object('bound',true,'valid_purchase',false);end if;
 select * into cfg from public.yt_play_upgrade_settings where id=true;
 if o.amount_rm<=0
 then return jsonb_build_object('bound',true,'valid_purchase',false);end if;
 -- First purchase remains immutable and uniquely tied to this member and order.
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

