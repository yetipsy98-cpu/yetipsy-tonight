-- Guest service requests remain isolated by a browser-held bearer credential.
-- The two GPS policies default to the existing on-site-only behavior.
alter table public.yt_play_upgrade_settings
 add column bell_gps_required boolean not null default true,
 add column freeflow_gps_required boolean not null default true;

create table public.yt_play_bell_guests(
 id uuid primary key default gen_random_uuid(),
 token_hash text not null unique,
 created_at timestamptz not null default clock_timestamp()
);
alter table public.yt_play_bell_guests enable row level security;
revoke all on public.yt_play_bell_guests from public,anon,authenticated;
alter table public.yt_play_bell_requests alter column customer_id drop not null;
alter table public.yt_play_bell_requests add column guest_id uuid references public.yt_play_bell_guests(id);
alter table public.yt_play_bell_requests add constraint bell_one_principal check(num_nonnulls(customer_id,guest_id)=1);
create unique index yt_play_one_pending_guest_bell on public.yt_play_bell_requests(guest_id)
 where acknowledged_at is null and cancelled_at is null;
create index yt_play_bell_guest_history on public.yt_play_bell_requests(guest_id,created_at desc);

create function private.yt_play_bell_call_actor(p_actor uuid,p_guest boolean,p_table text,p_type text,p_note text,p_lat double precision,p_lng double precision)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare s public.yt_play_upgrade_settings%rowtype;v_id uuid;v_distance double precision;
begin
 if p_actor is null then raise exception 'not_authenticated';end if;
 perform pg_advisory_xact_lock(hashtextextended('yt-service-bell:'||p_actor::text,0));
 select * into strict s from public.yt_play_upgrade_settings where id=true;
 if s.bell_gps_required then
  if s.bell_lat is null or s.bell_lng is null then raise exception 'bell_disabled';end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'location_required';end if;
  v_distance:=6371000*2*asin(least(1,sqrt(power(sin(radians(p_lat-s.bell_lat)/2),2)+cos(radians(s.bell_lat))*cos(radians(p_lat))*power(sin(radians(p_lng-s.bell_lng)/2),2))));
  if v_distance>s.bell_radius_m then raise exception 'outside_service_area';end if;
 end if;
 if char_length(btrim(coalesce(p_table,''))) not between 1 and 32
  or not exists(select 1 from public.yt_play_bell_types where id=p_type and enabled)
  or char_length(coalesce(p_note,''))>50 then raise exception 'invalid_bell_request';end if;
 if exists(select 1 from public.yt_play_bell_requests where
  ((p_guest and guest_id=p_actor) or (not p_guest and customer_id=p_actor)) and cancelled_at is null
  and (acknowledged_at is null or acknowledged_at+make_interval(secs=>s.bell_complete_seconds)>clock_timestamp()))
 then raise exception 'bell_already_active';end if;
 insert into public.yt_play_bell_requests(customer_id,guest_id,table_label,type_id,note)
 values(case when not p_guest then p_actor end,case when p_guest then p_actor end,btrim(p_table),p_type,coalesce(p_note,'')) returning id into v_id;
 return jsonb_build_object('id',v_id,'status','pending');
end$$;
revoke all on function private.yt_play_bell_call_actor(uuid,boolean,text,text,text,double precision,double precision) from public,anon,authenticated;

create or replace function private.yt_play_bell_call(p_table text,p_type text,p_note text,p_lat double precision,p_lng double precision)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.yt_play_customer() then raise exception 'customer_only';end if;
 return private.yt_play_bell_call_actor(auth.uid(),false,p_table,p_type,p_note,p_lat,p_lng);
end$$;

-- Keep all existing Owner settings and grants, adding independent GPS flags.
do $$declare d text;needle text:='bell_enabled=true,';begin
 select pg_get_functiondef('private.yt_play_bell_settings(jsonb)'::regprocedure) into d;
 if strpos(d,needle)=0 then raise exception 'bell_settings_patch_missing';end if;
 execute replace(d,needle,needle||E'\n bell_gps_required=case when p_data ? ''bell_gps_required'' then (p_data->>''bell_gps_required'')::boolean else bell_gps_required end,\n freeflow_gps_required=case when p_data ? ''freeflow_gps_required'' then (p_data->>''freeflow_gps_required'')::boolean else freeflow_gps_required end,');
end$$;

-- No schema-wide anon permission is added to the existing private schema.
create function freeflow_api.location_config() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('bell_gps_required',bell_gps_required,'freeflow_gps_required',freeflow_gps_required)
 from public.yt_play_upgrade_settings where id=true
