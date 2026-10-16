create table if not exists public.yt_pos_refresh_settings (
  id boolean primary key default true check (id),
  enabled boolean not null default true,
  start_time text not null default '18:30' check (start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  end_time text not null default '00:30' check (end_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  interval_seconds integer not null default 15 check (interval_seconds in (15,30,60,120,300)),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.yt_pos_refresh_settings enable row level security;
revoke all on table public.yt_pos_refresh_settings from public, anon, authenticated;
insert into public.yt_pos_refresh_settings (id) values (true) on conflict (id) do nothing;

create or replace function private.yt_pos_refresh_schedule(p_data jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  s public.yt_pos_refresh_settings%rowtype;
  v_enabled boolean;
  v_start text;
  v_end text;
  v_interval integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;

  if p_data is null then
    if not (private.yt_pos_work_staff() or private.yt_pos_work_cashier() or private.yt_work_owner()) then
      raise exception 'staff_only';
    end if;
    select * into s from public.yt_pos_refresh_settings where id=true;
    return jsonb_build_object(
      'enabled', s.enabled,
      'start_time', s.start_time,
      'end_time', s.end_time,
      'interval_seconds', s.interval_seconds,
      'updated_at', s.updated_at
    );
  end if;

  if not private.yt_work_owner() then raise exception 'owner_only'; end if;
  if coalesce(p_data->>'enabled','') not in ('true','false') then raise exception 'invalid_refresh_schedule'; end if;
  v_enabled := (p_data->>'enabled')::boolean;
  v_start := p_data->>'start_time';
  v_end := p_data->>'end_time';
  if v_start is null or v_start !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or v_end is null or v_end !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or v_start = v_end then
    raise exception 'invalid_refresh_schedule';
  end if;
  if coalesce(p_data->>'interval_seconds','') !~ '^(15|30|60|120|300)$' then
    raise exception 'invalid_refresh_schedule';
  end if;
  v_interval := (p_data->>'interval_seconds')::integer;

  insert into public.yt_pos_refresh_settings (id,enabled,start_time,end_time,interval_seconds,updated_at,updated_by)
  values (true,v_enabled,v_start,v_end,v_interval,now(),auth.uid())
  on conflict (id) do update set
    enabled=excluded.enabled,
    start_time=excluded.start_time,
    end_time=excluded.end_time,
    interval_seconds=excluded.interval_seconds,
    updated_at=excluded.updated_at,
    updated_by=excluded.updated_by
  returning * into s;

  return jsonb_build_object(
    'enabled', s.enabled,
    'start_time', s.start_time,
    'end_time', s.end_time,
    'interval_seconds', s.interval_seconds,
    'updated_at', s.updated_at
  );
end;
$function$;

create or replace function public.yt_pos_refresh_schedule(p_data jsonb default null)
returns jsonb
language sql
security invoker
set search_path = ''
as $function$
  select private.yt_pos_refresh_schedule(p_data);
$function$;

revoke execute on function private.yt_pos_refresh_schedule(jsonb) from public, anon;
revoke execute on function public.yt_pos_refresh_schedule(jsonb) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.yt_pos_refresh_schedule(jsonb) to authenticated;
grant execute on function public.yt_pos_refresh_schedule(jsonb) to authenticated;