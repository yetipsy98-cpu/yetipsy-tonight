-- Staff can complete normal POS checkouts. DuitNow still requires Cashier approval.
-- Transaction evidence lives in a private bucket and is removed from Storage after review.

create table if not exists public.yt_pos_duitnow_proofs (
 order_id uuid primary key references public.yt_member_orders(id) on delete cascade,
 storage_path text,
 submitted_by uuid references auth.users(id) on delete set null,
 submitted_at timestamptz not null default clock_timestamp(),
 status text not null check(status in ('pending','confirmed','rejected')),
 reviewed_by uuid references auth.users(id) on delete set null,
 reviewed_at timestamptz,
 amount_rm numeric(12,2) not null,
 order_no text not null,
 reject_note text
);
alter table public.yt_pos_duitnow_proofs enable row level security;
revoke all on table public.yt_pos_duitnow_proofs from public,anon,authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('yetipsy-payment-proof','yetipsy-payment-proof',false,5242880,array['image/png','image/jpeg','image/webp'])
on conflict(id) do update set name=excluded.name,public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists yt_payment_proof_staff_insert on storage.objects;
create policy yt_payment_proof_staff_insert on storage.objects for insert to authenticated
with check(bucket_id='yetipsy-payment-proof' and name ~ '^proof/[0-9a-f-]{36}/[0-9a-f-]{36}[.](png|jpg|webp)$' and (select private.yt_pos_work_staff()));
drop policy if exists yt_payment_proof_cashier_select on storage.objects;
create policy yt_payment_proof_cashier_select on storage.objects for select to authenticated
using(bucket_id='yetipsy-payment-proof' and (select private.yt_pos_work_cashier()));
drop policy if exists yt_payment_proof_cashier_delete on storage.objects;
create policy yt_payment_proof_cashier_delete on storage.objects for delete to authenticated
using(bucket_id='yetipsy-payment-proof' and (select private.yt_pos_work_cashier()));

-- Loosen only the paid action's role gate. DuitNow remains Cashier-only at the DB boundary.
do $migration$
declare def text; old_gate text; new_gate text;
begin
 select pg_get_functiondef('private.yt_pos_action(uuid,text,text,text)'::regprocedure) into def;
 old_gate := $old$elsif p_action='paid' then
  if not v_cashier then raise exception 'cashier_only';end if;$old$;
 new_gate := $new$elsif p_action='paid' then
  if p_method='duitnow' and not v_cashier then raise exception 'cashier_only';end if;$new$;
 if position(old_gate in def)=0 then raise exception 'yt_pos_action_paid_gate_not_found';end if;
 execute replace(def,old_gate,new_gate);
end$migration$;

create or replace function private.yt_pos_duitnow_proof_submit(p_order uuid,p_path text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o public.yt_member_orders%rowtype;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_order is null or p_path is null or p_path !~ ('^proof/'||p_order::text||'/[0-9a-f-]{36}[.](png|jpg|webp)$') then raise exception 'invalid_payment_proof';end if;
 select * into o from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found or o.payment_status<>'unpaid' or o.status not in ('confirmed','fulfilled') then raise exception 'order_not_ready_for_checkout';end if;
 if not exists(select 1 from storage.objects where bucket_id='yetipsy-payment-proof' and name=p_path) then raise exception 'payment_proof_not_uploaded';end if;
 if exists(select 1 from public.yt_pos_duitnow_proofs where order_id=p_order and status='pending') then raise exception 'payment_proof_already_pending';end if;
 insert into public.yt_pos_duitnow_proofs(order_id,storage_path,submitted_by,submitted_at,status,amount_rm,order_no)
 values(p_order,p_path,auth.uid(),clock_timestamp(),'pending',o.amount_rm,o.order_no)
 on conflict(order_id) do update set storage_path=excluded.storage_path,submitted_by=excluded.submitted_by,
  submitted_at=excluded.submitted_at,status='pending',reviewed_by=null,reviewed_at=null,
  amount_rm=excluded.amount_rm,order_no=excluded.order_no,reject_note=null;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(auth.uid(),'pos.duitnow_proof_submitted','pos_order',p_order,jsonb_build_object('order_no',o.order_no,'amount_rm',o.amount_rm));
 return jsonb_build_object('order_id',p_order,'order_no',o.order_no,'amount_rm',o.amount_rm,'status','pending');
end $$;

create or replace function public.yt_pos_duitnow_proof_submit(p_order uuid,p_path text) returns jsonb
language sql security invoker set search_path='' as $$select private.yt_pos_duitnow_proof_submit(p_order,p_path)$$;

create or replace function private.yt_pos_duitnow_proof_list() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 select coalesce(jsonb_agg(jsonb_build_object('order_id',p.order_id,'storage_path',p.storage_path,
  'submitted_at',p.submitted_at,'amount_rm',p.amount_rm,'order_no',p.order_no,'table_label',o.table_label,
  'submitted_by',wa.username) order by p.submitted_at),'[]'::jsonb) into rows
 from public.yt_pos_duitnow_proofs p join public.yt_member_orders o on o.id=p.order_id
 left join public.work_accounts wa on wa.auth_user_id=p.submitted_by where p.status='pending';
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
  update public.yt_pos_duitnow_proofs set status='confirmed',reviewed_by=auth.uid(),reviewed_at=clock_timestamp(),storage_path=null where order_id=p_order;
 else
  update public.yt_pos_duitnow_proofs set status='rejected',reviewed_by=auth.uid(),reviewed_at=clock_timestamp(),storage_path=null,reject_note=nullif(btrim(coalesce(p_note,'')),'') where order_id=p_order;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(auth.uid(),'pos.duitnow_proof_rejected','pos_order',p_order,jsonb_build_object('order_no',p.order_no,'amount_rm',p.amount_rm,'note',p_note));
  result:=jsonb_build_object('order_id',p_order,'status','unpaid');
 end if;
 return result||jsonb_build_object('storage_path',p.storage_path,'order_no',p.order_no,'amount_rm',p.amount_rm);
end $$;
create or replace function public.yt_pos_duitnow_proof_review(p_order uuid,p_confirm boolean,p_note text default null) returns jsonb
language sql security invoker set search_path='' as $$select private.yt_pos_duitnow_proof_review(p_order,p_confirm,p_note)$$;

revoke all on function private.yt_pos_duitnow_proof_submit(uuid,text),public.yt_pos_duitnow_proof_submit(uuid,text),
 private.yt_pos_duitnow_proof_list(),public.yt_pos_duitnow_proof_list(),
 private.yt_pos_duitnow_proof_review(uuid,boolean,text),public.yt_pos_duitnow_proof_review(uuid,boolean,text) from public,anon;
grant execute on function private.yt_pos_duitnow_proof_submit(uuid,text),public.yt_pos_duitnow_proof_submit(uuid,text),
 private.yt_pos_duitnow_proof_list(),public.yt_pos_duitnow_proof_list(),
 private.yt_pos_duitnow_proof_review(uuid,boolean,text),public.yt_pos_duitnow_proof_review(uuid,boolean,text) to authenticated;
notify pgrst,'reload schema';
