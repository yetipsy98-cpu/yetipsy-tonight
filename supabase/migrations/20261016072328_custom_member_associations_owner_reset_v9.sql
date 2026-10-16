-- Reset custom shared-member links with their parent records so the FK cannot block reset.
DO $patch$
DECLARE
  v_definition text;
  v_updated text;
  v_count_anchor text := '''订制饮品记录'',(select count(*) from public.yt_pos_custom_drinks));end if;';
  v_truncate_anchor text := 'public.yt_member_orders,public.yt_pos_custom_drink_versions,public.yt_pos_custom_drinks,public.yt_point_shop_exchanges';
BEGIN
  SELECT pg_get_functiondef(
    'private.yt_owner_reset_v9(uuid,text,text,uuid,uuid,bigint[],text[])'::regprocedure
  ) INTO v_definition;

  IF position('public.yt_pos_custom_drink_members' IN v_definition) = 0 THEN
    IF position(v_count_anchor IN v_definition) = 0
       OR position(v_truncate_anchor IN v_definition) = 0 THEN
      RAISE EXCEPTION 'custom_member_reset_patch_anchor_missing';
    END IF;

    v_updated := replace(
      v_definition,
      v_count_anchor,
      '''订制饮品记录'',(select count(*) from public.yt_pos_custom_drinks),''订制会员绑定'',(select count(*) from public.yt_pos_custom_drink_members));end if;'
    );
    v_updated := replace(
      v_updated,
      v_truncate_anchor,
      'public.yt_member_orders,public.yt_pos_custom_drink_versions,public.yt_pos_custom_drink_members,public.yt_pos_custom_drinks,public.yt_point_shop_exchanges'
    );

    IF v_updated = v_definition THEN
      RAISE EXCEPTION 'custom_member_reset_patch_failed';
    END IF;
    EXECUTE v_updated;
  END IF;
END
$patch$;