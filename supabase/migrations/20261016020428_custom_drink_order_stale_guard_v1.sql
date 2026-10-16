-- QR scan returns the persisted token; order creation also validates current material revisions.
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
  'name',d.public_name,'cost_rm',calc->'cost_rm','suggested_min_rm',calc->'suggested_min_rm',
  'suggested_max_rm',calc->'suggested_max_rm','recipe',calc->'recipe'); end if;
 return jsonb_build_object('ok',true,'product',jsonb_build_object('id',d.product_id,'custom_id',d.id,'share_token',d.share_token,'name',d.public_name,
  'price_rm',d.quote_rm,'active',true,'category','CUSTOM','is_drink',false),'name',d.public_name);
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
 if q is null or q<(calc->>'cost_rm')::numeric or q>5000 then raise exception 'custom_quote_below_cost'; end if;
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
create or replace function private.yt_pos_custom_order_item_guard()
returns trigger language plpgsql security definer set search_path=''
as $function$
declare d public.yt_pos_custom_drinks%rowtype; stale boolean; calc jsonb;
begin
 select * into d from public.yt_pos_custom_drinks where product_id=new.product_id;
 if not found then return new; end if;
 calc:=private.yt_pos_custom_calculate(d.recipe_snapshot);
 select exists(select 1 from jsonb_array_elements(d.recipe_snapshot) old
  join public.yt_pos_custom_materials cur on cur.id=(old->>'material_id')::uuid
  where (old->>'price_revision')::integer<>cur.price_revision) into stale;
 if stale then raise exception 'custom_reprice_required'; end if;
 if new.unit_price_rm< (calc->>'cost_rm')::numeric or new.unit_price_rm<>d.quote_rm then
  raise exception 'custom_quote_below_cost';
 end if;
 return new;
end;$function$;
drop trigger if exists yt_pos_custom_order_item_guard on public.yt_member_order_items;
create trigger yt_pos_custom_order_item_guard before insert or update of product_id,unit_price_rm,quantity
 on public.yt_member_order_items for each row execute function private.yt_pos_custom_order_item_guard();
revoke all on function private.yt_pos_custom_order_item_guard() from public,anon,authenticated;
