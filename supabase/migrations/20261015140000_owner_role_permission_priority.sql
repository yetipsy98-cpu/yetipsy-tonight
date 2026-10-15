-- Treat the active Owner work account as the authority for Owner privileges.
-- Staff-role mirror rows may lag or be inconsistent; they must never demote an Owner.
create or replace function private.yt_work_owner()
returns boolean language sql stable security definer set search_path=''
as $$
 select exists(
  select 1 from public.work_accounts wa
  where wa.auth_user_id=auth.uid() and wa.role='owner'
   and wa.active and not wa.must_change_password
 );
$$;

create or replace function private.yt_pos_work_staff()
returns boolean language sql stable security definer set search_path=''
as $$
 select private.yt_work_owner() or exists(
  select 1 from public.work_accounts wa
  join public.staff_roles sr on sr.user_id=wa.auth_user_id
  where wa.auth_user_id=auth.uid() and wa.active and not wa.must_change_password
   and wa.role in ('staff','cashier') and sr.active and sr.role=wa.role
 );
$$;

create or replace function private.yt_pos_work_cashier()
returns boolean language sql stable security definer set search_path=''
as $$
 select private.yt_work_owner() or exists(
  select 1 from public.work_accounts wa
  join public.staff_roles sr on sr.user_id=wa.auth_user_id
  where wa.auth_user_id=auth.uid() and wa.active and not wa.must_change_password
   and sr.active and sr.role=wa.role
   and (wa.role='cashier' or (wa.role='staff' and wa.can_cashier))
 );
$$;

create or replace function private.yt_pos_work_edit_orders()
returns boolean language sql stable security definer set search_path=''
as $$
 select private.yt_work_owner() or exists(
  select 1 from public.work_accounts wa
  join public.staff_roles sr on sr.user_id=wa.auth_user_id
  where wa.auth_user_id=auth.uid() and wa.active and not wa.must_change_password
   and sr.active and sr.role=wa.role
   and (wa.role='cashier' or (wa.role='staff' and wa.can_edit_orders))
 );
$$;

create or replace function private.yt_pos_identity()
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare a public.work_accounts%rowtype;owner_access boolean:=private.yt_work_owner();
begin
 if not private.yt_pos_work_staff() and not private.yt_owner_limited() then raise exception 'staff_only';end if;
 select * into a from public.work_accounts where auth_user_id=auth.uid();
 return jsonb_build_object(
  'username',a.username,'role',a.role,
  'can_cashier',private.yt_pos_work_cashier(),
  'can_edit_orders',private.yt_pos_work_edit_orders(),
  'can_owner',owner_access,
  'can_owner_limited',private.yt_owner_limited()
 );
end $$;
