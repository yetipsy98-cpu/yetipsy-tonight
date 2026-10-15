-- Allow the customer to call again 30 seconds after staff confirmation.
update public.yt_play_upgrade_settings
set bell_complete_seconds = 30
where id = true;

-- The customer UI uses the same server configured cooldown for its live status.
create or replace function private.yt_play_bell_config()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'enabled',s.bell_enabled,
  'bell_complete_seconds',s.bell_complete_seconds,
  'types',(select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'zh',t.label_zh,'en',t.label_en) order by t.sort_order),'[]'::jsonb)
   from public.yt_play_bell_types t where t.enabled)
 )
 from public.yt_play_upgrade_settings s
 where s.id=true and private.yt_play_customer()
$$;
