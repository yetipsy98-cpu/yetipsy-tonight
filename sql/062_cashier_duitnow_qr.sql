-- Owner-managed DuitNow QR for Cashier checkout.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('yetipsy-payment-qr','yetipsy-payment-qr',true,5242880,array['image/png','image/jpeg','image/webp'])
on conflict(id) do update set name=excluded.name,public=true,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
alter table public.yt_receipt_settings add column if not exists duitnow_qr_path text;
drop policy if exists yt_payment_qr_owner_insert on storage.objects;
create policy yt_payment_qr_owner_insert on storage.objects for insert to authenticated
with check(bucket_id='yetipsy-payment-qr' and name ~ '^qr/[0-9a-f-]{36}\.(png|jpg|webp)$' and (select private.yt_banner_owner()));
drop policy if exists yt_payment_qr_owner_select on storage.objects;
create policy yt_payment_qr_owner_select on storage.objects for select to authenticated
using(bucket_id='yetipsy-payment-qr' and (select private.yt_banner_owner()));
create or replace function private.yt_owner_payment_qr_save(p_path text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.yt_banner_owner() then raise exception 'owner_only';end if;
 if p_path is not null then
  if p_path !~ '^qr/[0-9a-f-]{36}\.(png|jpg|webp)$' then raise exception 'invalid_payment_qr';end if;
  if not exists(select 1 from storage.objects where bucket_id='yetipsy-payment-qr' and name=p_path) then raise exception 'payment_qr_not_uploaded';end if;
 end if;
 update public.yt_receipt_settings set duitnow_qr_path=p_path,updated_at=clock_timestamp(),updated_by=auth.uid() where id=1;
 insert into public.audit_logs(actor_id,action,entity_type,metadata) values(auth.uid(),'pos.duitnow_qr_settings','receipt_settings',jsonb_build_object('duitnow_qr_path',p_path));
 return jsonb_build_object('duitnow_qr_path',p_path);
end;$$;
create or replace function public.yt_owner_payment_qr_save(p_path text)
returns jsonb language sql security invoker set search_path='' as $$select private.yt_owner_payment_qr_save(p_path);$$;
revoke all on function private.yt_owner_payment_qr_save(text),public.yt_owner_payment_qr_save(text) from public,anon;
grant execute on function private.yt_owner_payment_qr_save(text),public.yt_owner_payment_qr_save(text) to authenticated;
notify pgrst,'reload schema';
