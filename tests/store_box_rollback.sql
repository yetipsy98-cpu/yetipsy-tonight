BEGIN;
-- Store Box end-to-end permissions and state-machine check; all fixture data rolls back.
do $$
declare
 owner_id uuid;staff_id uuid;member_id uuid;product uuid;o uuid;item uuid;
 token uuid:=gen_random_uuid();token2 uuid:=gen_random_uuid();claim uuid;box uuid;drink_request uuid;
 r jsonb;before_passes bigint;
begin
 select auth_user_id into owner_id from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 select auth_user_id into staff_id from public.work_accounts where role in ('staff','cashier') and active and not must_change_password order by role limit 1;
 select auth_user_id into member_id from public.pin_accounts where not exists(select 1 from public.work_accounts where auth_user_id=pin_accounts.auth_user_id) limit 1;
 if owner_id is null or staff_id is null or member_id is null then raise exception 'fixture_missing';end if;
 if has_function_privilege('anon','public.yt_store_box_claim(uuid)','execute')
  or has_function_privilege('anon','public.yt_store_box_request(uuid,integer,uuid,text)','execute')
  or has_function_privilege('anon','public.yt_store_box_request_action(uuid,text,integer,text)','execute')
 then raise exception 'store_box_rpc_exposed';end if;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 insert into public.yt_shop_products(title,price_rm,active) values('rollback store box',120,true) returning id into product;
 perform public.yt_store_box_rule_save(product,'challenge',6,2,30,'杯',null,false,true);
 insert into public.yt_member_orders(source,status,amount_rm,payment_status,payment_method,paid_at,created_by,paid_by,table_label)
 values('future_pos','fulfilled',120,'paid','cash',now(),owner_id,owner_id,'T8') returning id into o;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
 values(o,product,'rollback store box',1,120) returning id into item;
 select count(*) into before_passes from public.game_passes;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 r:=public.yt_store_box_issue(item,token,gen_random_uuid(),2);
 box:=(r->>'box_id')::uuid;claim:=(r->>'claim_id')::uuid;
 if jsonb_array_length(public.yt_store_box_claims_active())<1 then raise exception 'active_claim_not_visible';end if;
 begin
  perform public.yt_store_box_issue(item,gen_random_uuid(),gen_random_uuid(),2);raise exception 'expected_failure';
 exception when others then if sqlerrm<>'store_box_claim_already_active' then raise;end if;end;
 perform public.yt_store_box_claim_cancel(claim,'customer changed phone');

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member_id)::text,true);
 begin
  perform public.yt_store_box_claim_preview(token);raise exception 'expected_failure';
 exception when others then if sqlerrm<>'store_box_claim_invalid' then raise;end if;end;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 r:=public.yt_store_box_issue(item,token2,gen_random_uuid(),2);
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member_id)::text,true);
 if public.yt_store_box_claim_preview(token2)->>'name'<>'rollback store box' then raise exception 'claim_preview_wrong';end if;
 r:=public.yt_store_box_claim(token2);
 if r->>'customer_id'<>member_id::text or jsonb_array_length(public.yt_my_store_boxes())<1 then raise exception 'claim_binding_failed';end if;

 r:=public.yt_store_box_request(box,2,gen_random_uuid(),'T9');drink_request:=(r->>'id')::uuid;
 begin
  perform public.yt_store_box_request(box,1,gen_random_uuid(),'T9');raise exception 'expected_failure';
 exception when others then if sqlerrm<>'store_box_request_already_active' then raise;end if;end;
 perform public.yt_store_box_request_cancel(drink_request);
 r:=public.yt_store_box_request(box,2,gen_random_uuid(),'T9');drink_request:=(r->>'id')::uuid;
 begin
  perform public.yt_store_box_queue();raise exception 'expected_failure';
 exception when others then if sqlerrm<>'staff_only' then raise;end if;end;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 perform public.yt_store_box_request_action(drink_request,'serve',0,'');
 if not exists(select 1 from public.yt_store_boxes where id=box and served_units=2 and completed_units=0 and total_units-served_units=4) then raise exception 'served_completed_not_separate';end if;

 -- A challenge may request the next drinks even when the prior drinks are not marked completed.
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member_id)::text,true);
 r:=public.yt_store_box_request(box,2,gen_random_uuid(),'T9');drink_request:=(r->>'id')::uuid;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 perform public.yt_store_box_request_action(drink_request,'accept',0,'');
 perform public.yt_store_box_request_action(drink_request,'serve',1,'');
 perform public.yt_store_box_progress(box,'complete',2);
 if not exists(select 1 from public.yt_store_boxes where id=box and served_units=4 and completed_units=3) then raise exception 'progress_wrong';end if;
 if (select count(*) from public.game_passes)<>before_passes then raise exception 'package_created_gamepass';end if;
end $$;
ROLLBACK;
