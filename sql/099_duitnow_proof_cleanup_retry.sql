-- Keep the private object path until Storage confirms deletion, so cleanup can be retried.
create or replace function private.yt_pos_duitnow_proof_list() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 select coalesce(jsonb_agg(jsonb_build_object('order_id',p.order_id,'storage_path',p.storage_path,
  'submitted_at',p.submitted_at,'amount_rm',p.amount_rm,'order_no',p.order_no,'table_label',o.table_label,
  'submitted_by',wa.username,'status',p.status) order by (p.status='pending') desc,p.submitted_at),'[]'::jsonb) into rows
 from public.yt_pos_duitnow_proofs p join public.yt_member_orders o on o.id=p.order_id
 left join public.work_accounts wa on wa.auth_user_id=p.submitted_by
 where p.status='pending' or p.storage_path is not null;
 return rows;
end $$;
create or replace function public.yt_pos_duitnow_proof_list() returns jsonb
language sql security invoker set search_path='' as $$select private.yt_pos_duitnow_proof_list()$$;

create or replace function private.yt_pos_duitnow_proof_review(p_order uuid,p_confirm boolean,p_note text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p public.yt_pos_duitnow_proofs%rowtype;result jsonb;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if p_order is null or p_confirm is null or length(coalesce(p_note,''))>300 then raise exception 'invalid_payment_review';end if;
 select * into p from public.yt_pos_duitnow_proofs where order_id=p_order and status='pending' for update;
 if not found then raise exception 'payment_proof_not_pending';end if;
 if p_confirm then
  result:=private.yt_pos_action(p_order,'paid',null,'duitnow');
  update public.yt_pos_duitnow_proofs set status='confirmed',reviewed_by=auth.uid(),reviewed_at=clock_timestamp() where order_id=p_order;
 else
  update public.yt_pos_duitnow_proofs set status='rejected',reviewed_by=auth.uid(),reviewed_at=clock_timestamp(),reject_note=nullif(btrim(coalesce(p_note,'')),'') where order_id=p_order;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(auth.uid(),'pos.duitnow_proof_rejected','pos_order',p_order,jsonb_build_object('order_no',p.order_no,'amount_rm',p.amount_rm,'note',p_note));
  result:=jsonb_build_object('order_id',p_order,'status','unpaid');
 end if;
 return result||jsonb_build_object('storage_path',p.storage_path,'order_no',p.order_no,'amount_rm',p.amount_rm);
end $$;
create or replace function public.yt_pos_duitnow_proof_review(p_order uuid,p_confirm boolean,p_note text default null) returns jsonb
language sql security invoker set search_path='' as $$select private.yt_pos_duitnow_proof_review(p_order,p_confirm,p_note)$$;

create or replace function private.yt_pos_duitnow_proof_cleanup_complete(p_order uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p public.yt_pos_duitnow_proofs%rowtype;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 update public.yt_pos_duitnow_proofs set storage_path=null
 where order_id=p_order and status in ('confirmed','rejected') and storage_path is not null
 returning * into p;
 if not found then
  if exists(select 1 from public.yt_pos_duitnow_proofs where order_id=p_order and storage_path is null and status in ('confirmed','rejected')) then
   return jsonb_build_object('order_id',p_order,'cleaned',true);
  end if;
  raise exception 'payment_proof_not_ready_for_cleanup';
 end if;
 return jsonb_build_object('order_id',p.order_id,'status',p.status,'cleaned',true);
end $$;
create or replace function public.yt_pos_duitnow_proof_cleanup_complete(p_order uuid) returns jsonb
language sql security invoker set search_path='' as $$select private.yt_pos_duitnow_proof_cleanup_complete(p_order)$$;
revoke all on function private.yt_pos_duitnow_proof_cleanup_complete(uuid),public.yt_pos_duitnow_proof_cleanup_complete(uuid) from public,anon;
grant execute on function private.yt_pos_duitnow_proof_cleanup_complete(uuid),public.yt_pos_duitnow_proof_cleanup_complete(uuid) to authenticated;
notify pgrst,'reload schema';
