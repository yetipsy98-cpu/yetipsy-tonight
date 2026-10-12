-- Prevent issuing a QR that cannot qualify for Lucky Box's minimum spend.
-- This guard runs only for newly allocated GamePass units; old Game Mode is untouched.
create or replace function private.yt_lucky_capture_unit() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_order uuid;current_mode text;v_saved_mode text;v_cfg jsonb;
 v_gross numeric;v_eligible numeric;v_paid numeric;
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
 end if;
 update public.game_passes p set lucky_mode=v_saved_mode where p.id=new.game_pass_id and p.lucky_mode<>v_saved_mode;
 return new;
end $$;
