-- One global margin and maximum discount apply to every custom drink material.
create table if not exists public.yt_pos_custom_pricing_settings (
  id boolean primary key default true check (id),
  margin_percent numeric(5,2) not null check (margin_percent >= 0 and margin_percent < 100),
  max_discount_percent numeric(5,2) not null default 0 check (max_discount_percent between 0 and 100),
  updated_at timestamptz not null default clock_timestamp(),
  updated_by uuid
);
alter table public.yt_pos_custom_pricing_settings enable row level security;
revoke all on public.yt_pos_custom_pricing_settings from anon, authenticated;
insert into public.yt_pos_custom_pricing_settings(id, margin_percent, max_discount_percent)
select true, coalesce(max(margin_percent), 55), coalesce(max(max_discount_percent), 0)
from public.yt_pos_custom_materials
on conflict (id) do nothing;

create or replace function private.yt_pos_custom_settings()
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
declare s public.yt_pos_custom_pricing_settings%rowtype;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only'; end if;
 select * into s from public.yt_pos_custom_pricing_settings where id=true;
 return jsonb_build_object('margin_percent',s.margin_percent,'max_discount_percent',s.max_discount_percent,'updated_at',s.updated_at);
end;$function$;

create or replace function private.yt_pos_custom_settings_save(p_margin_percent numeric,p_max_discount_percent numeric)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare s public.yt_pos_custom_pricing_settings%rowtype; changed boolean;
begin
 if not private.yt_work_owner() then raise exception 'owner_only'; end if;
 if p_margin_percent is null or p_margin_percent<0 or p_margin_percent>=100
    or p_max_discount_percent is null or p_max_discount_percent<0 or p_max_discount_percent>100 then
   raise exception 'custom_settings_invalid';
 end if;
 select * into s from public.yt_pos_custom_pricing_settings where id=true for update;
 changed:=s.margin_percent is distinct from p_margin_percent or s.max_discount_percent is distinct from p_max_discount_percent;
 update public.yt_pos_custom_pricing_settings set margin_percent=p_margin_percent,
  max_discount_percent=p_max_discount_percent,updated_at=clock_timestamp(),updated_by=auth.uid() where id=true returning * into s;
 if changed then
  update public.yt_pos_custom_materials set margin_percent=p_margin_percent,min_discount_percent=0,
   max_discount_percent=p_max_discount_percent,price_revision=price_revision+1,updated_at=clock_timestamp();
 end if;
 return jsonb_build_object('margin_percent',s.margin_percent,'max_discount_percent',s.max_discount_percent,'updated_at',s.updated_at);
end;$function$;

create or replace function private.yt_pos_custom_material_save_v2(
 p_id uuid,p_name text,p_unit_cost numeric,p_active boolean
) returns jsonb language plpgsql security definer set search_path=''
as $function$
declare m public.yt_pos_custom_materials%rowtype; s public.yt_pos_custom_pricing_settings%rowtype;
begin
 if not private.yt_work_owner() then raise exception 'owner_only'; end if;
 if length(btrim(coalesce(p_name,''))) not between 1 and 80 or p_unit_cost is null or p_unit_cost<0 then
  raise exception 'custom_material_invalid';
 end if;
 select * into s from public.yt_pos_custom_pricing_settings where id=true;
 if p_id is null then
  insert into public.yt_pos_custom_materials(name,unit_cost_rm,margin_percent,min_discount_percent,max_discount_percent,active)
  values(btrim(p_name),p_unit_cost,s.margin_percent,0,s.max_discount_percent,coalesce(p_active,true)) returning * into m;
 else
  update public.yt_pos_custom_materials set name=btrim(p_name),unit_cost_rm=p_unit_cost,
   margin_percent=s.margin_percent,min_discount_percent=0,max_discount_percent=s.max_discount_percent,
   active=coalesce(p_active,true),
   price_revision=price_revision+case when name is distinct from btrim(p_name)
    or unit_cost_rm is distinct from p_unit_cost or active is distinct from coalesce(p_active,true) then 1 else 0 end,
   updated_at=clock_timestamp() where id=p_id returning * into m;
  if not found then raise exception 'custom_material_unavailable'; end if;
 end if;
 return jsonb_build_object('id',m.id,'name',m.name,'unit_cost_rm',m.unit_cost_rm,'active',m.active,'price_revision',m.price_revision);
end;$function$;

create or replace function private.yt_pos_custom_materials()
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'unit_cost_rm',unit_cost_rm,
  'active',active,'price_revision',price_revision) order by active desc,name) from public.yt_pos_custom_materials
  where active or private.yt_work_owner()),'[]'::jsonb);
end;$function$;

create or replace function private.yt_pos_custom_calculate(p_recipe jsonb)
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
declare e jsonb; m public.yt_pos_custom_materials%rowtype; s public.yt_pos_custom_pricing_settings%rowtype; q integer;
 v_recipe jsonb:='[]'::jsonb; v_cost numeric:=0; v_base numeric:=0; line_base numeric;
begin
 if jsonb_typeof(p_recipe)<>'array' or jsonb_array_length(p_recipe)<1 or jsonb_array_length(p_recipe)>40 then raise exception 'custom_recipe_invalid'; end if;
 select * into s from public.yt_pos_custom_pricing_settings where id=true;
 for e in select value from jsonb_array_elements(p_recipe) loop
  begin q:=(e->>'quantity')::integer; exception when others then raise exception 'custom_recipe_invalid'; end;
  if q<1 or q>50 then raise exception 'custom_recipe_invalid'; end if;
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

