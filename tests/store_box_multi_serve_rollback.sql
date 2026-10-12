BEGIN;
-- One request may contain multiple combo items; fixed serving may cross item boundaries.
do $$
declare
 owner_id uuid;staff_id uuid;member_id uuid;product uuid;o uuid;item uuid;token uuid:=gen_random_uuid();
 box uuid;drink_request uuid;request_key uuid:=gen_random_uuid();r jsonb;queued jsonb;
begin
 select auth_user_id into owner_id from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 select auth_user_id into staff_id from public.work_accounts where role in ('staff','cashier') and active and not must_change_password order by role limit 1;
 select auth_user_id into member_id from public.pin_accounts where not exists(select 1 from public.work_accounts where auth_user_id=pin_accounts.auth_user_id) limit 1;
 if owner_id is null or staff_id is null or member_id is null then raise exception 'fixture_missing';end if;
 if has_function_privilege('anon','public.yt_store_box_request_v3(uuid,integer,jsonb,uuid,text)','execute') then raise exception 'store_box_request_v3_exposed';end if;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 insert into public.yt_shop_products(title,price_rm,active) values('rollback multi combo',99,true) returning id into product;
 perform public.yt_store_box_rule_save_v2(product,'package',1,2,30,'杯','customer','[{"name":"A","quantity":1},{"name":"B","quantity":2},{"name":"C","quantity":1}]'::jsonb,true);
 insert into public.yt_member_orders(source,status,amount_rm,payment_status,payment_method,paid_at,created_by,paid_by,table_label)
 values('future_pos','fulfilled',99,'paid','cash',now(),owner_id,owner_id,'M8') returning id into o;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) values(o,product,'rollback multi combo',1,99) returning id into item;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 r:=public.yt_store_box_issue(item,token,gen_random_uuid(),2);box:=(r->>'box_id')::uuid;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member_id)::text,true);
 perform public.yt_store_box_claim(token);
 r:=public.yt_store_box_request_v3(box,2,'[{"key":"c1","quantity":1},{"key":"c2","quantity":1}]'::jsonb,request_key,'M9');drink_request:=(r->>'id')::uuid;
 if jsonb_array_length(r->'selections')<>2 or r->>'component_key' is not null then raise exception 'multi_selection_not_saved';end if;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 select x into queued from jsonb_array_elements(public.yt_store_box_queue())x where x->>'request_id'=drink_request::text;
 if jsonb_array_length(queued->'selections')<>2 or queued->>'component_name'<>'A×1 · B×1' then raise exception 'multi_queue_wrong';end if;
 perform public.yt_store_box_request_action(drink_request,'serve',0,'');
 if not exists(select 1 from public.yt_store_boxes where id=box and served_units=2 and components#>>'{0,served_units}'='1' and components#>>'{1,served_units}'='1') then raise exception 'multi_inventory_wrong';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member_id)::text,true);
 r:=public.yt_store_box_request_v3(box,2,'[{"key":"c1","quantity":1},{"key":"c2","quantity":1}]'::jsonb,request_key,'M9');
 if r->>'status'<>'served' or (select served_units from public.yt_store_boxes where id=box)<>2 then raise exception 'multi_retry_not_idempotent';end if;

 -- Switching this fixture to fixed mode proves that a single request can continue from B into C.
 update public.yt_store_boxes set selection_mode='fixed' where id=box;
 r:=public.yt_store_box_request_v3(box,2,'[]'::jsonb,gen_random_uuid(),'M9');drink_request:=(r->>'id')::uuid;
 if r#>>'{selections,0,key}'<>'c2' or r#>>'{selections,1,key}'<>'c3' then raise exception 'fixed_cross_component_wrong';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 perform public.yt_store_box_request_action(drink_request,'serve',0,'');
 if not exists(select 1 from public.yt_store_boxes where id=box and served_units=4 and status='exhausted') then raise exception 'multi_box_not_exhausted';end if;
end $$;
ROLLBACK;
