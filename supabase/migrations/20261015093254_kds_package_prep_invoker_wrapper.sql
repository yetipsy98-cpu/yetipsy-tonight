-- Keep authorization in the protected private function and make the API wrapper invoker.
create or replace function public.yt_pos_kds_package_preps(p_orders uuid[])
returns jsonb
language sql
set search_path=''
as $function$
 select private.yt_pos_kds_package_preps(p_orders)
$function$;
revoke all on function public.yt_pos_kds_package_preps(uuid[]) from public,anon;
grant execute on function public.yt_pos_kds_package_preps(uuid[]) to authenticated;
