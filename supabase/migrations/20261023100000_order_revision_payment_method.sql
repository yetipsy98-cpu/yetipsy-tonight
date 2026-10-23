-- Let an order revision correct its payment method without changing the collected amount.
-- The existing revision transaction remains the source of all item, benefit and balance logic.
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
  if not found or rev.request_payload<>rev.request_payload||jsonb_build_object('payment_method',p_payment_method) then raise;end if;
  return rev.after_state||jsonb_build_object('ok',true,'retried',true);
 end;
 update public.yt_member_orders set payment_method=p_payment_method where id=p_order returning * into current_order;
 update public.yt_pos_payment_entries set method=p_payment_method where order_id=p_order and kind='sale';
 select * into rev from public.yt_pos_order_revisions where request_id=p_request for update;
 update public.yt_pos_order_revisions set
  request_payload=request_payload||jsonb_build_object('payment_method',p_payment_method),
  after_state=after_state||jsonb_build_object('payment_method',p_payment_method)
  where id=rev.id returning * into rev;
 update public.yt_pos_owner_revision_requests set
  request_payload=request_payload||jsonb_build_object('payment_method',p_payment_method),
  result=coalesce(result,'{}'::jsonb)||jsonb_build_object('payment_method',p_payment_method)
  where id=p_request;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(auth.uid(),'pos.payment_method_corrected','pos_order',p_order,jsonb_build_object('revision',current_order.revision,'payment_method',p_payment_method));
 return result||jsonb_build_object('payment_method',p_payment_method);
end $$;

create or replace function private.yt_pos_owner_revision_request_submit_v2(
 p_order uuid,p_items jsonb,p_reason text,p_table text,p_note text,
 p_expected_updated timestamptz,p_cancel boolean,p_request uuid,p_payment_method text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_member_orders%rowtype;clean_items jsonb;payload jsonb;existing public.yt_pos_owner_revision_requests%rowtype;preview jsonb;
begin
 if not private.yt_pos_work_cashier() or private.yt_work_owner() then raise exception 'cashier_only';end if;
 if p_order is null or p_request is null or p_expected_updated is null or p_cancel is null or length(btrim(coalesce(p_reason,''))) not between 3 and 300 or length(coalesce(p_table,''))>32 or length(coalesce(p_note,''))>600 then raise exception 'invalid_order_revision';end if;
 if p_payment_method is not null and (p_payment_method not in ('foodcourt','cash','duitnow','bank_transfer','card','other') or p_cancel) then raise exception 'invalid_payment_method';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos';
 if not found or v.status in ('cancelled','refunded') then raise exception 'order_not_editable';end if;
 if p_payment_method is not null and exists(select 1 from public.yt_ambassador_pos_sales where order_id=p_order) then raise exception 'payment_method_change_not_allowed';end if;
 if p_cancel then clean_items:='[]'::jsonb;
 else
  if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'invalid_order_revision';end if;
  select coalesce(jsonb_agg(value-'unit_price_rm' order by ordinality),'[]'::jsonb) into clean_items from jsonb_array_elements(p_items) with ordinality as i(value,ordinality);
 end if;
 preview:=private.yt_pos_owner_revision_preview(p_order,clean_items,p_cancel);
 payload:=jsonb_build_object('order',p_order,'items',clean_items,'reason',btrim(p_reason),'table',nullif(btrim(coalesce(p_table,'')),''),'note',nullif(btrim(coalesce(p_note,'')),''),'expected',p_expected_updated,'cancel',p_cancel,'preview',preview);
 if p_payment_method is not null then payload:=payload||jsonb_build_object('payment_method',p_payment_method);end if;
 select * into existing from public.yt_pos_owner_revision_requests where id=p_request;
 if found then if existing.requester_id<>auth.uid() or existing.order_id<>p_order or existing.request_payload<>payload then raise exception 'request_conflict';end if;return jsonb_build_object('id',existing.id,'status',existing.status,'retried',true);end if;
 begin
  insert into public.yt_pos_owner_revision_requests(id,order_id,requester_id,request_payload) values(p_request,p_order,auth.uid(),payload);
 exception when unique_violation then raise exception 'revision_request_already_pending';end;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.revision_requested','pos_order',p_order,jsonb_build_object('request_id',p_request,'cancel',p_cancel,'reason',btrim(p_reason),'payment_method',p_payment_method));
 return jsonb_build_object('id',p_request,'status','pending');
end $$;

create or replace function private.yt_pos_owner_revision_request_review(p_request uuid,p_approve boolean,p_note text default '',p_revoke boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare q public.yt_pos_owner_revision_requests%rowtype;payload jsonb;applied jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_request is null or p_approve is null or p_revoke is null or length(coalesce(p_note,''))>600 then raise exception 'invalid_request';end if;
 select * into q from public.yt_pos_owner_revision_requests where id=p_request for update;
 if not found then raise exception 'request_not_found';end if;
 if q.status<>'pending' then
  if (q.status='approved' and p_approve) or (q.status='rejected' and not p_approve) then return coalesce(q.result,jsonb_build_object('id',q.id,'status',q.status,'retried',true));end if;
  raise exception 'request_already_reviewed';
 end if;
 payload:=q.request_payload;
 if not p_approve then
  if length(btrim(coalesce(p_note,'')))<2 then raise exception 'review_note_required';end if;
  update public.yt_pos_owner_revision_requests set status='rejected',reviewer_id=auth.uid(),reviewed_at=now(),review_note=btrim(p_note),updated_at=now() where id=q.id;
  applied:=jsonb_build_object('id',q.id,'status','rejected');
 else
  if payload ? 'payment_method' then
   applied:=private.yt_pos_owner_revision_apply_v2(q.order_id,payload->'items',payload->>'reason',payload->>'table',payload->>'note',(payload->>'expected')::timestamptz,q.id,p_revoke,(payload->>'cancel')::boolean,payload->>'payment_method');
  else
   applied:=private.yt_pos_owner_revision_apply(q.order_id,payload->'items',payload->>'reason',payload->>'table',payload->>'note',(payload->>'expected')::timestamptz,q.id,p_revoke,(payload->>'cancel')::boolean);
  end if;
  update public.yt_pos_owner_revision_requests set status='approved',reviewer_id=auth.uid(),reviewed_at=now(),review_note=nullif(btrim(coalesce(p_note,'')),''),result=applied,updated_at=now() where id=q.id;
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),case when p_approve then 'pos.revision_approved' else 'pos.revision_rejected' end,'pos_order',q.order_id,jsonb_build_object('request_id',q.id,'note',nullif(btrim(coalesce(p_note,'')),''),'revoke_benefits',case when p_approve then p_revoke else false end));
 return applied||jsonb_build_object('id',q.id,'status',case when p_approve then 'approved' else 'rejected' end);
