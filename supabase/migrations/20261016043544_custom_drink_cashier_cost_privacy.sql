-- Do not send Owner-only material costs or recipes to Cashier clients.
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
  'name',d.public_name,'price_rm',d.quote_rm,'suggested_min_rm',d.suggested_min_rm,
  'suggested_max_rm',d.suggested_max_rm,'active',true,'category','CUSTOM','is_drink',true);
end;$function$;

create or replace function private.yt_pos_custom_scan(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
declare d public.yt_pos_custom_drinks%rowtype; calc jsonb; stale boolean;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only'; end if;
 select * into d from public.yt_pos_custom_drinks where share_token=p_token;
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
end;$function$;

revoke all on function private.yt_pos_custom_create(text,jsonb,numeric),private.yt_pos_custom_scan(uuid) from public,anon,authenticated;
grant execute on function private.yt_pos_custom_create(text,jsonb,numeric),private.yt_pos_custom_scan(uuid) to authenticated;
