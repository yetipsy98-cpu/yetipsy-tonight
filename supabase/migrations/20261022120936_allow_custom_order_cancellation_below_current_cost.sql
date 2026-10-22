-- Historical custom drink prices stay valid when an order line is only reduced or removed.
-- Enforce the current cost floor when a new line, product, price, or larger quantity is introduced.
create or replace function private.yt_pos_custom_order_item_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
 d public.yt_pos_custom_drinks%rowtype;
 stale boolean;
 calc jsonb;
begin
 if TG_OP='UPDATE'
   and NEW.product_id=OLD.product_id
   and NEW.unit_price_rm=OLD.unit_price_rm
   and NEW.quantity<=OLD.quantity then
  return NEW;
 end if;

 select * into d
 from public.yt_pos_custom_drinks
 where product_id=NEW.product_id;
 if not found then return NEW; end if;

 calc:=private.yt_pos_custom_calculate(d.recipe_snapshot);
 select exists(
  select 1
  from jsonb_array_elements(d.recipe_snapshot) as recipe_item(value)
  join public.yt_pos_custom_materials cur
    on cur.id=(recipe_item.value->>'material_id')::uuid
  where (recipe_item.value->>'price_revision')::integer<>cur.price_revision
 ) into stale;
 if stale then raise exception 'custom_reprice_required'; end if;
 if NEW.unit_price_rm<(calc->>'cost_rm')::numeric or NEW.unit_price_rm<>d.quote_rm then
  raise exception 'custom_quote_below_cost';
 end if;
 return NEW;
end;
$function$;