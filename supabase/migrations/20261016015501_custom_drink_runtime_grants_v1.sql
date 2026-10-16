-- Ensure custom products count as paid drink units, while remaining excluded from member points.
create or replace function private.yt_pos_custom_product_guard()
returns trigger language plpgsql set search_path=''
as $function$
begin
 if new.category='CUSTOM' then new.is_drink:=true; end if;
 return new;
end;$function$;
drop trigger if exists yt_pos_custom_product_guard on public.yt_shop_products;
create trigger yt_pos_custom_product_guard before insert or update of category,is_drink
 on public.yt_shop_products for each row execute function private.yt_pos_custom_product_guard();
update public.yt_shop_products set is_drink=true where category='CUSTOM' and is_drink is distinct from true;

grant execute on function private.yt_pos_custom_materials(),private.yt_pos_custom_material_save(uuid,text,numeric,numeric,numeric,numeric,boolean),
 private.yt_pos_custom_create(text,jsonb,numeric),private.yt_pos_custom_scan(uuid),private.yt_pos_custom_reprice(uuid,numeric),
 private.yt_pos_custom_my_list(),private.yt_pos_custom_owner_history() to authenticated;
