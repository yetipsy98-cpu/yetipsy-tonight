-- Include every FK child table in the scoped reset TRUNCATE statement.
-- TRUNCATE does not apply ON DELETE CASCADE; these children must be listed explicitly.
-- Patch the current v9 definition while preserving its reviewed body.
do $patch$
declare
  v_definition text;
  v_updated text;
begin
  select pg_get_functiondef('private.yt_owner_reset_v9(uuid,text,text,uuid,uuid,bigint[],text[])'::regprocedure)
    into v_definition;
  if position('public.yt_pos_order_events,public.yt_pos_pass_bundle_items,public.yt_pos_pass_bundles' in v_definition) = 0
     or position('public.yt_pos_preorder_holds,public.yt_pos_reward_holds,public.yt_promo_grants' in v_definition) = 0 then
    raise exception 'owner_reset_v9_patch_anchor_missing';
  end if;

  v_updated := replace(v_definition,
    'public.yt_pos_order_events,public.yt_pos_pass_bundle_items,public.yt_pos_pass_bundles',
    'public.yt_pos_order_events,public.yt_pos_duitnow_proofs,public.yt_pos_pass_bundle_items,public.yt_pos_pass_bundles');
  v_updated := replace(v_updated,
    'public.yt_pos_preorder_holds,public.yt_pos_reward_holds,public.yt_promo_grants',
    'public.yt_pos_preorder_holds,public.yt_pos_reward_holds,private.yt_store_box_prep_intents,public.yt_promo_grants');

  execute v_updated;
end
$patch$;
