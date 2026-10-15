-- Keep the printed short reference deterministic from the pass QR payload.
-- This lets customers and staff manually look up the exact pass if the QR won't scan.
create or replace function private.yt_ambassador_pass_ref_sync()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  new.reference_code := upper(substr(replace(new.pass_code::text, '-', ''), 1, 10));
  return new;
end;
$function$;

update public.yt_ambassador_passes
set reference_code = upper(substr(replace(pass_code::text, '-', ''), 1, 10));

create or replace trigger yt_ambassador_pass_ref_sync
before insert or update of pass_code on public.yt_ambassador_passes
for each row execute function private.yt_ambassador_pass_ref_sync();

create or replace function private.yt_ambassador_pass_lookup(p_token text)
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
  token text := regexp_replace(trim(p_token), '^(YTAMB:|ambassador:|https?://[^ ]*[?&]amb=)', '', 'i');
begin
  perform private.yt_ambassador_assert_work();
  if token ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into v from public.yt_ambassador_passes where pass_code = token::uuid and status = 'issued';
  elsif token ~* '^[0-9a-f]{10}$' then
    select * into v from public.yt_ambassador_passes where reference_code = upper(token) and status = 'issued';
  else
    raise exception 'ambassador_pass_not_found';
  end if;
  if v.id is null then raise exception 'ambassador_pass_not_found'; end if;
  select * into a from public.yt_ambassadors where id = v.ambassador_id and active;
  if a.id is null then raise exception 'ambassador_inactive'; end if;
  if a.member_user_id = auth.uid() or a.work_user_id = auth.uid() then raise exception 'cannot_redeem_own_pass'; end if;
  if d <> v.reservation_day or now() < private.yt_business_start(v.reservation_day) or now() >= private.yt_business_start(v.reservation_day + 1) then
    raise exception 'ambassador_pass_not_valid_today';
  end if;
  pp := private.yt_ambassador_price(v.reservation_day);
  if coalesce((pp->>'male')::numeric, 0) <= 0 or coalesce((pp->>'female')::numeric, 0) <= 0 then
    raise exception 'ambassador_prices_not_configured';
  end if;
  return jsonb_build_object(
    'pass_id', v.id, 'pass_code', v.pass_code, 'reference_code', v.reference_code,
    'reservation_day', v.reservation_day, 'pass_type', v.pass_type, 'planned_pax', v.planned_pax,
    'guest_name', v.guest_name, 'guest_phone', v.guest_phone, 'remark', v.remark,
    'ambassador_name', coalesce(nullif(a.display_name, ''), 'Ambassador'), 'commission_rate', a.commission_rate,
    'male_price', (pp->>'male')::numeric, 'female_price', (pp->>'female')::numeric,
    'checked_pax', (select coalesce(sum(c.male_count + c.female_count), 0) from public.yt_ambassador_checkins c where c.pass_id = v.id),
    'sales', (select coalesce(sum(c.sales), 0) from public.yt_ambassador_checkins c where c.pass_id = v.id),
    'commission', (select coalesce(sum(c.commission_amount), 0) from public.yt_ambassador_checkins c where c.pass_id = v.id)
  );
end;
$function$;

revoke all on function private.yt_ambassador_pass_ref_sync() from public, anon, authenticated;
revoke all on function private.yt_ambassador_pass_lookup(text) from public, anon;
grant execute on function private.yt_ambassador_pass_lookup(text) to authenticated, service_role;
