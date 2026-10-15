-- When the Owner has selected Gamepass or Lucky Box as the current activity,
-- disable the member-points binding path at the database boundary as well.
create or replace function private.yt_play_binding_choice_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare existing_source text;
begin
 if new.source in ('pos_qr','member_qr') and exists(
  select 1 from public.yt_lucky_settings where id=true and mode<>'off'
 ) then raise exception 'points_binding_disabled_by_activity';end if;

 select source into existing_source from public.yt_play_consumption_bindings
 where order_id=new.order_id;
 if found and existing_source='customer_order' and new.source<>'customer_order' then
  update public.yt_play_consumption_bindings set source=new.source where order_id=new.order_id;
  return new;
 end if;
 if found and existing_source<>'customer_order' and new.source<>'customer_order'
   and existing_source<>new.source
   and not (existing_source in ('pos_qr','member_qr') and new.source in ('pos_qr','member_qr')) then
  raise exception 'order_benefit_already_selected';
 end if;
 if new.source in ('pos_qr','member_qr') and (
  exists(select 1 from public.yt_play_consumption_bindings b where b.order_id=new.order_id and b.source in ('gamepass','lucky_box'))
  or exists(select 1 from public.yt_lucky_results r where r.order_id=new.order_id)
  or exists(select 1 from public.yt_member_order_items i join public.yt_pos_item_units u on u.order_item_id=i.id
    join public.game_passes p on p.id=u.game_pass_id
    where i.order_id=new.order_id and p.status not in ('cancelled','revoked','void'))
  or exists(select 1 from public.yt_pos_pass_bundles b where b.order_id=new.order_id and b.status<>'cancelled')
 ) then raise exception 'order_benefit_already_selected';end if;
 return new;
end $$;
