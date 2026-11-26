-- Read only the group displayed in a staff member's open binding QR window.
create or replace function private.yt_freeflow_binding_status(p_session uuid,p_token uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.yt_freeflow_sessions%rowtype;
begin
 if auth.uid() is null or not coalesce(private.yt_pos_work_staff(),false) then raise exception 'staff_only';end if;
 select * into s from public.yt_freeflow_sessions where id=p_session;
 if not found then raise exception 'freeflow_unavailable';end if;
 return jsonb_build_object('id',s.id,'capacity',s.capacity,'status',s.status,
  'token_valid',p_token is not null and s.bind_token=p_token and s.token_expires_at>clock_timestamp()
   and s.status='active' and s.ends_at>clock_timestamp() and exists(
    select 1 from public.yt_member_orders o where o.id=s.order_id and o.status not in ('cancelled','refunded')
     and o.payment_status<>'refunded' and not o.cancel_after_refund),
  'members',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'guest',m.guest_id is not null,
   'name',coalesce(nullif(p.display_name,''),case when m.guest_id is not null then '访客 '||upper(right(m.id::text,4)) else '会员' end),
   'status',m.status,'bound_at',m.bound_at) order by m.bound_at,m.id)
   from public.yt_freeflow_members m left join public.profiles p on p.id=m.customer_id where m.session_id=s.id),'[]'::jsonb));
end $$;
create or replace function public.yt_freeflow_binding_status(p_session uuid,p_token uuid default null)
returns jsonb language sql stable security invoker set search_path = '' as $$
 select private.yt_freeflow_binding_status(p_session,p_token)
$$;
revoke all on function private.yt_freeflow_binding_status(uuid,uuid) from public,anon,authenticated;
revoke all on function public.yt_freeflow_binding_status(uuid,uuid) from public,anon,authenticated;
grant execute on function private.yt_freeflow_binding_status(uuid,uuid) to authenticated;
grant execute on function public.yt_freeflow_binding_status(uuid,uuid) to authenticated;
