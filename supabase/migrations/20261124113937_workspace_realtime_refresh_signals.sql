-- Private invalidation signals only: no order, member, table or payment details.
-- Existing RPCs remain the authority for reading data and every operation.
create policy yt_work_receive_refresh_signals on realtime.messages
for select to authenticated
using (
 extension='broadcast' and private=true
 and topic=(select realtime.topic())
 and (
  (topic in ('yt-work-orders','yt-work-freeflow') and (select private.yt_pos_work_staff()))
  or (topic='yt-work-bell' and (select private.yt_pos_work_cashier()))
 )
);

create or replace function private.yt_work_refresh_signal() returns trigger
language plpgsql security definer set search_path='' as $$
declare scope text:=tg_argv[0];flag text;transaction_key text:=txid_current()::text;old_topic text:=coalesce(current_setting('realtime.topic',true),'');
begin
 if scope not in ('orders','freeflow','bell') then return null;end if;
 -- Many item/request statements in one transaction produce one signal per scope.
 -- The broadcast is committed with the sale, never before the sale is visible.
 flag:='yt.work_signal_'||scope;
 if current_setting(flag,true)=transaction_key then return null;end if;
 perform set_config(flag,transaction_key,true);
 perform realtime.send(jsonb_build_object('scope',scope),'changed','yt-work-'||scope,true);
 perform set_config('realtime.topic',old_topic,true);
 return null;
exception when others then
 -- Notification delivery must never turn a successful sale into a failed sale.
 raise warning 'Workspace refresh signal failed (%)',sqlstate;
 return null;
end$$;
revoke all on function private.yt_work_refresh_signal() from public,anon,authenticated;

create trigger yt_work_live_orders after insert or update or delete on public.yt_member_orders
for each statement execute function private.yt_work_refresh_signal('orders');
create trigger yt_work_live_items after insert or update or delete on public.yt_member_order_items
for each statement execute function private.yt_work_refresh_signal('orders');
create trigger yt_work_live_storebox after insert or update or delete on public.yt_store_box_requests
for each statement execute function private.yt_work_refresh_signal('orders');
create trigger yt_work_live_freeflow after insert or update or delete on public.yt_freeflow_requests
for each statement execute function private.yt_work_refresh_signal('freeflow');
create trigger yt_work_live_groups after insert or update or delete on public.yt_freeflow_sessions
for each statement execute function private.yt_work_refresh_signal('freeflow');
create trigger yt_work_live_bell after insert or update or delete on public.yt_play_bell_requests
for each statement execute function private.yt_work_refresh_signal('bell');
