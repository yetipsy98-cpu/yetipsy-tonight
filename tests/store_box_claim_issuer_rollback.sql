BEGIN;
-- Verify claim attribution and customer visibility without preserving fixtures.
DO $$
declare owner_id uuid;staff_id uuid;member_id uuid;product uuid;o uuid;item uuid;
 token uuid:=gen_random_uuid();box uuid;r jsonb;issuer text;account_name text;
begin
 select auth_user_id,username into staff_id,account_name from public.work_accounts where role in ('staff','cashier') and active and not must_change_password order by role limit 1;
 select auth_user_id into owner_id from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 select auth_user_id into member_id from public.pin_accounts where not exists(select 1 from public.work_accounts where auth_user_id=pin_accounts.auth_user_id) limit 1;
 if owner_id is null or staff_id is null or member_id is null then raise exception 'fixture_missing';end if;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 insert into public.yt_shop_products(title,price_rm,active) values('rollback claim attribution',15,true) returning id into product;
 perform public.yt_store_box_rule_save_v2(product,'package',1,1,30,'杯','fixed','[]'::jsonb,true);
 insert into public.yt_member_orders(source,status,amount_rm,payment_status,payment_method,paid_at,created_by,paid_by)
 values('future_pos','fulfilled',15,'paid','cash',now(),owner_id,owner_id) returning id into o;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
 values(o,product,'rollback claim attribution',1,15) returning id into item;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 r:=public.yt_store_box_issue(item,token,gen_random_uuid(),2);box:=(r->>'box_id')::uuid;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member_id)::text,true);
 perform public.yt_store_box_claim(token);
 if not exists(select 1 from jsonb_array_elements(public.yt_my_store_boxes())x where x->>'id'=box::text) then raise exception 'claimed_box_missing_from_customer_history';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 select x->>'claimed_qr_issued_by_name' into issuer from jsonb_array_elements(public.yt_store_box_staff_boxes())x where x->>'id'=box::text;
 if issuer is distinct from account_name then raise exception 'claimed_qr_issuer_missing';end if;
end $$;
ROLLBACK;
