-- Keep fulfillment status inside the already-authorized private POS query.
-- The public wrappers must not read yt_member_order_items as the caller.
do $$
declare
  v_name text;
  v_def text;
  v_old text := $old$jsonb_build_object('id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'price_rm',i.unit_price_rm,'store_box_item',exists($old$;
  v_new text := $new$jsonb_build_object('id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'price_rm',i.unit_price_rm,'fulfilled',i.fulfilled,'store_box_item',exists($new$;
begin
  foreach v_name in array array['yt_pos_orders','yt_pos_orders_day'] loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='private' and p.proname=v_name;
    if v_def is null or position(v_old in v_def)=0 then
      raise exception 'expected POS order JSON fragment missing in private.%',v_name;
    end if;
    execute replace(v_def,v_old,v_new);
  end loop;
end $$;

create or replace function public.yt_pos_orders(p_scope text default 'active', p_limit integer default 60)
returns jsonb language sql set search_path to ''
as $$ select private.yt_pos_orders($1,$2) $$;

create or replace function public.yt_pos_orders_day(p_scope text default 'active', p_day date default null, p_limit integer default 60)
returns jsonb language sql set search_path to ''
as $$ select private.yt_pos_orders_day($1,$2,$3) $$;
