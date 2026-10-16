-- Expose the safe reusable short code and shared-member count to the Owner history view.
CREATE OR REPLACE FUNCTION private.yt_pos_custom_owner_history()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
begin
  if not private.yt_work_owner() then raise exception 'owner_only'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',d.id,'name',d.public_name,'note',d.note,'customer_id',d.customer_id,
      'customer_name',(select coalesce(nullif(btrim(p.display_name),''),p.phone) from public.profiles p where p.id=d.customer_id),
      'share_token',d.share_token,
      'customer_count',(select count(*) from public.yt_pos_custom_drink_members m where m.custom_drink_id=d.id),
      'created_by',d.created_by,'created_by_name',(select wa.username from public.work_accounts wa where wa.auth_user_id=d.created_by),
      'created_at',d.created_at,'current_version',d.current_version,'current_recipe',d.recipe_snapshot,
      'current_note',d.note,'current_cost_rm',d.total_cost_rm,
      'current_suggested_min_rm',d.suggested_min_rm,'current_suggested_max_rm',d.suggested_max_rm,
      'current_quote_rm',d.quote_rm,
      'versions',(select jsonb_agg(jsonb_build_object(
        'version',v.version,'name',v.public_name,'recipe',v.recipe_snapshot,'note',v.note,
        'cost_rm',v.total_cost_rm,'suggested_min_rm',v.suggested_min_rm,
        'suggested_max_rm',v.suggested_max_rm,'quote_rm',v.quote_rm,
        'changed_by',v.changed_by,
        'changed_by_name',(select wa.username from public.work_accounts wa where wa.auth_user_id=v.changed_by),
        'changed_at',v.changed_at,'change_kind',v.change_kind
      ) order by v.version desc) from public.yt_pos_custom_drink_versions v where v.custom_drink_id=d.id)
    ) order by d.created_at desc)
    from public.yt_pos_custom_drinks d
  ),'[]'::jsonb);
end;
$function$;
