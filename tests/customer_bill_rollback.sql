-- Never settle a real order: all fixtures and mutations are rolled back.
do $$
declare actor uuid; member uuid; product uuid; reward uuid; award uuid; o uuid; item uuid; hold uuid; rd uuid; r jsonb;lines jsonb;old_updated timestamptz;
begin
 select auth_user_id into actor from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 select auth_user_id into member from public.pin_accounts limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
 insert into public.yt_shop_products(title,price_rm,active) values('rollback invoice drink',25.90,true) returning id into product;
 insert into public.rewards(name,category,active) values('rollback RM5','voucher',true) returning id into reward;
 insert into public.user_rewards(customer_id,reward_id,issued_by,expires_at) values(member,reward,actor,clock_timestamp()+interval '1 month') returning id into award;
 insert into public.yt_member_orders(source,status,amount_rm,created_by) values('future_pos','fulfilled',25.90,actor) returning id into o;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) values(o,product,'rollback invoice drink',1,25.90) returning id into item;
 insert into public.yt_pos_item_units(order_item_id,unit_number) values(item,1) on conflict do nothing;
 insert into public.yt_pos_reward_holds(order_id,user_reward_id,reward_id,operator_id,request_id,state,rule_mode,discount_type,discount_value,discount_rm,order_item_id,unit_number,expires_at)
 values(o,award,reward,actor,gen_random_uuid(),'ready','any_drink','fixed',5,5,item,1,clock_timestamp()+interval '10 minutes') returning id into hold;
 r=public.yt_pos_bill_v8(o);
 if (r->>'amount_rm')::numeric<>20.90 or (r->>'gross_total_rm')::numeric<>25.90 or (r->>'discount_total_rm')::numeric<>5
 or (r#>>'{items,0,line_total_rm}')::numeric<>20.90 or r#>>'{discounts,0,reward_name}'<>'rollback RM5' or not (r->>'discount_pending')::boolean then raise exception 'unpaid_bill_wrong';end if;
 update public.yt_pos_reward_holds set expires_at=clock_timestamp()-interval '1 second' where id=hold;
 r=public.yt_pos_bill_v8(o);if (r->>'amount_rm')::numeric<>25.90 or (r->>'discount_total_rm')::numeric<>0 or (r->>'unresolved_count')::int<>1 then raise exception 'expired_discount_applied';end if;
 update public.yt_pos_reward_holds set expires_at=clock_timestamp()+interval '10 minutes' where id=hold;
 -- Settle only this temporary fixture inside the rollback transaction.
 update public.yt_member_orders set payment_status='paid',paid_at=clock_timestamp(),paid_by=actor,payment_method='cash' where id=o;
 r=public.yt_pos_bill_v8(o);if (r->>'amount_rm')::numeric<>20.90 or (r->>'discount_total_rm')::numeric<>5 or jsonb_array_length(r->'discounts')<>1 or (r->>'discount_pending')::boolean then raise exception 'paid_discount_double_counted';end if;
 -- An Owner price reduction cannot remove the last net-paid drink; after adding a second drink the saved RM5 discount is clipped to the new line price.
 select updated_at into old_updated from public.yt_member_orders where id=o;
 lines:=jsonb_build_array(jsonb_build_object('item_id',item,'product_id',product,'quantity',1,'unit_price_rm',4));
 begin perform public.yt_pos_owner_revision_apply(o,lines,'price adjustment',null,null,old_updated,gen_random_uuid());raise exception 'expected_failure';exception when others then if sqlerrm<>'minimum_one_paid_drink' then raise;end if;end;
 lines:=lines||jsonb_build_array(jsonb_build_object('product_id',product,'quantity',1,'unit_price_rm',10));
 perform public.yt_pos_owner_revision_apply(o,lines,'price and quantity adjustment',null,null,old_updated,gen_random_uuid());
 r:=public.yt_pos_bill_v8(o);
 if (r->>'amount_rm')::numeric<>10 or (r->>'discount_total_rm')::numeric<>4 or (r->>'received_rm')::numeric<>20.90 or (select status from public.user_rewards where id=award)<>'redeemed'
 or exists(select 1 from jsonb_array_elements(r->'items') x where (x->>'line_total_rm')::numeric<0) then raise exception 'revised_discount_or_consumed_coupon_wrong';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
 begin perform public.yt_pos_bill_v8(o);raise exception 'expected_failure';exception when others then if sqlerrm<>'staff_only' then raise;end if;end;
end;$$;
