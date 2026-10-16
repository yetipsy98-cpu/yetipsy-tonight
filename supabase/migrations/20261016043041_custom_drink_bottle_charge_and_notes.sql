-- Custom drink full-bottle ingredient pricing and private order/ingredient notes.
alter table public.yt_pos_custom_materials
  add column if not exists charge_full_bottle boolean not null default false;
alter table public.yt_pos_custom_drinks
  add column if not exists note text not null default '';
alter table public.yt_pos_custom_drink_versions
  add column if not exists note text not null default '';

-- Return selling-price components to staff. Raw ingredient cost is only included for Owner.
create or replace function private.yt_pos_custom_materials()
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
declare s public.yt_pos_custom_pricing_settings%rowtype;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only'; end if;
 select * into s from public.yt_pos_custom_pricing_settings where id=true;
 return coalesce((
  select jsonb_agg(
   jsonb_build_object(
    'id',m.id,'name',m.name,'active',m.active,'price_revision',m.price_revision,
    'charge_full_bottle',m.charge_full_bottle,
    'unit_suggested_rm',m.unit_cost_rm/(1-s.margin_percent/100),
    'unit_minimum_rm',greatest(m.unit_cost_rm,(m.unit_cost_rm/(1-s.margin_percent/100))*(1-s.max_discount_percent/100))
   ) || case when private.yt_work_owner() then jsonb_build_object('unit_cost_rm',m.unit_cost_rm) else '{}'::jsonb end
   order by m.active desc,m.name
  )
  from public.yt_pos_custom_materials m where m.active or private.yt_work_owner()
 ),'[]'::jsonb);
end;$function$;

