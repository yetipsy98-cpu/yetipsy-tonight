begin;
do $$
declare actor uuid;box_product uuid;normal_product uuid;package_order uuid;mixed_order uuid;package_item uuid;mixed_item uuid;r jsonb;q jsonb;
begin
 select auth_user_id into actor from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 if actor is null then raise exception 'fixture_missing';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
 insert into public.yt_shop_products(title,price_rm,active) values('rollback direct package',120,true) returning id into box_product;
 insert into public.yt_shop_products(title,price_rm,active) values('rollback normal drink',20,true) returning id into normal_product;
 perform public.yt_store_box_rule_save(box_product,'package',6,2,30,'杯',null,false,true);

 insert into public.yt_member_orders(source,status,amount_rm,payment_status,created_by,accepted_by,accepted_at)
 values('future_pos','confirmed',120,'unpaid',actor,actor,now()) returning id into package_order;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
 values(package_order,box_product,'rollback direct package',1,120) returning id into package_item;
 q:=public.yt_pos_cart_summary(package_order);
 if not (q->>'store_box_only')::boolean or not (q->>'can_pay')::boolean then raise exception 'package_not_direct_payable';end if;
 r:=public.yt_pos_action(package_order,'paid',null,'cash');
 if r->>'status'<>'fulfilled' or r->>'payment_status'<>'paid' or jsonb_array_length(r->'store_box_claims')<>1 then raise exception 'package_checkout_result_wrong';end if;
 if coalesce(r#>>'{store_box_claims,0,claim_token}','')='' then raise exception 'package_claim_token_missing';end if;
 if not exists(select 1 from public.yt_member_orders where id=package_order and status='fulfilled' and payment_status='paid') then raise exception 'package_not_paid';end if;
 if not exists(select 1 from public.yt_store_box_claims c join public.yt_store_boxes b on b.id=c.box_id where b.source_order_item_id=package_item and c.status='issued') then raise exception 'package_claim_not_issued';end if;

 insert into public.yt_member_orders(source,status,amount_rm,payment_status,created_by,accepted_by,accepted_at)
 values('future_pos','confirmed',140,'unpaid',actor,actor,now()) returning id into mixed_order;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
 values(mixed_order,box_product,'rollback direct package',1,120) returning id into mixed_item;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
 values(mixed_order,normal_product,'rollback normal drink',1,20);
 q:=public.yt_pos_cart_summary(mixed_order);
 if (q->>'store_box_only')::boolean or not (q->>'can_pay')::boolean then raise exception 'mixed_order_not_prepaid_ready';end if;
 r:=public.yt_pos_action(mixed_order,'paid',null,'cash');
 if r->>'status'<>'confirmed' or r->>'payment_status'<>'paid' or jsonb_array_length(r->'store_box_claims')<>0 then raise exception 'mixed_prepayment_left_kds';end if;
 if exists(select 1 from public.yt_store_boxes where source_order_item_id=mixed_item) then raise exception 'mixed_package_issued_before_serve';end if;
 r:=public.yt_pos_action(mixed_order,'fulfilled');
 if r->>'status'<>'fulfilled' or jsonb_array_length(r->'store_box_claims')<>1 then raise exception 'mixed_package_claim_not_issued';end if;
 if not exists(select 1 from public.yt_store_boxes where source_order_item_id=mixed_item) then raise exception 'mixed_package_box_missing';end if;
end $$;
rollback;
