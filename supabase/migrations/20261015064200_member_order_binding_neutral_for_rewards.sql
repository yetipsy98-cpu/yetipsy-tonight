-- An order's automatic customer association is neutral: it must not block
-- choosing a Gamepass or bundle. The choice is written to the binding source
-- by yt_play_finalize_binding after pass issuance.
create or replace function private.yt_play_pass_issue_choice_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_order uuid;
begin
 if new.game_pass_id is null or new.game_pass_id is not distinct from old.game_pass_id then return new;end if;
 select order_id into v_order from public.yt_member_order_items where id=new.order_item_id;
 if exists(select 1 from public.yt_play_consumption_bindings b where b.order_id=v_order
   and b.source in ('pos_qr','member_qr','lucky_box'))
  or exists(select 1 from public.yt_lucky_results r where r.order_id=v_order)
  or exists(select 1 from public.yt_pos_pass_bundles b where b.order_id=v_order and b.status<>'cancelled') then
  raise exception 'order_benefit_already_selected';
 end if;
 return new;
end $$;

create or replace function private.yt_play_bundle_issue_choice_guard()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.yt_play_consumption_bindings b where b.order_id=new.order_id
   and b.source in ('pos_qr','member_qr','lucky_box'))
  or exists(select 1 from public.yt_lucky_results r where r.order_id=new.order_id)
  or exists(select 1 from public.yt_member_order_items i join public.yt_pos_item_units u on u.order_item_id=i.id
   join public.game_passes p on p.id=u.game_pass_id
   where i.order_id=new.order_id and p.status not in ('cancelled','revoked','void')) then
  raise exception 'order_benefit_already_selected';
 end if;
 return new;
end $$;
