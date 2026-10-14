begin;
-- Role, privacy, and history checks; all fixtures are rolled back.
do $$
declare
 owner_id uuid;staff_id uuid;cashier_id uuid;member_id uuid;staff_name text;product uuid;order_id uuid;item_id uuid;box_id uuid;request_id uuid;
 token uuid:=gen_random_uuid();payload jsonb;row_data jsonb;issuer text;claimant text;history jsonb;
begin
 select auth_user_id into owner_id from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 select auth_user_id,username into staff_id,staff_name from public.work_accounts where role='staff' and active and not must_change_password order by username limit 1;
 select auth_user_id into cashier_id from public.work_accounts where role='cashier' and active and not must_change_password limit 1;
 select auth_user_id into member_id from public.pin_accounts where not exists(select 1 from public.work_accounts where auth_user_id=pin_accounts.auth_user_id) limit 1;
 if owner_id is null or staff_id is null or cashier_id is null or member_id is null then raise exception 'fixture_missing';end if;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 insert into public.yt_shop_products(title,price_rm,active) values('rollback kds privacy',16,true) returning id into product;
 perform public.yt_store_box_rule_save_v2(product,'package',2,2,30,'杯','fixed','[]'::jsonb,true);
 insert into public.yt_member_orders(source,status,amount_rm,payment_status,payment_method,paid_at,created_by,paid_by,notes)
 values('future_pos','fulfilled',16,'paid','cash',clock_timestamp(),owner_id,owner_id,'KDS history note') returning id into order_id;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
 values(order_id,product,'rollback kds privacy',1,16) returning id into item_id;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 payload:=public.yt_store_box_issue(item_id,token,gen_random_uuid(),2);box_id:=(payload->>'box_id')::uuid;
 payload:=public.yt_store_box_claims_active();
 select x->>'issued_by_name' into issuer from jsonb_array_elements(payload)x where x->>'box_id'=box_id::text;
 if issuer is not null then raise exception 'staff_can_see_qr_issuer';end if;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',cashier_id)::text,true);
 payload:=public.yt_store_box_claims_active();
 select x->>'issued_by_name' into issuer from jsonb_array_elements(payload)x where x->>'box_id'=box_id::text;
 if issuer is distinct from staff_name then raise exception 'cashier_cannot_see_qr_issuer';end if;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member_id)::text,true);
 perform public.yt_store_box_claim(token);
 payload:=public.yt_store_box_request_v3(box_id,1,'[]'::jsonb,gen_random_uuid(),'T-TEST');

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 payload:=public.yt_store_box_staff_boxes();
 select x into row_data from jsonb_array_elements(payload)x where x->>'id'=box_id::text;
 if row_data->>'customer_name' is not null or row_data->>'customer_phone' is not null or row_data->>'claimed_qr_issued_by_name' is not null then raise exception 'staff_can_see_claim_identity';end if;
 payload:=public.yt_store_box_queue();
 select x into row_data from jsonb_array_elements(payload)x where x->>'table_label'='T-TEST';
 if row_data is null or row_data->>'customer_name' is not null or row_data->>'customer_phone' is not null or row_data->>'request_customer_id' is not null then raise exception 'store_box_kds_exposes_customer';end if;
 request_id:=(row_data->>'request_id')::uuid;
 begin
  perform public.yt_store_box_progress(box_id,'pause',0);
  raise exception 'staff_pause_succeeded';
 exception when others then
  if sqlerrm<>'cashier_or_owner_only' then raise;end if;
 end;
 perform public.yt_store_box_request_action(request_id,'serve',0,'');
 history:=public.yt_kds_history(private.yt_business_day(clock_timestamp()),100);
 if not exists(select 1 from jsonb_array_elements(history->'orders')x where x->>'id'=order_id::text and x->>'notes'='KDS history note') then raise exception 'regular_kds_history_or_notes_missing';end if;
 if not exists(select 1 from jsonb_array_elements(history->'store_box_requests')x where x->>'table_label'='T-TEST' and x->>'status'='served') then raise exception 'store_box_kds_history_missing';end if;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',cashier_id)::text,true);
 perform public.yt_store_box_progress(box_id,'pause',0);
 perform public.yt_store_box_progress(box_id,'resume',0);
end $$;
rollback;