$$;
create function public.yt_play_location_config() returns jsonb
language sql stable security invoker set search_path='' as $$select freeflow_api.location_config()$$;
create function freeflow_api.bell_config() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('enabled',true,'gps_required',s.bell_gps_required,'bell_complete_seconds',s.bell_complete_seconds,'types',
  (select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'zh',t.label_zh,'en',t.label_en) order by t.sort_order),'[]'::jsonb)
   from public.yt_play_bell_types t where t.enabled))
 from public.yt_play_upgrade_settings s where s.id=true
$$;
create or replace function public.yt_play_bell_config() returns jsonb
language sql stable security invoker set search_path='' as $$select freeflow_api.bell_config()$$;
revoke all on function freeflow_api.location_config(),public.yt_play_location_config(),freeflow_api.bell_config(),public.yt_play_bell_config() from public,anon,authenticated;
grant execute on function freeflow_api.location_config(),public.yt_play_location_config(),freeflow_api.bell_config(),public.yt_play_bell_config() to anon,authenticated;

create function freeflow_api.bell_guest(p_action text,p_credential uuid,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare g public.yt_play_bell_guests%rowtype;v_hash text;v_id uuid;s public.yt_play_upgrade_settings%rowtype;
begin
 if p_credential is null or p_action is null or p_action not in ('list','call','cancel') then raise exception 'invalid_bell_request';end if;
 v_hash:=private.yt_play_hash(p_credential);
 perform pg_advisory_xact_lock(hashtextextended('yt-bell-credential:'||v_hash,0));
 select * into g from public.yt_play_bell_guests where token_hash=v_hash;
 if not found then
  if p_action='list' then return '[]'::jsonb;end if;
  if p_action<>'call' then raise exception 'bell_request_not_cancellable';end if;
  insert into public.yt_play_bell_guests(token_hash) values(v_hash) returning * into g;
 end if;
 if p_action='call' then
  return private.yt_play_bell_call_actor(g.id,true,p_data->>'table',p_data->>'type',p_data->>'note',(p_data->>'lat')::double precision,(p_data->>'lng')::double precision);
 elsif p_action='cancel' then
  update public.yt_play_bell_requests set cancelled_at=clock_timestamp()
   where id=(p_data->>'id')::uuid and guest_id=g.id and acknowledged_at is null and cancelled_at is null returning id into v_id;
  if not found then raise exception 'bell_request_not_cancellable';end if;
  return jsonb_build_object('id',v_id,'status','cancelled');
 end if;
 select * into strict s from public.yt_play_upgrade_settings where id=true;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'table',r.table_label,'type',r.type_id,
  'created_at',r.created_at,'acknowledged_at',r.acknowledged_at,'cancelled_at',r.cancelled_at,
  'status',case when r.cancelled_at is not null then 'cancelled' when r.acknowledged_at is null then 'pending'
   when r.acknowledged_at+make_interval(secs=>s.bell_complete_seconds)>clock_timestamp() then 'acknowledged' else 'completed' end)
  order by r.created_at desc) from public.yt_play_bell_requests r where r.guest_id=g.id and r.created_at>clock_timestamp()-interval '24 hours'),'[]'::jsonb);
end$$;
create function public.yt_play_bell_guest(p_action text,p_credential uuid,p_data jsonb default '{}') returns jsonb
language sql security invoker set search_path='' as $$select freeflow_api.bell_guest(p_action,p_credential,p_data)$$;
revoke all on function freeflow_api.bell_guest(text,uuid,jsonb),public.yt_play_bell_guest(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function freeflow_api.bell_guest(text,uuid,jsonb),public.yt_play_bell_guest(text,uuid,jsonb) to anon,authenticated;

-- Wrap only the GPS block; entitlement, payment, time and one-cup checks still apply.
do $$declare d text;start_text text:='  if cfg.bell_lat is null or cfg.bell_lng is null then';end_text text:='  if distance_m>cfg.bell_radius_m then raise exception ''outside_service_area'';end if;';begin
 select pg_get_functiondef('private.yt_freeflow_core(uuid,boolean,text,jsonb)'::regprocedure) into d;
 if strpos(d,start_text)=0 or strpos(d,end_text)=0 then raise exception 'freeflow_gps_patch_missing';end if;
 d:=replace(d,start_text,E'  if cfg.freeflow_gps_required then\n'||start_text);
 d:=replace(d,end_text,end_text||E'\n  end if;');
 execute d;
end$$;

do $$declare d text;needle text:='public.yt_play_bell_requests restart identity';begin
 select pg_get_functiondef('private.yt_owner_reset_v9(uuid,text,text,uuid,uuid,bigint[],text[])'::regprocedure) into d;
 if strpos(d,needle)=0 then raise exception 'bell_guest_reset_patch_missing';end if;
 execute replace(d,needle,'public.yt_play_bell_requests,public.yt_play_bell_guests restart identity');
end$$;
