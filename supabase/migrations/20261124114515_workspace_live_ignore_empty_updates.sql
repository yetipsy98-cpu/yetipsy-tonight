-- Ignore zero-row expiry checks and unchanged rows; they are not new work.
-- Transaction flags still emit at most one message per scope.
create or replace function private.yt_work_refresh_signal() returns trigger
language plpgsql security definer set search_path='' as $$
declare scope text:=tg_argv[0];flag text;transaction_key text:=txid_current()::text;old_topic text:=coalesce(current_setting('realtime.topic',true),'');
begin
 if tg_op='UPDATE' and new is not distinct from old then return null;end if;
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

drop trigger yt_work_live_orders on public.yt_member_orders;
drop trigger yt_work_live_items on public.yt_member_order_items;
drop trigger yt_work_live_storebox on public.yt_store_box_requests;
drop trigger yt_work_live_freeflow on public.yt_freeflow_requests;
drop trigger yt_work_live_groups on public.yt_freeflow_sessions;
drop trigger yt_work_live_bell on public.yt_play_bell_requests;

create trigger yt_work_live_orders after insert or update or delete on public.yt_member_orders
for each row execute function private.yt_work_refresh_signal('orders');
create trigger yt_work_live_items after insert or update or delete on public.yt_member_order_items
for each row execute function private.yt_work_refresh_signal('orders');
create trigger yt_work_live_storebox after insert or update or delete on public.yt_store_box_requests
for each row execute function private.yt_work_refresh_signal('orders');
create trigger yt_work_live_freeflow after insert or update or delete on public.yt_freeflow_requests
for each row execute function private.yt_work_refresh_signal('freeflow');
create trigger yt_work_live_groups after insert or update or delete on public.yt_freeflow_sessions
for each row execute function private.yt_work_refresh_signal('freeflow');
create trigger yt_work_live_bell after insert or update or delete on public.yt_play_bell_requests
for each row execute function private.yt_work_refresh_signal('bell');
