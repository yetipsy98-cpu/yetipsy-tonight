create or replace function private.yt_pos_custom_owner_history()
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
begin
 if not private.yt_work_owner() then raise exception 'owner_only'; end if;
 return coalesce((
  select jsonb_agg(jsonb_build_object(
   'id',d.id,'name',d.public_name,'customer_id',d.customer_id,
   'customer_name',(select coalesce(nullif(btrim(p.display_name),''),p.phone) from public.profiles p where p.id=d.customer_id),
   'created_by',d.created_by,
   'created_by_name',(select wa.username from public.work_accounts wa where wa.auth_user_id=d.created_by),
   'created_at',d.created_at,
   'versions',(select jsonb_agg(jsonb_build_object(
    'version',v.version,'recipe',v.recipe_snapshot,'cost_rm',v.total_cost_rm,
    'suggested_min_rm',v.suggested_min_rm,'suggested_max_rm',v.suggested_max_rm,
    'quote_rm',v.quote_rm,'changed_by',v.changed_by,
    'changed_by_name',(select wa.username from public.work_accounts wa where wa.auth_user_id=v.changed_by),
    'changed_at',v.changed_at,'change_kind',v.change_kind) order by v.version desc)
    from public.yt_pos_custom_drink_versions v where v.custom_drink_id=d.id)
  ) order by d.created_at desc)
  from public.yt_pos_custom_drinks d
 ),'[]'::jsonb);
end;$function$;
