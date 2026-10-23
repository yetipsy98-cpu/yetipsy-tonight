-- Avoid PL/pgSQL ambiguity between the local result value and the requests.result column.
create or replace function private.yt_pos_owner_revision_apply_v2(
 p_order uuid,p_items jsonb,p_reason text,p_table text,p_note text,
 p_expected_updated timestamptz,p_request uuid,p_revoke boolean default false,
 p_cancel boolean default false,p_payment_method text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; rev public.yt_pos_order_revisions%rowtype; payload jsonb; current_order public.yt_member_orders%rowtype;
begin
 if p_payment_method is null then
  return private.yt_pos_owner_revision_apply(p_order,p_items,p_reason,p_table,p_note,p_expected_updated,p_request,p_revoke,p_cancel);
 end if;
 if p_payment_method not in ('foodcourt','cash','duitnow','bank_transfer','card','other') then raise exception 'invalid_payment_method';end if;
 if p_cancel then raise exception 'payment_method_change_not_allowed';end if;
 select * into current_order from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found';end if;
 if exists(select 1 from public.yt_ambassador_pos_sales where order_id=p_order) then raise exception 'payment_method_change_not_allowed';end if;
 select * into rev from public.yt_pos_order_revisions where request_id=p_request;
 if found then
  payload:=rev.request_payload||jsonb_build_object('payment_method',p_payment_method);
  if rev.request_payload<>payload then raise exception 'request_conflict';end if;
  return rev.after_state||jsonb_build_object('ok',true,'retried',true);
 end if;
 begin
  result:=private.yt_pos_owner_revision_apply(p_order,p_items,p_reason,p_table,p_note,p_expected_updated,p_request,p_revoke,p_cancel);
 exception when sqlstate 'P0001' then
  if sqlerrm<>'request_conflict' then raise;end if;
  select * into rev from public.yt_pos_order_revisions where request_id=p_request;
  if not found or rev.request_payload<>(rev.request_payload||jsonb_build_object('payment_method',p_payment_method)) then raise;end if;
  return rev.after_state||jsonb_build_object('ok',true,'retried',true);
 end;
 update public.yt_member_orders set payment_method=p_payment_method where id=p_order returning * into current_order;
 update public.yt_pos_payment_entries set method=p_payment_method where order_id=p_order and kind='sale';
 select * into rev from public.yt_pos_order_revisions where request_id=p_request for update;
 update public.yt_pos_order_revisions set
  request_payload=request_payload||jsonb_build_object('payment_method',p_payment_method),
  after_state=after_state||jsonb_build_object('payment_method',p_payment_method)
  where id=rev.id returning * into rev;
 update public.yt_pos_owner_revision_requests as req set
  request_payload=req.request_payload||jsonb_build_object('payment_method',p_payment_method),
  result=coalesce(req.result,'{}'::jsonb)||jsonb_build_object('payment_method',p_payment_method)
  where req.id=p_request;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(auth.uid(),'pos.payment_method_corrected','pos_order',p_order,jsonb_build_object('revision',current_order.revision,'payment_method',p_payment_method));
 return result||jsonb_build_object('payment_method',p_payment_method);
end $$;
