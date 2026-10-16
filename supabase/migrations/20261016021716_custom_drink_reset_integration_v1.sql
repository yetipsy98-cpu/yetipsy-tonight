-- Include one-off custom drinks in the existing Owner reset scopes.
do $patch$
declare
  v_definition text;
  v_updated text;
begin
  select pg_get_functiondef(
    'private.yt_owner_reset_v9(uuid,text,text,uuid,uuid,bigint[],text[])'::regprocedure
  ) into v_definition;

  if position('public.yt_pos_custom_drink_versions' in v_definition) > 0 then
    raise exception 'custom_drink_reset_patch_already_present';
  end if;

  if position('''Ambassador 佣金记录'',(select count(*) from public.yt_ambassador_ledger));end if;' in v_definition) = 0
     or position('public.yt_member_order_items,public.yt_member_orders,public.yt_point_shop_exchanges' in v_definition) = 0
     or position('public.yt_play_bell_requests restart identity;' in v_definition) = 0
     or position('delete from public.yt_shop_products where true;delete from public.yt_pos_series where true;' in v_definition) = 0 then
    raise exception 'custom_drink_reset_patch_anchor_missing';
  end if;

  v_updated := replace(
    v_definition,
    '''Ambassador 佣金记录'',(select count(*) from public.yt_ambassador_ledger));end if;',
    '''Ambassador 佣金记录'',(select count(*) from public.yt_ambassador_ledger),''订制饮品记录'',(select count(*) from public.yt_pos_custom_drinks));end if;'
  );
  v_updated := replace(
    v_updated,
    'public.yt_member_order_items,public.yt_member_orders,public.yt_point_shop_exchanges',
    'public.yt_member_order_items,public.yt_member_orders,public.yt_pos_custom_drink_versions,public.yt_pos_custom_drinks,public.yt_point_shop_exchanges'
  );
  v_updated := replace(
    v_updated,
    'public.yt_play_bell_requests restart identity;',
    'public.yt_play_bell_requests restart identity;' || chr(10) || '  delete from public.yt_shop_products where category=''CUSTOM'';'
  );
  v_updated := replace(
    v_updated,
    'delete from public.yt_shop_products where true;delete from public.yt_pos_series where true;',
    'delete from public.yt_pos_custom_materials where true;delete from public.yt_shop_products where true;delete from public.yt_pos_series where true;'
  );

  execute v_updated;
end
$patch$;
