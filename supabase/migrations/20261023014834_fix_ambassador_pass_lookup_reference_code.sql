-- Let POS pass lookup accept both the full QR UUID and the printed 10-character
-- reference code. Existing permission, status, ownership, and business-day checks
-- remain unchanged.
create or replace function private.yt_ambassador_pos_pass_lookup(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  a public.yt_ambassadors%rowtype;
  v public.yt_ambassador_passes%rowtype;
  d date := private.yt_business_day(now());
  pp jsonb;
  code text;
  ref text;
  issuer text;
begin
  if not private.yt_pos_work_staff() then
    raise exception 'staff_only';
  end if;

  code := (regexp_match(
    trim(coalesce(p_token, '')),
    '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
  ))[1];

  if code is not null then
    select * into v
    from public.yt_ambassador_passes
    where pass_code = code::uuid and status = 'issued';
  else
    ref := (regexp_match(trim(coalesce(p_token, '')), '([0-9a-fA-F]{10})$'))[1];
    if ref is null then
      raise exception 'ambassador_pass_not_found';
    end if;
    select * into v
    from public.yt_ambassador_passes
    where reference_code = upper(ref) and status = 'issued';
  end if;

  if v.id is null then raise exception 'ambassador_pass_not_found'; end if;
  if v.issued_by = auth.uid() and not (private.yt_pos_work_cashier() or private.yt_has_role('owner')) then
    raise exception 'cannot_redeem_own_pass';
  end if;
  if v.ambassador_id is not null then
    select * into a from public.yt_ambassadors where id = v.ambassador_id and active;
    if a.id is null then raise exception 'ambassador_inactive'; end if;
    if a.member_user_id = auth.uid() or a.work_user_id = auth.uid() then
      raise exception 'cannot_redeem_own_pass';
    end if;
  end if;
  if d <> v.reservation_day
    or now() < private.yt_business_start(v.reservation_day)
    or now() >= private.yt_business_start(v.reservation_day + 1) then
    raise exception 'ambassador_pass_not_valid_today';
  end if;

  pp := private.yt_ambassador_price(v.reservation_day);
  if coalesce((pp->>'male')::numeric, 0) <= 0 or coalesce((pp->>'female')::numeric, 0) <= 0 then
    raise exception 'ambassador_prices_not_configured';
  end if;

  select coalesce(nullif(p.display_name, ''), wa.username, 'POS') into issuer
  from public.profiles p
  full join public.work_accounts wa on wa.auth_user_id = p.id
  where p.id = v.issued_by or wa.auth_user_id = v.issued_by
  limit 1;

  return jsonb_build_object(
    'pass_id', v.id,
    'pass_code', v.pass_code,
    'reservation_day', v.reservation_day,
    'pass_type', v.pass_type,
    'planned_pax', v.planned_pax,
    'guest_name', v.guest_name,
    'guest_phone', v.guest_phone,
    'remark', v.remark,
    'ambassador_id', v.ambassador_id,
    'ambassador_name', case when v.ambassador_id is null then 'POS 直发' else coalesce(nullif(a.display_name, ''), 'Ambassador') end,
    'issued_by_name', issuer,
    'commission_rate', coalesce(a.commission_rate, 0),
    'male_price', (pp->>'male')::numeric,
    'female_price', (pp->>'female')::numeric,
    'checked_pax', (select coalesce(sum(c.male_count + c.female_count), 0) from public.yt_ambassador_checkins c where c.pass_id = v.id),
    'sales', (select coalesce(sum(c.sales), 0) from public.yt_ambassador_checkins c where c.pass_id = v.id),
    'commission', (select coalesce(sum(c.commission_amount), 0) from public.yt_ambassador_checkins c where c.pass_id = v.id)
  );
end
$function$;