create or replace function private.yt_pos_custom_material_save_v3(
 p_id uuid,p_name text,p_unit_cost numeric,p_active boolean,p_charge_full_bottle boolean
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
  insert into public.yt_pos_custom_materials(name,unit_cost_rm,margin_percent,min_discount_percent,max_discount_percent,active,charge_full_bottle)
  values(btrim(p_name),p_unit_cost,s.margin_percent,0,s.max_discount_percent,coalesce(p_active,true),coalesce(p_charge_full_bottle,false))
  returning * into m;
 else
  update public.yt_pos_custom_materials set name=btrim(p_name),unit_cost_rm=p_unit_cost,
   margin_percent=s.margin_percent,min_discount_percent=0,max_discount_percent=s.max_discount_percent,
   active=coalesce(p_active,true),charge_full_bottle=coalesce(p_charge_full_bottle,false),
   price_revision=price_revision+case when name is distinct from btrim(p_name)
    or unit_cost_rm is distinct from p_unit_cost or active is distinct from coalesce(p_active,true)
    or charge_full_bottle is distinct from coalesce(p_charge_full_bottle,false) then 1 else 0 end,
   updated_at=clock_timestamp() where id=p_id returning * into m;
  if not found then raise exception 'custom_material_unavailable'; end if;
 end if;
 return jsonb_build_object('id',m.id,'name',m.name,'unit_cost_rm',m.unit_cost_rm,'active',m.active,
  'charge_full_bottle',m.charge_full_bottle,'price_revision',m.price_revision);
end;$function$;

-- Accept both legacy recipe arrays and the extended {items,note} payload.
-- A full-bottle ingredient is charged as one bottle for each custom drink, regardless of amount used.
create or replace function private.yt_pos_custom_calculate(p_recipe jsonb)
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
declare
 e jsonb; m public.yt_pos_custom_materials%rowtype; s public.yt_pos_custom_pricing_settings%rowtype;
 q numeric; billed_q numeric; items jsonb; drink_note text;
 v_recipe jsonb:='[]'::jsonb; v_cost numeric:=0; v_base numeric:=0; line_base numeric;
begin
 if jsonb_typeof(p_recipe)='array' then items:=p_recipe;
 elsif jsonb_typeof(p_recipe)='object' then items:=p_recipe->'items';
 else raise exception 'custom_recipe_invalid'; end if;
 if jsonb_typeof(items)<>'array' or jsonb_array_length(items)<1 then raise exception 'custom_recipe_invalid'; end if;
 drink_note:=btrim(coalesce(p_recipe->>'note',''));
 if length(drink_note)>500 then raise exception 'custom_note_invalid'; end if;
 select * into s from public.yt_pos_custom_pricing_settings where id=true;
 for e in select value from jsonb_array_elements(items) loop
  begin q:=(e->>'quantity')::numeric; exception when others then raise exception 'custom_recipe_invalid'; end;
  if q<1 or q<>trunc(q) then raise exception 'custom_recipe_invalid'; end if;
  select * into m from public.yt_pos_custom_materials where id=(e->>'material_id')::uuid;
  if not found then raise exception 'custom_material_unavailable'; end if;
  if length(btrim(coalesce(e->>'note','')))>250 then raise exception 'custom_note_invalid'; end if;
  billed_q:=case when m.charge_full_bottle then 1 else q end;
  line_base:=m.unit_cost_rm*billed_q/(1-s.margin_percent/100);
  v_cost:=v_cost+m.unit_cost_rm*billed_q; v_base:=v_base+line_base;
  v_recipe:=v_recipe||jsonb_build_array(jsonb_build_object(
   'material_id',m.id,'name',m.name,'quantity',q,'billed_quantity',billed_q,
   'charge_full_bottle',m.charge_full_bottle,'unit_cost_rm',m.unit_cost_rm,
   'note',btrim(coalesce(e->>'note','')),
   'margin_percent',s.margin_percent,'min_discount_percent',0,
   'max_discount_percent',s.max_discount_percent,'price_revision',m.price_revision));
 end loop;
 return jsonb_build_object('recipe',v_recipe,'note',drink_note,'cost_rm',round(v_cost,2),
  'suggested_min_rm',greatest(round(v_base*(1-s.max_discount_percent/100),2),round(v_cost,2)),
  'suggested_max_rm',round(v_base,2));
end;$function$;

create or replace function private.yt_pos_custom_create(p_name text,p_recipe jsonb,p_quote numeric)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare calc jsonb; pid uuid; d public.yt_pos_custom_drinks%rowtype; quote numeric; items jsonb;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only'; end if;
 if length(btrim(coalesce(p_name,''))) not between 2 and 100 then raise exception 'custom_name_invalid'; end if;
 items:=case when jsonb_typeof(p_recipe)='object' then p_recipe->'items' else p_recipe end;
 if jsonb_typeof(items)<>'array' then raise exception 'custom_recipe_invalid'; end if;
 for pid in select (value->>'material_id')::uuid from jsonb_array_elements(items) loop
  if not exists(select 1 from public.yt_pos_custom_materials where id=pid and active) then raise exception 'custom_material_unavailable'; end if;
 end loop;
 calc:=private.yt_pos_custom_calculate(p_recipe); quote:=round(p_quote,2);
 if quote is null or quote<(calc->>'suggested_min_rm')::numeric or quote>5000 then raise exception 'custom_quote_below_cost'; end if;
 insert into public.yt_shop_products(title,category,price_rm,redeem_points,active,sort_order,series_id,is_drink)
 values(btrim(p_name),'CUSTOM',quote,null,true,999999,null,true) returning id into pid;
 insert into public.yt_pos_custom_drinks(product_id,public_name,recipe_snapshot,note,total_cost_rm,suggested_min_rm,suggested_max_rm,quote_rm,created_by)
 values(pid,btrim(p_name),calc->'recipe',calc->>'note',(calc->>'cost_rm')::numeric,(calc->>'suggested_min_rm')::numeric,
  (calc->>'suggested_max_rm')::numeric,quote,auth.uid()) returning * into d;
 insert into public.yt_pos_custom_drink_versions(custom_drink_id,version,recipe_snapshot,note,total_cost_rm,
  suggested_min_rm,suggested_max_rm,quote_rm,changed_by,change_kind)
 values(d.id,1,d.recipe_snapshot,d.note,d.total_cost_rm,d.suggested_min_rm,d.suggested_max_rm,d.quote_rm,auth.uid(),'created');
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
 insert into public.yt_pos_custom_drink_versions(custom_drink_id,version,recipe_snapshot,note,total_cost_rm,
  suggested_min_rm,suggested_max_rm,quote_rm,changed_by,change_kind)
 values(d.id,v,d.recipe_snapshot,d.note,d.total_cost_rm,d.suggested_min_rm,d.suggested_max_rm,d.quote_rm,auth.uid(),'repriced');
 return jsonb_build_object('ok',true,'id',d.id,'product',jsonb_build_object('id',d.product_id,'custom_id',d.id,'share_token',d.share_token,
  'name',d.public_name,'price_rm',d.quote_rm,'active',true,'category','CUSTOM','is_drink',false));
end;$function$;

create or replace function private.yt_pos_custom_owner_history()
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
begin
 if not private.yt_work_owner() then raise exception 'owner_only'; end if;
 return coalesce((
  select jsonb_agg(jsonb_build_object(
   'id',d.id,'name',d.public_name,'note',d.note,'customer_id',d.customer_id,
   'customer_name',(select coalesce(nullif(btrim(p.display_name),''),p.phone) from public.profiles p where p.id=d.customer_id),
   'created_by',d.created_by,
   'created_by_name',(select wa.username from public.work_accounts wa where wa.auth_user_id=d.created_by),
   'created_at',d.created_at,
   'versions',(select jsonb_agg(jsonb_build_object(
    'version',v.version,'recipe',v.recipe_snapshot,'note',v.note,'cost_rm',v.total_cost_rm,
    'suggested_min_rm',v.suggested_min_rm,'suggested_max_rm',v.suggested_max_rm,
    'quote_rm',v.quote_rm,'changed_by',v.changed_by,
    'changed_by_name',(select wa.username from public.work_accounts wa where wa.auth_user_id=v.changed_by),
    'changed_at',v.changed_at,'change_kind',v.change_kind) order by v.version desc)
    from public.yt_pos_custom_drink_versions v where v.custom_drink_id=d.id)
  ) order by d.created_at desc) from public.yt_pos_custom_drinks d
 ),'[]'::jsonb);
end;$function$;

create or replace function public.yt_pos_custom_material_save_v3(
 p_id uuid,p_name text,p_unit_cost numeric,p_active boolean,p_charge_full_bottle boolean
) returns jsonb language sql set search_path=''
as $function$ select private.yt_pos_custom_material_save_v3(p_id,p_name,p_unit_cost,p_active,p_charge_full_bottle); $function$;

revoke all on function private.yt_pos_custom_materials(),private.yt_pos_custom_material_save_v3(uuid,text,numeric,boolean,boolean),
 private.yt_pos_custom_calculate(jsonb),private.yt_pos_custom_create(text,jsonb,numeric),
 private.yt_pos_custom_reprice(uuid,numeric),private.yt_pos_custom_owner_history() from public,anon,authenticated;
grant execute on function private.yt_pos_custom_materials(),private.yt_pos_custom_material_save_v3(uuid,text,numeric,boolean,boolean),
 private.yt_pos_custom_create(text,jsonb,numeric),private.yt_pos_custom_reprice(uuid,numeric),
 private.yt_pos_custom_owner_history() to authenticated;
revoke all on function public.yt_pos_custom_material_save_v3(uuid,text,numeric,boolean,boolean) from public,anon;
grant execute on function public.yt_pos_custom_material_save_v3(uuid,text,numeric,boolean,boolean) to authenticated;
