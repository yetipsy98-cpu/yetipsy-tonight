-- Preserve each saved custom drink version while allowing Owner to revise its recipe.
alter table public.yt_pos_custom_drink_versions
  drop constraint yt_pos_custom_drink_versions_change_kind_check;
alter table public.yt_pos_custom_drink_versions
  add constraint yt_pos_custom_drink_versions_change_kind_check
  check (change_kind = any (array['created'::text, 'repriced'::text, 'edited'::text]));

create or replace function private.yt_pos_custom_update(
  p_id uuid,
  p_name text,
  p_recipe jsonb,
  p_quote numeric
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  d public.yt_pos_custom_drinks%rowtype;
  calc jsonb;
  items jsonb;
  material_id uuid;
  quote_value numeric;
  next_version integer;
begin
  if not private.yt_work_owner() then raise exception 'owner_only'; end if;
  if p_id is null then raise exception 'custom_code_not_found'; end if;
  if length(btrim(coalesce(p_name,''))) not between 2 and 100 then raise exception 'custom_name_invalid'; end if;

  select * into d
  from public.yt_pos_custom_drinks
  where id=p_id
  for update;
  if not found then raise exception 'custom_code_not_found'; end if;

  items:=case when jsonb_typeof(p_recipe)='object' then p_recipe->'items' else p_recipe end;
  if jsonb_typeof(items)<>'array' then raise exception 'custom_recipe_invalid'; end if;
  for material_id in
    select (value->>'material_id')::uuid from jsonb_array_elements(items)
  loop
    if not exists(select 1 from public.yt_pos_custom_materials where id=material_id and active) then
      raise exception 'custom_material_unavailable';
    end if;
  end loop;

  calc:=private.yt_pos_custom_calculate(p_recipe);
  quote_value:=round(p_quote,2);
  if quote_value is null or quote_value<(calc->>'cost_rm')::numeric or quote_value>5000 then
    raise exception 'custom_quote_below_cost';
  end if;
  if not exists(select 1 from public.yt_shop_products where id=d.product_id and category='CUSTOM') then
    raise exception 'custom_product_missing';
  end if;

  -- Backfill a baseline snapshot if an older record predates version tracking.
  if not exists(
    select 1 from public.yt_pos_custom_drink_versions
    where custom_drink_id=d.id and version=d.current_version
  ) then
    insert into public.yt_pos_custom_drink_versions(
      custom_drink_id,version,recipe_snapshot,note,total_cost_rm,
      suggested_min_rm,suggested_max_rm,quote_rm,changed_by,change_kind
    ) values(
      d.id,d.current_version,d.recipe_snapshot,d.note,d.total_cost_rm,
      d.suggested_min_rm,d.suggested_max_rm,d.quote_rm,d.created_by,'created'
    );
  end if;

  select greatest(d.current_version,coalesce(max(version),0))+1
    into next_version
  from public.yt_pos_custom_drink_versions
  where custom_drink_id=d.id;

  update public.yt_shop_products
    set title=btrim(p_name),price_rm=quote_value,updated_at=clock_timestamp()
    where id=d.product_id and category='CUSTOM';
  update public.yt_pos_custom_drinks
    set public_name=btrim(p_name),recipe_snapshot=calc->'recipe',note=calc->>'note',
        total_cost_rm=(calc->>'cost_rm')::numeric,
        suggested_min_rm=(calc->>'suggested_min_rm')::numeric,
        suggested_max_rm=(calc->>'suggested_max_rm')::numeric,
        quote_rm=quote_value,current_version=next_version,updated_at=clock_timestamp()
    where id=d.id
    returning * into d;

  insert into public.yt_pos_custom_drink_versions(
    custom_drink_id,version,recipe_snapshot,note,total_cost_rm,
    suggested_min_rm,suggested_max_rm,quote_rm,changed_by,change_kind
  ) values(
    d.id,next_version,d.recipe_snapshot,d.note,d.total_cost_rm,
    d.suggested_min_rm,d.suggested_max_rm,d.quote_rm,auth.uid(),'edited'
  );

  return jsonb_build_object(
    'ok',true,'id',d.id,'version',d.current_version,
    'product',jsonb_build_object('id',d.product_id,'custom_id',d.id,
      'share_token',d.share_token,'name',d.public_name,'price_rm',d.quote_rm,
      'active',true,'category','CUSTOM','is_drink',true)
  );
end;
$function$;

create or replace function public.yt_pos_custom_update(
  p_id uuid,p_name text,p_recipe jsonb,p_quote numeric
)
returns jsonb
language sql
set search_path to ''
as $function$
  select private.yt_pos_custom_update(p_id,p_name,p_recipe,p_quote);
$function$;

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
        'version',v.version,'recipe',v.recipe_snapshot,'note',v.note,
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

revoke all on function private.yt_pos_custom_update(uuid,text,jsonb,numeric) from public,anon;
grant execute on function private.yt_pos_custom_update(uuid,text,jsonb,numeric) to authenticated;
revoke all on function public.yt_pos_custom_update(uuid,text,jsonb,numeric) from public,anon;
grant execute on function public.yt_pos_custom_update(uuid,text,jsonb,numeric) to authenticated;
