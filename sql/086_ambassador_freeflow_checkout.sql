-- Exempt only Ambassador Freeflow POS sales from drink/reward checkout rules.
-- They are paid through yt_pos_action like all other POS orders, with their own
-- AB_ method and check-in/commission capture triggers.
create or replace function private.yt_pos_checkout_minimum()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.source='future_pos' and old.payment_status='unpaid' and new.payment_status='paid'
  and not exists(select 1 from public.yt_ambassador_pos_sales where order_id=new.id)
  and not (private.yt_pos_order_minimum(new.id)->>'minimum_met')::boolean
 then raise exception 'minimum_one_paid_drink';end if;
 return new;
end $$;

create or replace function private.yt_pos_checkout_quote()
returns trigger language plpgsql security definer set search_path='' as $$
declare n_bad integer; v_discount numeric; v_moon numeric:=0; v_moon_bad integer:=0;
begin
 if old.payment_status='unpaid' and new.payment_status='paid' and old.source='future_pos' then
  if exists(select 1 from public.yt_ambassador_pos_sales where order_id=new.id) then return new;end if;
  select count(*) filter(where state<>'ready' or expires_at<=clock_timestamp()),
   coalesce(sum(case when state='ready' and expires_at>clock_timestamp() then discount_rm else 0 end),0)
   into n_bad,v_discount from public.yt_pos_reward_holds where order_id=new.id and state in('reserved','ready');
  if n_bad>0 then raise exception 'coupon_hold_not_ready_or_expired';end if;
  select coalesce(sum(case when kind='R0' then 5 else 0 end),0),
   count(*) filter(where valid_until<(clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date)
   into v_moon,v_moon_bad from public.yt_moon_guest_codes where reserved_order_id=new.id and status='reserved';
  if v_moon_bad>0 then raise exception 'moon_expired';end if;
  if v_discount+v_moon>old.amount_rm then raise exception 'discount_exceeds_bill';end if;
  if v_moon>0 and old.amount_rm<=v_discount+v_moon then raise exception 'moon_minimum_payable';end if;
  if not (private.yt_pos_order_minimum(new.id)->>'minimum_met')::boolean then raise exception 'minimum_one_paid_drink';end if;
  new.amount_rm:=old.amount_rm-v_discount-v_moon;
 end if;
 return new;
end $$;

create or replace function private.yt_pos_checkout_redeem()
returns trigger language plpgsql security definer set search_path='' as $$
declare h public.yt_pos_reward_holds%rowtype; w public.user_rewards%rowtype; v_red uuid;
 v_time timestamptz:=clock_timestamp();
begin
 if not (old.payment_status='unpaid' and new.payment_status='paid' and old.source='future_pos')
  or exists(select 1 from public.yt_ambassador_pos_sales where order_id=new.id) then return new;end if;
 for h in select * from public.yt_pos_reward_holds where order_id=new.id and state in('reserved','ready') order by id for update loop
  if h.state<>'ready' or h.expires_at<=clock_timestamp() then raise exception 'coupon_hold_not_ready_or_expired';end if;
  select * into w from public.user_rewards where id=h.user_reward_id for update;
  if not found or w.status<>'available' or w.expires_at<=clock_timestamp() then raise exception 'coupon_no_longer_available';end if;
  if exists(select 1 from public.redemptions where user_reward_id=w.id) then raise exception 'coupon_already_redeemed';end if;
  if not exists(select 1 from public.yt_pos_item_units u where u.order_item_id=h.order_item_id and u.unit_number=h.unit_number
   and u.reward_redemption_id is null and u.game_pass_id is null) then raise exception 'coupon_cart_item_missing';end if;
  insert into public.redemptions(user_reward_id,customer_id,staff_id,request_id,redeemed_at)
   values(w.id,w.customer_id,new.paid_by,h.id,v_time) returning id into v_red;
  update public.user_rewards set status='redeemed',redeemed_at=v_time where id=w.id;
  update public.redeem_tokens set consumed_at=v_time where user_reward_id=w.id and consumed_at is null;
  update public.yt_pos_item_units set reward_redemption_id=v_red,reward_discount_rm=h.discount_rm
   where order_item_id=h.order_item_id and unit_number=h.unit_number;
  update public.yt_pos_reward_holds set state='settled',redemption_id=v_red,settled_at=v_time,updated_at=v_time where id=h.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
   values(new.paid_by,'pos.coupon_checked_out','pos_order',new.id,
    jsonb_build_object('hold_id',h.id,'redemption_id',v_red,'item_id',h.order_item_id,'discount_rm',h.discount_rm));
 end loop;
 return new;
end $$;
