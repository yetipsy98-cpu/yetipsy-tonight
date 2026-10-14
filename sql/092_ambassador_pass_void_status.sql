-- The existing Pass status constraint uses 'void' for cancelled Passes.
-- Keep the Owner cancellation RPC aligned with the established status vocabulary.
create or replace function private.yt_ambassador_owner_cancel_pass(p_pass_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare v public.yt_ambassador_passes%rowtype;
begin
 perform private.yt_ambassador_assert_owner();
 select * into v from public.yt_ambassador_passes where id=p_pass_id for update;
 if v.id is null then raise exception 'ambassador_pass_not_found';end if;
 if v.status<>'issued' then raise exception 'pass_not_cancellable';end if;
 if exists(select 1 from public.yt_ambassador_checkins c where c.pass_id=v.id)
  or exists(select 1 from public.yt_ambassador_pos_sales s where s.pass_id=v.id) then
  raise exception 'pass_has_orders';
 end if;
 update public.yt_ambassador_passes set status='void',updated_at=now() where id=v.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(auth.uid(),'ambassador.pass_cancelled','ambassador_pass',v.id,
  jsonb_build_object('pass_code',v.pass_code,'reservation_day',v.reservation_day,'issued_by',v.issued_by));
 return jsonb_build_object('id',v.id,'status','void');
end $$;
