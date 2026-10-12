begin;
do $$
declare actor uuid;product uuid;prepaid uuid;open_tab uuid;r jsonb;q jsonb;rows jsonb;
begin
 select auth_user_id into actor from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 if actor is null then raise exception 'fixture_missing';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
 insert into public.yt_shop_products(title,price_rm,active) values('rollback KDS drink',18,true) returning id into product;

 insert into public.yt_member_orders(source,status,amount_rm,payment_status,checkout_mode,created_by,accepted_by,accepted_at,order_no)
 values('future_pos','confirmed',36,'unpaid','pay_now',actor,actor,now(),'ROLLBACK-KDS-PREPAID') returning id into prepaid;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
 values(prepaid,product,'rollback KDS drink',2,18);
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source) values(prepaid,actor,'created','staff');
 q:=public.yt_pos_cart_summary(prepaid);
 if not (q->>'can_pay')::boolean then raise exception 'confirmed_order_not_payable';end if;
 r:=public.yt_pos_action(prepaid,'paid',null,'cash');
 if r->>'status'<>'confirmed' or r->>'payment_status'<>'paid' then raise exception 'prepaid_order_left_kds';end if;
 rows:=public.yt_pos_orders('active',80);
 if not exists(select 1 from jsonb_array_elements(rows) x where x->>'id'=prepaid::text and x->>'created_channel'='staff' and x->>'checkout_mode'='pay_now') then raise exception 'prepaid_order_missing_from_kds';end if;
 r:=public.yt_pos_action(prepaid,'fulfilled');
 if r->>'status'<>'fulfilled' or r->>'payment_status'<>'paid' then raise exception 'prepaid_order_not_completed';end if;
 rows:=public.yt_pos_orders('active',80);
 if exists(select 1 from jsonb_array_elements(rows) x where x->>'id'=prepaid::text) then raise exception 'completed_prepaid_still_active';end if;

 insert into public.yt_member_orders(source,status,amount_rm,payment_status,checkout_mode,created_by,accepted_by,accepted_at,fulfilled_by,fulfilled_at,order_no)
 values('future_pos','fulfilled',18,'unpaid','pay_later',actor,actor,now(),actor,now(),'ROLLBACK-KDS-OPEN') returning id into open_tab;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
 values(open_tab,product,'rollback KDS drink',1,18);
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source) values(open_tab,actor,'created','cashier');
 rows:=public.yt_pos_orders('active',80);
 if not exists(select 1 from jsonb_array_elements(rows) x where x->>'id'=open_tab::text and x->>'created_channel'='cashier' and x->>'checkout_mode'='pay_later') then raise exception 'open_tab_missing';end if;
end $$;
rollback;
