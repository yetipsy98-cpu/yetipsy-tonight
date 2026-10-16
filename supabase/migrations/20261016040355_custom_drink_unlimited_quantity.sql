-- Allow cashiers to enter any positive whole-number quantity for each material.
-- The UI and database intentionally impose no per-material quantity ceiling.
create or replace function private.yt_pos_custom_calculate(p_recipe jsonb)
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
declare e jsonb; m public.yt_pos_custom_materials%rowtype; s public.yt_pos_custom_pricing_settings%rowtype; q numeric;
 v_recipe jsonb:='[]'::jsonb; v_cost numeric:=0; v_base numeric:=0; line_base numeric;
begin
 if coalesce(jsonb_typeof(p_recipe),'')<>'array' then raise exception 'custom_recipe_invalid'; end if;
 if jsonb_array_length(p_recipe)<1 then raise exception 'custom_recipe_invalid'; end if;
 select * into s from public.yt_pos_custom_pricing_settings where id=true;
 for e in select value from jsonb_array_elements(p_recipe) loop
  begin q:=(e->>'quantity')::numeric; exception when others then raise exception 'custom_recipe_invalid'; end;
  if q<1 or q<>trunc(q) then raise exception 'custom_recipe_invalid'; end if;
  select * into m from public.yt_pos_custom_materials where id=(e->>'material_id')::uuid;
  if not found then raise exception 'custom_material_unavailable'; end if;
  line_base:=m.unit_cost_rm*q/(1-s.margin_percent/100);
  v_cost:=v_cost+m.unit_cost_rm*q; v_base:=v_base+line_base;
  v_recipe:=v_recipe||jsonb_build_array(jsonb_build_object(
   'material_id',m.id,'name',m.name,'quantity',q,'unit_cost_rm',m.unit_cost_rm,
   'margin_percent',s.margin_percent,'min_discount_percent',0,
   'max_discount_percent',s.max_discount_percent,'price_revision',m.price_revision));
 end loop;
 return jsonb_build_object('recipe',v_recipe,'cost_rm',round(v_cost,2),
  'suggested_min_rm',greatest(round(v_base*(1-s.max_discount_percent/100),2),round(v_cost,2)),
  'suggested_max_rm',round(v_base,2));
end;$function$;
revoke all on function private.yt_pos_custom_calculate(jsonb) from public,anon,authenticated;