create or replace function private.yt_pos_custom_create(p_name text,p_recipe jsonb,p_quote numeric)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare calc jsonb; pid uuid; d public.yt_pos_custom_drinks%rowtype; quote numeric;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only'; end if;
 if length(btrim(coalesce(p_name,''))) not between 2 and 100 then raise exception 'custom_name_invalid'; end if;
 for pid in select (value->>'material_id')::uuid from jsonb_array_elements(p_recipe) loop
  if not exists(select 1 from public.yt_pos_custom_materials where id=pid and active) then raise exception 'custom_material_unavailable'; end if;
 end loop;
 calc:=private.yt_pos_custom_calculate(p_recipe); quote:=round(p_quote,2);
 if quote is null or quote<(calc->>'suggested_min_rm')::numeric or quote>5000 then raise exception 'custom_quote_below_cost'; end if;
 insert into public.yt_shop_products(title,category,price_rm,redeem_points,active,sort_order,series_id,is_drink)
 values(btrim(p_name),'CUSTOM',quote,null,true,999999,null,true) returning id into pid;
 insert into public.yt_pos_custom_drinks(product_id,public_name,recipe_snapshot,total_cost_rm,suggested_min_rm,suggested_max_rm,quote_rm,created_by)
 values(pid,btrim(p_name),calc->'recipe',(calc->>'cost_rm')::numeric,(calc->>'suggested_min_rm')::numeric,
  (calc->>'suggested_max_rm')::numeric,quote,auth.uid()) returning * into d;
 insert into public.yt_pos_custom_drink_versions(custom_drink_id,version,recipe_snapshot,total_cost_rm,
  suggested_min_rm,suggested_max_rm,quote_rm,changed_by,change_kind)
 values(d.id,1,d.recipe_snapshot,d.total_cost_rm,d.suggested_min_rm,d.suggested_max_rm,d.quote_rm,auth.uid(),'created');
 return jsonb_build_object('ok',true,'id',d.id,'product_id',d.product_id,'share_token',d.share_token,
  'name',d.public_name,'price_rm',d.quote_rm,'cost_rm',d.total_cost_rm,
  'suggested_min_rm',d.suggested_min_rm,'suggested_max_rm',d.suggested_max_rm,'active',true,'category','CUSTOM','is_drink',true);
end;$function$;

create or replace function private.yt_pos_custom_reprice(p_token uuid,p_quote numeric)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare d public.yt_pos_custom_drinks%rowtype; calc jsonb; q numeric; v integer;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only'; end if;
 select * into d from public.yt_pos_custom_drinks where share_token=p_token for update;
 if not found then raise exception 'custom_code_not_found'; end if;
 calc:=private.yt_pos_custom_calculate(d.recipe_snapshot); q:=round(p_quote,2);
 if q is null or q<(calc->>'suggested_min_rm')::numeric or q>5000 then raise exception 'custom_quote_below_cost'; end if;
 v:=d.current_version+1;
 update public.yt_shop_products set price_rm=q,updated_at=clock_timestamp() where id=d.product_id and category='CUSTOM';
 update public.yt_pos_custom_drinks set recipe_snapshot=calc->'recipe',total_cost_rm=(calc->>'cost_rm')::numeric,
  suggested_min_rm=(calc->>'suggested_min_rm')::numeric,suggested_max_rm=(calc->>'suggested_max_rm')::numeric,
  quote_rm=q,current_version=v,updated_at=clock_timestamp() where id=d.id returning * into d;
 insert into public.yt_pos_custom_drink_versions(custom_drink_id,version,recipe_snapshot,total_cost_rm,
  suggested_min_rm,suggested_max_rm,quote_rm,changed_by,change_kind)
 values(d.id,v,d.recipe_snapshot,d.total_cost_rm,d.suggested_min_rm,d.suggested_max_rm,d.quote_rm,auth.uid(),'repriced');
 return jsonb_build_object('ok',true,'id',d.id,'product',jsonb_build_object('id',d.product_id,'custom_id',d.id,'share_token',d.share_token,
  'name',d.public_name,'price_rm',d.quote_rm,'active',true,'category','CUSTOM','is_drink',false));
end;$function$;

create or replace function public.yt_pos_custom_settings()
returns jsonb language sql set search_path=''
as $function$ select private.yt_pos_custom_settings(); $function$;
create or replace function public.yt_pos_custom_settings_save(p_margin_percent numeric,p_max_discount_percent numeric)
returns jsonb language sql set search_path=''
as $function$ select private.yt_pos_custom_settings_save(p_margin_percent,p_max_discount_percent); $function$;
create or replace function public.yt_pos_custom_material_save_v2(p_id uuid,p_name text,p_unit_cost numeric,p_active boolean)
returns jsonb language sql set search_path=''
as $function$ select private.yt_pos_custom_material_save_v2(p_id,p_name,p_unit_cost,p_active); $function$;
revoke all on function public.yt_pos_custom_settings(),public.yt_pos_custom_settings_save(numeric,numeric),
 public.yt_pos_custom_material_save_v2(uuid,text,numeric,boolean) from public,anon;
grant execute on function public.yt_pos_custom_settings(),public.yt_pos_custom_settings_save(numeric,numeric),
 public.yt_pos_custom_material_save_v2(uuid,text,numeric,boolean) to authenticated;
revoke all on function private.yt_pos_custom_settings(),private.yt_pos_custom_settings_save(numeric,numeric),
 private.yt_pos_custom_material_save_v2(uuid,text,numeric,boolean),private.yt_pos_custom_create(text,jsonb,numeric),
 private.yt_pos_custom_reprice(uuid,numeric),private.yt_pos_custom_calculate(jsonb) from public,anon,authenticated;
