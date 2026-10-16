-- Keep the display name with every immutable custom-drink version.
alter table public.yt_pos_custom_drink_versions
  add column if not exists public_name text not null default '';

-- No custom recipe edits existed before versioned editing, so the current name is
-- the accurate name for every existing version row.
update public.yt_pos_custom_drink_versions v
set public_name=d.public_name
from public.yt_pos_custom_drinks d
where d.id=v.custom_drink_id and v.public_name='';

create or replace function private.yt_pos_custom_version_fill_name()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if btrim(coalesce(new.public_name,''))='' then
    select d.public_name into new.public_name
    from public.yt_pos_custom_drinks d
    where d.id=new.custom_drink_id;
  end if;
  return new;
end;
$function$;

drop trigger if exists yt_pos_custom_version_fill_name on public.yt_pos_custom_drink_versions;
create trigger yt_pos_custom_version_fill_name
before insert on public.yt_pos_custom_drink_versions
for each row execute function private.yt_pos_custom_version_fill_name();

create or replace function private.yt_pos_custom_owner_history()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if not private.yt_work_owner() then raise exception 'owner_only'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',d.id,'name',d.public_name,'note',d.note,'customer_id',d.customer_id,
      'customer_name',(select coalesce(nullif(btrim(p.display_name),''),p.phone) from public.profiles p where p.id=d.customer_id),
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

create or replace function public.yt_pos_custom_owner_history()
returns jsonb
language sql
set search_path to ''
as $function$
  select private.yt_pos_custom_owner_history();
$function$;
