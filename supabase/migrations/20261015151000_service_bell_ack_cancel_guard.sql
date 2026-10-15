-- A stale staff screen must not acknowledge a request after the customer cancelled it.
create or replace function private.yt_play_bell_ack(p_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_play_bell_requests%rowtype;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 update public.yt_play_bell_requests
 set acknowledged_at=clock_timestamp(),acknowledged_by=auth.uid()
 where id=p_id and acknowledged_at is null and cancelled_at is null
 returning * into v;
 if not found then raise exception 'bell_already_acknowledged';end if;
 return jsonb_build_object('id',v.id,'status','acknowledged');
end $$;
create or replace function public.yt_play_bell_ack(p_id uuid)
returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_play_bell_ack(p_id)
$$;
revoke all on function private.yt_play_bell_ack(uuid),public.yt_play_bell_ack(uuid) from public,anon;
grant execute on function private.yt_play_bell_ack(uuid),public.yt_play_bell_ack(uuid) to authenticated;
