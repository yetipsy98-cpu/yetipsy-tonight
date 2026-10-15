-- Service Bell stays enabled. Only the Cashier UI announces requests aloud.
update public.yt_play_upgrade_settings
set bell_enabled = true
where id = true;

alter table public.yt_play_upgrade_settings
  alter column bell_enabled set default true;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.yt_play_upgrade_settings'::regclass
      and conname = 'yt_play_upgrade_settings_bell_always_enabled_check'
  ) then
    alter table public.yt_play_upgrade_settings
      add constraint yt_play_upgrade_settings_bell_always_enabled_check
      check (bell_enabled is true);
  end if;
end $$;

create or replace function private.yt_play_bell_settings(p_data jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.yt_play_upgrade_settings%rowtype;
begin
  if not private.yt_work_owner() then raise exception 'owner_only'; end if;
  if p_data is not null then
    update public.yt_play_upgrade_settings set
      invite_min_spend_rm=case when p_data ? 'invite_min_spend_rm' then nullif(p_data->>'invite_min_spend_rm','')::numeric else invite_min_spend_rm end,
      bell_enabled=true,
      bell_lat=case when p_data ? 'bell_lat' then (p_data->>'bell_lat')::double precision else bell_lat end,
      bell_lng=case when p_data ? 'bell_lng' then (p_data->>'bell_lng')::double precision else bell_lng end,
      bell_radius_m=coalesce((p_data->>'bell_radius_m')::integer,bell_radius_m),
      bell_remind_seconds=coalesce((p_data->>'bell_remind_seconds')::integer,bell_remind_seconds),
      bell_complete_seconds=coalesce((p_data->>'bell_complete_seconds')::integer,bell_complete_seconds)
    where id=true;
  end if;
  select * into s from public.yt_play_upgrade_settings where id=true;
  return to_jsonb(s)||jsonb_build_object('bell_enabled',true,'types',
    (select coalesce(jsonb_agg(to_jsonb(t) order by sort_order),'[]'::jsonb)
     from public.yt_play_bell_types t));
end $$;

create or replace function private.yt_play_bell_call(p_table text,p_type text,p_note text,p_lat double precision,p_lng double precision)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.yt_play_upgrade_settings%rowtype;v_id uuid;v_distance double precision;
begin
  if not private.yt_play_customer() then raise exception 'customer_only'; end if;
  select * into s from public.yt_play_upgrade_settings where id=true;
  if s.bell_lat is null or s.bell_lng is null then raise exception 'bell_disabled'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'location_required'; end if;
  v_distance:=6371000*2*asin(sqrt(power(sin(radians(p_lat-s.bell_lat)/2),2)+cos(radians(s.bell_lat))*cos(radians(p_lat))*power(sin(radians(p_lng-s.bell_lng)/2),2)));
  if v_distance>s.bell_radius_m then raise exception 'outside_service_area'; end if;
  if char_length(btrim(coalesce(p_table,''))) not between 1 and 32
    or not exists(select 1 from public.yt_play_bell_types where id=p_type and enabled)
    or char_length(coalesce(p_note,''))>50 then raise exception 'invalid_bell_request'; end if;
  if exists(select 1 from public.yt_play_bell_requests where customer_id=auth.uid() and cancelled_at is null
    and (acknowledged_at is null or acknowledged_at+make_interval(secs=>s.bell_complete_seconds)>clock_timestamp()))
    then raise exception 'bell_already_active'; end if;
  insert into public.yt_play_bell_requests(customer_id,table_label,type_id,note)
    values(auth.uid(),btrim(p_table),p_type,coalesce(p_note,'')) returning id into v_id;
  return jsonb_build_object('id',v_id,'status','pending');
end $$;

create or replace function private.yt_play_bell_config()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('enabled',true,'bell_complete_seconds',s.bell_complete_seconds,'types',
    (select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'zh',t.label_zh,'en',t.label_en) order by t.sort_order),'[]'::jsonb)
     from public.yt_play_bell_types t where t.enabled))
  from public.yt_play_upgrade_settings s where s.id=true and private.yt_play_customer()
$$;