end $$;

create or replace function public.yt_pos_owner_revision_apply_v2(p_order uuid,p_items jsonb,p_reason text,p_table text,p_note text,p_expected_updated timestamptz,p_request uuid,p_revoke boolean default false,p_cancel boolean default false,p_payment_method text default null)
returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_owner_revision_apply_v2(p_order,p_items,p_reason,p_table,p_note,p_expected_updated,p_request,p_revoke,p_cancel,p_payment_method)$$;
create or replace function public.yt_pos_owner_revision_request_submit_v2(p_order uuid,p_items jsonb,p_reason text,p_table text,p_note text,p_expected_updated timestamptz,p_cancel boolean,p_request uuid,p_payment_method text default null)
returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_owner_revision_request_submit_v2(p_order,p_items,p_reason,p_table,p_note,p_expected_updated,p_cancel,p_request,p_payment_method)$$;
revoke all on function private.yt_pos_owner_revision_apply_v2(uuid,jsonb,text,text,text,timestamptz,uuid,boolean,boolean,text),private.yt_pos_owner_revision_request_submit_v2(uuid,jsonb,text,text,text,timestamptz,boolean,uuid,text) from public,anon;
revoke all on function public.yt_pos_owner_revision_apply_v2(uuid,jsonb,text,text,text,timestamptz,uuid,boolean,boolean,text),public.yt_pos_owner_revision_request_submit_v2(uuid,jsonb,text,text,text,timestamptz,boolean,uuid,text) from public,anon;
grant execute on function private.yt_pos_owner_revision_apply_v2(uuid,jsonb,text,text,text,timestamptz,uuid,boolean,boolean,text),private.yt_pos_owner_revision_request_submit_v2(uuid,jsonb,text,text,text,timestamptz,boolean,uuid,text) to authenticated;
grant execute on function public.yt_pos_owner_revision_apply_v2(uuid,jsonb,text,text,text,timestamptz,uuid,boolean,boolean,text),public.yt_pos_owner_revision_request_submit_v2(uuid,jsonb,text,text,text,timestamptz,boolean,uuid,text) to authenticated;
revoke all on function private.yt_pos_owner_revision_request_review(uuid,boolean,text,boolean) from public,anon;
grant execute on function private.yt_pos_owner_revision_request_review(uuid,boolean,text,boolean) to authenticated;
