-- Same-mode bundle creation assigns its passes after inserting the bundle.
-- Keep member-points/Lucky Box exclusivity while allowing that internal assignment.
create or replace function private.yt_play_pass_issue_choice_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_order uuid; v_mode text;
begin
 if new.game_pass_id is null or new.game_pass_id is not distinct from old.game_pass_id then return new;end if;
 select order_id into v_order from public.yt_member_order_items where id=new.order_item_id;
 select lucky_mode into v_mode from public.game_passes where id=new.game_pass_id;
 if exists(select 1 from public.yt_play_consumption_bindings b where b.order_id=v_order
   and b.source in ('pos_qr','member_qr','lucky_box'))
  or exists(select 1 from public.yt_lucky_results r where r.order_id=v_order)
  or exists(select 1 from public.yt_pos_pass_bundles b where b.order_id=v_order
   and b.status<>'cancelled' and b.lucky_mode is distinct from v_mode) then
  raise exception 'order_benefit_already_selected';
 end if;
 return new;
end $$;
