ALTER TABLE public.yt_pos_custom_drinks
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

CREATE OR REPLACE FUNCTION private.yt_pos_custom_delete(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare d public.yt_pos_custom_drinks%rowtype;
begin
  if not private.yt_work_owner() then raise exception 'owner_only'; end if;
  select * into d
  from public.yt_pos_custom_drinks
  where id=p_id and deleted_at is null
  for update;
  if not found then
    return jsonb_build_object('ok',false,'error_code','custom_not_found');
  end if;
  update public.yt_pos_custom_drinks
     set deleted_at=clock_timestamp(),updated_at=clock_timestamp()
   where id=d.id;
  update public.yt_shop_products
     set active=false,updated_at=clock_timestamp()
   where id=d.product_id and category='CUSTOM';
  return jsonb_build_object('ok',true,'id',d.id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.yt_pos_custom_delete(p_id uuid)
RETURNS jsonb
LANGUAGE sql
SET search_path TO ''
AS $function$
  select private.yt_pos_custom_delete(p_id);
$function$;
REVOKE ALL ON FUNCTION private.yt_pos_custom_delete(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.yt_pos_custom_delete(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.yt_pos_custom_delete(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.yt_pos_custom_delete(uuid) TO authenticated;

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
    where d.deleted_at is null
  ),'[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_custom_cashier_history()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
begin
 if not (private.yt_work_owner() or private.yt_pos_work_cashier()) then raise exception 'cashier_only'; end if;
 return coalesce((
  select jsonb_agg(jsonb_build_object(
   'id',d.id,'name',d.public_name,'note',d.note,'share_token',d.share_token,
   'created_by',d.created_by,
   'created_by_name',(select wa.username from public.work_accounts wa where wa.auth_user_id=d.created_by),
   'created_at',d.created_at,'current_version',d.current_version,
   'customer_count',(select count(*) from public.yt_pos_custom_drink_members m where m.custom_drink_id=d.id),
   'current_recipe',(select coalesce(jsonb_agg(jsonb_build_object(
      'material_id',x->'material_id','name',x->'name','quantity',x->'quantity',
      'note',x->'note','charge_full_bottle',x->'charge_full_bottle'
    )),'[]'::jsonb) from jsonb_array_elements(coalesce(d.recipe_snapshot,'[]'::jsonb)) x),
   'current_note',d.note,'current_quote_rm',d.quote_rm,
   'versions',(select jsonb_agg(jsonb_build_object(
    'version',v.version,'name',v.public_name,
    'recipe',(select coalesce(jsonb_agg(jsonb_build_object(
      'material_id',x->'material_id','name',x->'name','quantity',x->'quantity',
      'note',x->'note','charge_full_bottle',x->'charge_full_bottle'
    )),'[]'::jsonb) from jsonb_array_elements(coalesce(v.recipe_snapshot,'[]'::jsonb)) x),
    'note',v.note,'quote_rm',v.quote_rm,'changed_by',v.changed_by,
    'changed_by_name',(select wa.username from public.work_accounts wa where wa.auth_user_id=v.changed_by),
    'changed_at',v.changed_at,'change_kind',v.change_kind
   ) order by v.version desc) from public.yt_pos_custom_drink_versions v where v.custom_drink_id=d.id)
  ) order by d.created_at desc)
  from public.yt_pos_custom_drinks d
  where d.deleted_at is null
 ),'[]'::jsonb);
end;
$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_custom_scan(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
declare d public.yt_pos_custom_drinks%rowtype; calc jsonb; stale boolean;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only'; end if;
 select * into d from public.yt_pos_custom_drinks where share_token=p_token and deleted_at is null;
 if not found then raise exception 'custom_code_not_found'; end if;
 calc:=private.yt_pos_custom_calculate(d.recipe_snapshot);
 select exists(select 1 from jsonb_array_elements(d.recipe_snapshot) old
  join public.yt_pos_custom_materials cur on cur.id=(old->>'material_id')::uuid
  where (old->>'price_revision')::integer<>cur.price_revision) into stale;
 if stale then return jsonb_build_object('ok',false,'error_code','custom_reprice_required','id',d.id,
  'name',d.public_name,'suggested_min_rm',calc->'suggested_min_rm','suggested_max_rm',calc->'suggested_max_rm'); end if;
 return jsonb_build_object('ok',true,'product',jsonb_build_object('id',d.product_id,'custom_id',d.id,
  'share_token',d.share_token,'name',d.public_name,'price_rm',d.quote_rm,'active',true,'category','CUSTOM','is_drink',false),
  'name',d.public_name);
end;
$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_custom_reprice(p_token uuid, p_quote numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare d public.yt_pos_custom_drinks%rowtype; calc jsonb; q numeric; v integer;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only'; end if;
 select * into d from public.yt_pos_custom_drinks where share_token=p_token and deleted_at is null for update;
 if not found then raise exception 'custom_code_not_found'; end if;
 calc:=private.yt_pos_custom_calculate(d.recipe_snapshot); q:=round(p_quote,2);
 if q is null or q<(calc->>'cost_rm')::numeric or q>5000 then raise exception 'custom_quote_below_cost'; end if;
 v:=d.current_version+1;
 update public.yt_shop_products set price_rm=q,updated_at=clock_timestamp() where id=d.product_id and category='CUSTOM';
 update public.yt_pos_custom_drinks set recipe_snapshot=calc->'recipe',total_cost_rm=(calc->>'cost_rm')::numeric,
  suggested_min_rm=(calc->>'suggested_min_rm')::numeric,suggested_max_rm=(calc->>'suggested_max_rm')::numeric,
  quote_rm=q,current_version=v,updated_at=clock_timestamp() where id=d.id returning * into d;
 insert into public.yt_pos_custom_drink_versions(custom_drink_id,version,recipe_snapshot,note,total_cost_rm,
  suggested_min_rm,suggested_max_rm,quote_rm,changed_by,change_kind)
 values(d.id,v,d.recipe_snapshot,d.note,d.total_cost_rm,d.suggested_min_rm,d.suggested_max_rm,d.quote_rm,auth.uid(),'repriced');
 return jsonb_build_object('ok',true,'id',d.id,'product',jsonb_build_object('id',d.product_id,'custom_id',d.id,
  'share_token',d.share_token,'name',d.public_name,'price_rm',d.quote_rm,'active',true,'category','CUSTOM','is_drink',false));
end;
$function$;

CREATE OR REPLACE FUNCTION private.yt_pos_custom_my_list()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
 select coalesce(jsonb_agg(jsonb_build_object('name',d.public_name,'created_at',d.created_at,
  'share_token',d.share_token,'last_updated_at',d.updated_at) order by d.created_at desc),'[]'::jsonb)
 from public.yt_pos_custom_drinks d
 where d.deleted_at is null and (
   d.customer_id=auth.uid()
   or exists(select 1 from public.yt_pos_custom_drink_members m where m.custom_drink_id=d.id and m.customer_id=auth.uid())
 );
$function$;
