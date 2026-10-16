create or replace function private.yt_play_finalize_binding(p_order uuid, p_customer uuid, p_source text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
 o public.yt_member_orders%rowtype;
 cfg public.yt_play_upgrade_settings%rowtype;
 r public.yt_referral_links%rowtype;
 inserted integer;
 rewarded boolean:=false;
 v_pending boolean:=false;
 v_reward uuid;
 v_enabled boolean;
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

 -- POS/member QR points can be bound for 24 hours after payment, including across a business-day cutoff.
 if o.payment_status='paid' and p_source in ('pos_qr','member_qr')
   and o.paid_at < clock_timestamp()-interval '24 hours'
   and not exists(select 1 from public.yt_play_consumption_bindings where order_id=p_order and customer_id=p_customer)
 then raise exception 'member_binding_window_closed';end if;

 -- Keep the existing late GamePass/Lucky Box claim behavior, while allowing fresh member QR binds across cutoff.
 if o.payment_status='paid' and private.yt_business_day(o.paid_at)<>private.yt_business_day(clock_timestamp())
 and not exists(select 1 from public.yt_play_consumption_bindings where order_id=p_order and customer_id=p_customer)
 and not (p_source in ('pos_qr','member_qr') and o.paid_at>=clock_timestamp()-interval '24 hours')
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
 if o.amount_rm<=0 then return jsonb_build_object('bound',true,'valid_purchase',false);end if;

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
end $function$;

create or replace function private.yt_play_grant_member_binding_points(p_order uuid,p_customer uuid)
returns bigint
language plpgsql
security definer
set search_path to ''
as $function$
declare
 o public.yt_member_orders%rowtype;
 b public.yt_play_consumption_bindings%rowtype;
 cfg public.yt_loyalty_config%rowtype;
 n bigint;
 v_exp timestamptz;
 v_entry uuid;
 v_custom_amount numeric:=0;
 v_eligible_amount numeric:=0;
begin
 select * into o from public.yt_member_orders where id=p_order and source='future_pos';
 if not found or o.payment_status<>'paid' or o.paid_at is null or o.status in ('cancelled','rejected')
   or o.payment_status='refunded' or o.cancel_after_refund or o.settlement_due_since is not null
   or o.paid_at<clock_timestamp()-interval '24 hours' then return 0;end if;
 select * into b from public.yt_play_consumption_bindings where order_id=p_order and customer_id=p_customer;
 if not found or b.source not in ('pos_qr','member_qr') then return 0;end if;
 if exists(select 1 from public.yt_play_consumption_bindings where order_id=p_order and source in ('gamepass','lucky_box'))
  or exists(select 1 from public.yt_lucky_results where order_id=p_order)
  or exists(select 1 from public.yt_member_order_items i join public.yt_pos_item_units u on u.order_item_id=i.id
    join public.game_passes p on p.id=u.game_pass_id where i.order_id=p_order and p.status not in ('cancelled','revoked','void'))
  or exists(select 1 from public.yt_pos_pass_bundles where order_id=p_order and status<>'cancelled') then return 0;end if;
 select * into cfg from public.yt_loyalty_config where id=true;
 select coalesce(sum(i.quantity*i.unit_price_rm),0) into v_custom_amount
 from public.yt_member_order_items i join public.yt_pos_custom_drinks d on d.product_id=i.product_id
 where i.order_id=p_order;
 v_eligible_amount:=greatest(0,o.amount_rm-v_custom_amount);
 n:=floor(v_eligible_amount*cfg.pos_member_binding_percent*cfg.points_per_rm/100)::bigint;
 if n<1 then return 0;end if;
 perform private.yt_points_sync(p_customer);
 v_exp:=case when cfg.points_validity_days>0 then clock_timestamp()+make_interval(days=>cfg.points_validity_days) else null end;
 insert into public.yt_point_entries(customer_id,direction,points,reference,spend_amount_rm,
   max_budget_points,conversion_points_per_rm,remaining_points,expires_at,source)
 values(p_customer,'earn',n,'POS-MEMBER:'||p_order::text,v_eligible_amount,n,cfg.points_per_rm,n,v_exp,'pos_member_binding')
 on conflict(reference) where source='pos_member_binding' and direction='earn' do nothing
 returning id into v_entry;
 if v_entry is null then return 0;end if;
 update public.yt_point_wallets set balance=balance+n,lifetime_earned=lifetime_earned+n,
   updated_at=clock_timestamp() where customer_id=p_customer;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(p_customer,'points.pos_member_binding','pos_order',p_order,
   jsonb_build_object('amount_rm',v_eligible_amount,'excluded_custom_rm',v_custom_amount,
    'percent',cfg.pos_member_binding_percent,'points',n,'entry_id',v_entry));
 return n;
end $function$;
