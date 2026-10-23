-- A reviewed FOC may set a custom item's order snapshot price to zero; normal custom quotes stay cost-protected.
create or replace function private.yt_pos_custom_order_item_guard()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare d public.yt_pos_custom_drinks%rowtype; stale boolean; calc jsonb;
begin
  if TG_OP='UPDATE' and NEW.product_id=OLD.product_id and NEW.unit_price_rm=OLD.unit_price_rm and NEW.quantity<=OLD.quantity then return NEW; end if;
  select * into d from public.yt_pos_custom_drinks where product_id=NEW.product_id;
  if not found then return NEW; end if;
  if current_setting('yt.pos.owner_adjustment',true)='on' and private.yt_work_owner()
     and TG_OP='UPDATE' and NEW.product_id=OLD.product_id and NEW.unit_price_rm=0 and NEW.quantity=OLD.quantity then return NEW; end if;
  calc:=private.yt_pos_custom_calculate(d.recipe_snapshot);
  select exists(select 1 from jsonb_array_elements(d.recipe_snapshot) as recipe_item(value)
    join public.yt_pos_custom_materials cur on cur.id=(recipe_item.value->>'material_id')::uuid
    where (recipe_item.value->>'price_revision')::integer<>cur.price_revision) into stale;
  if stale then raise exception 'custom_reprice_required'; end if;
  if NEW.unit_price_rm<(calc->>'cost_rm')::numeric or NEW.unit_price_rm<>d.quote_rm then raise exception 'custom_quote_below_cost'; end if;
  return NEW;
end;
$function$;

do $migration$
declare d text; needle text:=$needle$    update public.yt_member_order_items i set unit_price_rm=0,item_name=i.item_name||' · FOC'$needle$;
begin
  select pg_get_functiondef('private.yt_pos_cashier_adjustment_review(uuid,boolean,text)'::regprocedure) into d;
  if position('yt.pos.owner_adjustment' in d)=0 then
    d:=replace(d,needle,$prefix$    perform set_config('yt.pos.owner_adjustment','on',true);
$prefix$||needle);
    d:=replace(d,$needle$where i.order_id=v_order_id and i.product_id in (select value::uuid from jsonb_array_elements_text(v_foc));$needle$,$replace$where i.order_id=v_order_id and i.product_id in (select value::uuid from jsonb_array_elements_text(v_foc));
    perform set_config('yt.pos.owner_adjustment','off',true);$replace$);
    if position('yt.pos.owner_adjustment' in d)=0 then raise exception 'Could not update FOC approval context'; end if;
    execute d;
  end if;
end;
$migration$;
