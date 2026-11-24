-- Hosted regression: uses the real checkout/rewards pipeline and rolls back all test records.
begin;
do $test$
declare actor uuid; drink uuid; menu uuid:=gen_random_uuid(); package uuid:=gen_random_uuid(); day date; d jsonb; r jsonb; prior jsonb; sid uuid;review boolean;
begin
 select auth_user_id into actor from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 if actor is null then raise exception 'test_owner_missing';end if;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 select id into drink from public.yt_shop_products where active and is_drink limit 1;
 if drink is null then raise exception 'test_drink_missing';end if;
 day:=private.yt_business_day(clock_timestamp());
 insert into public.yt_freeflow_menus(id,name,start_time,end_time) values(menu,'Rollback checkout regression','23:58','23:59');
 insert into public.yt_freeflow_menu_items values(menu,drink);
 perform public.yt_freeflow('package_save',jsonb_build_object('id',package,'name','Rollback checkout regression','price_rm',45,'pax_per_unit',1,'menu_id',menu,'active',true));
 foreach review in array array[false,true] loop
  d:=jsonb_build_object('p_request',gen_random_uuid(),'p_draft',gen_random_uuid(),'p_table','TST-'||left(gen_random_uuid()::text,8),'p_note','rollback regression','p_items',jsonb_build_array(jsonb_build_object('product_id',package,'quantity',2)),'p_channel','cashier','p_checkout_mode',case when review then 'pay_now' else 'pay_later' end,'p_business_day',day);
  r:=public.yt_ff_checkout_order(d,false);
  if r->>'status'<>'fulfilled' then raise exception 'test_package_status: %',r;end if;
  select id into sid from public.yt_freeflow_sessions where order_id=(r->>'id')::uuid;
  if sid is null then raise exception 'test_group_missing';end if;
  if not exists(select 1 from public.yt_freeflow_sessions where id=sid and capacity=2 and starts_at>clock_timestamp()) then raise exception 'test_not_before_service_window';end if;
  prior:=public.yt_ff_checkout_order(d,false);
  if not (prior->>'idempotent')::boolean or prior->>'id'<>r->>'id' then raise exception 'test_retry_failed';end if;
 end loop;
 d:=jsonb_build_object('p_request',gen_random_uuid(),'p_draft',gen_random_uuid(),'p_table','TST-'||left(gen_random_uuid()::text,8),'p_note','rollback mixed','p_items',jsonb_build_array(jsonb_build_object('product_id',package,'quantity',1),jsonb_build_object('product_id',drink,'quantity',1)),'p_channel','cashier','p_checkout_mode','pay_later','p_business_day',day);
 r:=public.yt_ff_checkout_order(d,false);
 if r->>'status'<>'confirmed' then raise exception 'test_mixed_status: %',r;end if;
 select coalesce((select require_review from public.yt_pos_order_review_settings where singleton),true) into review;
 d:=jsonb_build_object('p_request',gen_random_uuid(),'p_draft',gen_random_uuid(),'p_table','TST-'||left(gen_random_uuid()::text,8),'p_note','rollback staff','p_items',jsonb_build_array(jsonb_build_object('product_id',package,'quantity',1)),'p_channel','staff','p_checkout_mode','pay_later','p_business_day',day);
 r:=public.yt_ff_checkout_order(d,false);
 if r->>'status'<>(case when review then 'pending' else 'fulfilled' end) then raise exception 'test_staff_review_status: %',r;end if;
 if coalesce(current_setting('yt.ff.checkout_building',true),'')<>'' then raise exception 'test_guard_leaked';end if;
end $test$;
select 'PASS actual rewards/Moon checkout: before service window, pay-now, pay-later, exact retry, mixed drinks, Staff review; all writes rolled back' result;
rollback;
