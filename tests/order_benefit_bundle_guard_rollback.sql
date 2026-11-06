-- Run inside a transaction and roll back: no customer data survives.
do $$
declare actor uuid; series uuid; product uuid; campaign uuid; o uuid; item uuid;
 v_mode text; r jsonb; token uuid; request uuid; b uuid; pass uuid;
begin
 select auth_user_id into actor from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
 insert into public.yt_pos_series(name,benefit_mode,game_plays,active) values('rollback bundle guard','games',1,true) returning id into series;
 insert into public.yt_shop_products(title,price_rm,series_id,active,is_drink) values('rollback bundle drink',20,series,true,true) returning id into product;
 insert into public.campaigns(name,active) values('rollback bundle campaign',true) returning id into campaign;
 foreach v_mode in array array['game','lucky'] loop
  update public.yt_lucky_settings set mode=v_mode where id=true;
  insert into public.yt_member_orders(source,status,amount_rm,created_by) values('future_pos','fulfilled',40,actor) returning id into o;
  insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) values(o,product,'rollback bundle drink',2,20) returning id into item;
  insert into public.yt_pos_item_units(order_item_id,unit_number) values(item,1),(item,2) on conflict do nothing;
  update public.yt_member_orders set payment_status='paid',paid_at=clock_timestamp(),paid_by=actor,payment_method='cash' where id=o;
  token:=gen_random_uuid();request:=gen_random_uuid();
  if v_mode='game' then r:=private.yt_pos_bundle_issue(o,campaign,token,request,2);
  else r:=private.yt_lucky_bundle_issue(o,token,request,2);end if;
  if (r->>'pass_count')::int<>2 then raise exception 'bundle_count_wrong: %',r;end if;
  b:=(r->>'id')::uuid;
  if (select count(*) from public.yt_pos_pass_bundle_items where bundle_id=b)<>2 then raise exception 'bundle_items_missing';end if;
  if v_mode='game' then r:=private.yt_pos_bundle_issue(o,campaign,token,request,2);
  else r:=private.yt_lucky_bundle_issue(o,token,request,2);end if;
  if not (r->>'idempotent')::boolean then raise exception 'retry_not_idempotent';end if;
  if (select count(*) from public.yt_pos_pass_bundles where order_id=o)<>1 then raise exception 'duplicate_bundle';end if;
  -- A different-mode bundle must still block assignment of this pass.
  select game_pass_id into pass from public.yt_pos_item_units where order_item_id=item and unit_number=1;
  update public.yt_pos_pass_bundles set lucky_mode=case when v_mode='game' then 'lucky' else 'game' end where id=b;
  update public.yt_pos_item_units set game_pass_id=null where order_item_id=item and unit_number=1;
  begin
   update public.yt_pos_item_units set game_pass_id=pass where order_item_id=item and unit_number=1;
   raise exception 'opposite_mode_was_allowed';
  exception when others then if sqlerrm<>'order_benefit_already_selected' then raise;end if;end;
  update public.yt_pos_pass_bundles set lucky_mode=v_mode where id=b;
  update public.yt_pos_item_units set game_pass_id=pass where order_item_id=item and unit_number=1;
 end loop;
end $$;
