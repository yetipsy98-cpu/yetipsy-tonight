-- Keep every Play order FK child in the same scoped TRUNCATE as its parent.
-- The reset remains transactional; this only extends its existing records scope.
do $patch$
declare
  v_definition text;
  v_updated text;
begin
  select pg_get_functiondef(
    'private.yt_owner_reset_v9(uuid,text,text,uuid,uuid,bigint[],text[])'::regprocedure
  ) into v_definition;

  if position('public.yt_referral_links restart identity' in v_definition) = 0 then
    raise exception 'owner_reset_play_children_patch_anchor_missing';
  end if;

  if position('public.yt_play_order_tokens' in v_definition) > 0
     or position('public.yt_play_consumption_bindings' in v_definition) > 0
     or position('public.yt_play_first_purchases' in v_definition) > 0
     or position('public.yt_play_referral_events' in v_definition) > 0 then
    raise exception 'owner_reset_play_children_already_present';
  end if;

  v_updated := replace(
    v_definition,
    'public.yt_referral_links restart identity',
    'public.yt_referral_links,public.yt_play_order_tokens,public.yt_play_consumption_bindings,public.yt_play_first_purchases,public.yt_play_referral_events restart identity'
  );

  execute v_updated;
end
$patch$;
