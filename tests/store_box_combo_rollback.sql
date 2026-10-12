BEGIN;
-- Combination Store Box workflow; fixtures and state changes are rolled back.
do $$
declare
 owner_id uuid;staff_id uuid;member_id uuid;product uuid;o uuid;item uuid;
 token uuid:=gen_random_uuid();box uuid;drink_request uuid;r jsonb;component text;
begin
 if not exists(
  select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='yt_store_box_rule_save_v2'
   and p.proargnames=array['p_product','p_mode','p_total_units','p_request_limit','p_expiry_days','p_unit_label','p_selection_mode','p_components','p_active']::text[]
 ) or not exists(
  select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='yt_store_box_request_v2'
   and p.proargnames=array['p_box','p_quantity','p_component','p_request','p_table_label']::text[]
 ) then raise exception 'store_box_combo_rpc_argument_names_missing';end if;

 select auth_user_id into owner_id from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 select auth_user_id into staff_id from public.work_accounts where role in ('staff','cashier') and active and not must_change_password order by role limit 1;
 select auth_user_id into member_id from public.pin_accounts where not exists(select 1 from public.work_accounts where auth_user_id=pin_accounts.auth_user_id) limit 1;
 if owner_id is null or staff_id is null or member_id is null then raise exception 'fixture_missing';end if;
 if has_function_privilege('anon','public.yt_store_box_rule_save_v2(uuid,text,integer,integer,integer,text,text,jsonb,boolean)','execute')
  or has_function_privilege('anon','public.yt_store_box_request_v2(uuid,integer,text,uuid,text)','execute')
 then raise exception 'store_box_combo_rpc_exposed';end if;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 insert into public.yt_shop_products(title,price_rm,active) values('rollback combo box',88,true) returning id into product;
 r:=public.yt_store_box_rule_save_v2(
  p_product=>product,p_mode=>'package',p_total_units=>1,p_request_limit=>1,p_expiry_days=>30,p_unit_label=>'杯',
  p_selection_mode=>'customer',p_components=>'[{"name":"A","quantity":1},{"name":"B","quantity":1},{"name":"C","quantity":1}]'::jsonb,p_active=>true
 );
 if (r->>'total_units')::integer<>3 or r->>'selection_mode'<>'customer' or jsonb_array_length(r->'components')<>3 then raise exception 'combo_rule_wrong';end if;
 insert into public.yt_member_orders(source,status,amount_rm,payment_status,payment_method,paid_at,created_by,paid_by,table_label)
 values('future_pos','fulfilled',88,'paid','cash',now(),owner_id,owner_id,'C8') returning id into o;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
 values(o,product,'rollback combo box',1,88) returning id into item;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
 r:=public.yt_store_box_issue(item,token,gen_random_uuid(),2);box:=(r->>'box_id')::uuid;
 if not exists(select 1 from public.yt_store_boxes where id=box and total_units=3 and selection_mode='customer' and jsonb_array_length(components)=3) then raise exception 'combo_snapshot_wrong';end if;

 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member_id)::text,true);
 perform public.yt_store_box_claim(token);
 for component in select unnest(array['c2','c1','c3']) loop
  r:=public.yt_store_box_request_v2(box,1,component,gen_random_uuid(),'C9');drink_request:=(r->>'id')::uuid;
  if r->>'component_key'<>component then raise exception 'combo_choice_wrong';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff_id)::text,true);
  if not exists(select 1 from jsonb_array_elements(public.yt_store_box_queue())x where x->>'request_id'=drink_request::text and x->>'component_key'=component) then raise exception 'combo_queue_wrong';end if;
  perform public.yt_store_box_request_action(drink_request,'serve',0,'');
  perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member_id)::text,true);
 end loop;
 if not exists(select 1 from public.yt_store_boxes where id=box and served_units=3 and status='exhausted') then raise exception 'combo_not_exhausted';end if;
 if not exists(select 1 from jsonb_array_elements(public.yt_my_store_boxes())x where x->>'id'=box::text and x->>'status'='exhausted') then raise exception 'combo_history_missing';end if;
end $$;
ROLLBACK;
