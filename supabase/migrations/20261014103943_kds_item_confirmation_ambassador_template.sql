-- Per-line KDS completion, persistent invite-card artwork, and seven-day Ambassador window.
alter table public.yt_member_order_items
  add column if not exists fulfilled boolean not null default false,
  add column if not exists fulfilled_at timestamptz,
  add column if not exists fulfilled_by uuid references auth.users(id);

create or replace function public.yt_pos_orders(p_scope text default 'active',p_limit integer default 60)
returns jsonb language sql set search_path to '' as $function$
 select coalesce(jsonb_agg(
  o || jsonb_build_object('items',coalesce((
   select jsonb_agg(item || jsonb_build_object('fulfilled',coalesce(li.fulfilled,false)) order by item->>'name')
   from jsonb_array_elements(o->'items') as x(item) left join public.yt_member_order_items li on li.id=(item->>'id')::uuid
  ),'[]'::jsonb)) order by (o->>'created_at')::timestamptz desc),'[]'::jsonb)
 from jsonb_array_elements(private.yt_pos_orders(p_scope,p_limit)) o;
$function$;

create or replace function public.yt_pos_orders_day(p_scope text default 'active',p_day date default null,p_limit integer default 60)
returns jsonb language sql set search_path to '' as $function$
 select coalesce(jsonb_agg(
  o || jsonb_build_object('items',coalesce((
   select jsonb_agg(item || jsonb_build_object('fulfilled',coalesce(li.fulfilled,false)) order by item->>'name')
   from jsonb_array_elements(o->'items') as x(item) left join public.yt_member_order_items li on li.id=(item->>'id')::uuid
  ),'[]'::jsonb)) order by (o->>'created_at')::timestamptz desc),'[]'::jsonb)
 from jsonb_array_elements(private.yt_pos_orders_day(p_scope,p_day,p_limit)) o;
$function$;

create or replace function public.yt_pos_item_fulfill(p_order uuid,p_order_item uuid default null,p_all boolean default false)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v public.yt_member_orders%rowtype;v_actor uuid:=auth.uid();v_item public.yt_member_order_items%rowtype;
 v_complete boolean;v_store_box_only boolean;v_claims jsonb:='[]'::jsonb;v_issue jsonb;v_line record;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_order is null or (p_all is distinct from true and p_order_item is null) then raise exception 'invalid_order';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found or v.status<>'confirmed' or v.payment_status not in ('unpaid','paid') then raise exception 'order_not_accepted';end if;
 if p_all then
  update public.yt_member_order_items set fulfilled=true,fulfilled_at=coalesce(fulfilled_at,clock_timestamp()),fulfilled_by=coalesce(fulfilled_by,v_actor)
   where order_id=p_order and quantity>0 and not fulfilled;
 else
  update public.yt_member_order_items set fulfilled=true,fulfilled_at=clock_timestamp(),fulfilled_by=v_actor
   where id=p_order_item and order_id=p_order and quantity>0 and not fulfilled returning * into v_item;
  if not found then
   select * into v_item from public.yt_member_order_items where id=p_order_item and order_id=p_order;
   if v_item.id is null then raise exception 'item_not_in_order';end if;
  end if;
 end if;
 select not exists(select 1 from public.yt_member_order_items where order_id=p_order and quantity>0 and not fulfilled) into v_complete;
 if v_complete then
  update public.yt_member_orders set status='fulfilled',fulfilled_by=v_actor,fulfilled_at=clock_timestamp(),updated_at=clock_timestamp() where id=p_order;
 else update public.yt_member_orders set updated_at=clock_timestamp() where id=p_order;
 end if;
 if v_complete and v.payment_status='paid' then
  for v_line in select i.id from public.yt_member_order_items i join public.yt_store_box_product_rules r on r.product_id=i.product_id and r.active
    where i.order_id=p_order and i.quantity>0 and not exists(select 1 from public.yt_store_boxes b where b.source_order_item_id=i.id and b.cashier_managed) order by i.id loop
   v_issue:=private.yt_store_box_issue(v_line.id,gen_random_uuid(),gen_random_uuid(),2);v_claims:=v_claims||jsonb_build_array(v_issue);
  end loop;
 end if;
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note)
 values(p_order,v_actor,'fulfilled',case when private.yt_pos_work_cashier() then 'cashier' else 'staff' end,
  case when p_all then '整单确认出品' else coalesce(v_item.item_name,'单项确认出品') end);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(v_actor,'pos.fulfilled','pos_order',p_order,jsonb_build_object('all_items',p_all,'complete',v_complete,'store_box_claims',jsonb_array_length(v_claims)));
 return jsonb_build_object('ok',true,'order_id',p_order,'status',case when v_complete then 'fulfilled' else 'confirmed' end,'complete',v_complete,
  'item_name',case when p_all then null else v_item.item_name end,'store_box_claims',v_claims);
end $function$;
revoke all on function public.yt_pos_item_fulfill(uuid,uuid,boolean) from public,anon;
grant execute on function public.yt_pos_item_fulfill(uuid,uuid,boolean) to authenticated,service_role;

create table if not exists public.yt_ambassador_qr_template(
 singleton boolean primary key default true check(singleton), image_data_url text not null,
 qr_x numeric not null default 50 check(qr_x between 0 and 100),
 qr_y numeric not null default 58 check(qr_y between 0 and 100),
 qr_size numeric not null default 34 check(qr_size between 10 and 80),
 updated_at timestamptz not null default now(), updated_by uuid references auth.users(id)
);
alter table public.yt_ambassador_qr_template enable row level security;
revoke all on public.yt_ambassador_qr_template from public,anon,authenticated;

create or replace function public.yt_ambassador_qr_template_get()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v public.yt_ambassador_qr_template%rowtype;
begin
 if auth.uid() is null or not (private.yt_pos_work_staff() or private.yt_ambassador_work_access()) then raise exception 'staff_only';end if;
 select * into v from public.yt_ambassador_qr_template where singleton;
 if v.singleton is null then return jsonb_build_object('image_data_url',null,'qr_x',50,'qr_y',58,'qr_size',34);end if;
 return jsonb_build_object('image_data_url',v.image_data_url,'qr_x',v.qr_x,'qr_y',v.qr_y,'qr_size',v.qr_size);
end $function$;

create or replace function public.yt_ambassador_qr_template_save(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_image text:=coalesce(p_payload->>'image_data_url','');v_x numeric:=coalesce((p_payload->>'qr_x')::numeric,50);
 v_y numeric:=coalesce((p_payload->>'qr_y')::numeric,58);v_size numeric:=coalesce((p_payload->>'qr_size')::numeric,34);
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if length(v_image)>1400000 or v_image !~ '^data:image/(png|jpeg);base64,[A-Za-z0-9+/=]+$' then raise exception 'invalid_template';end if;
 if v_x not between 0 and 100 or v_y not between 0 and 100 or v_size not between 10 and 80 then raise exception 'invalid_template_position';end if;
 insert into public.yt_ambassador_qr_template(singleton,image_data_url,qr_x,qr_y,qr_size,updated_at,updated_by)
 values(true,v_image,v_x,v_y,v_size,clock_timestamp(),auth.uid()) on conflict(singleton) do update set image_data_url=excluded.image_data_url,
 qr_x=excluded.qr_x,qr_y=excluded.qr_y,qr_size=excluded.qr_size,updated_at=excluded.updated_at,updated_by=excluded.updated_by;
 return jsonb_build_object('ok',true);
end $function$;
revoke all on function public.yt_ambassador_qr_template_get() from public,anon;
revoke all on function public.yt_ambassador_qr_template_save(jsonb) from public,anon;
grant execute on function public.yt_ambassador_qr_template_get() to authenticated,service_role;
grant execute on function public.yt_ambassador_qr_template_save(jsonb) to authenticated,service_role;

create or replace function private.yt_ambassador_pos_pass_save(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v public.yt_ambassador_passes%rowtype; pid uuid; d date; pax integer; ptype text;
begin
 if auth.uid() is null or not (private.yt_pos_work_cashier() or private.yt_has_role('owner') or private.yt_owner_limited()) then raise exception 'cashier_only';end if;
 if private.yt_owner_limited() and nullif(p_payload->>'id','') is not null then raise exception 'pass_not_editable';end if;
 begin pid:=nullif(p_payload->>'id','')::uuid;d:=nullif(p_payload->>'reservation_day','')::date;pax:=nullif(p_payload->>'planned_pax','')::integer;
 exception when others then raise exception 'invalid_pass';end;
 ptype:=coalesce(p_payload->>'pass_type','group');
 if d is null or d<private.yt_business_day(now()) or d>private.yt_business_day(now())+6 then raise exception 'invalid_reservation_day';end if;
 if pax not between 1 and 500 or ptype not in ('group','individual') then raise exception 'invalid_planned_pax';end if;
 if length(coalesce(p_payload->>'guest_name',''))>100 or length(coalesce(p_payload->>'guest_phone',''))>40 or length(coalesce(p_payload->>'remark',''))>500 then raise exception 'invalid_pass';end if;
 if pid is null then
  insert into public.yt_ambassador_passes(ambassador_id,issued_by,reservation_day,pass_type,planned_pax,guest_name,guest_phone,remark)
  values(null,auth.uid(),d,ptype,pax,coalesce(p_payload->>'guest_name',''),coalesce(p_payload->>'guest_phone',''),coalesce(p_payload->>'remark','')) returning * into v;
 else
  select * into v from public.yt_ambassador_passes where id=pid and issued_by=auth.uid() and ambassador_id is null and status='issued' for update;
  if v.id is null then raise exception 'pass_not_editable';end if;
  if exists(select 1 from public.yt_ambassador_checkins where pass_id=v.id) then raise exception 'pass_already_checked_in';end if;
  update public.yt_ambassador_passes set reservation_day=d,pass_type=ptype,planned_pax=pax,guest_name=coalesce(p_payload->>'guest_name',''),guest_phone=coalesce(p_payload->>'guest_phone',''),remark=coalesce(p_payload->>'remark',''),updated_at=now() where id=v.id returning * into v;
 end if;
 return jsonb_build_object('id',v.id,'pass_code',v.pass_code,'reservation_day',v.reservation_day,'planned_pax',v.planned_pax,'pass_type',v.pass_type);
end $function$;
create or replace function private.yt_ambassador_work_pass_save(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare a public.yt_ambassadors%rowtype; v public.yt_ambassador_passes%rowtype; pid uuid; d date; pax integer; ptype text;
begin
 if not private.yt_ambassador_work_access() then raise exception 'ambassador_work_only';end if;
 select * into a from public.yt_ambassadors where work_user_id=auth.uid() and active limit 1;
 begin pid:=nullif(p_payload->>'id','')::uuid;d:=nullif(p_payload->>'reservation_day','')::date;pax:=nullif(p_payload->>'planned_pax','')::integer;
 exception when others then raise exception 'invalid_pass';end;
 ptype:=coalesce(p_payload->>'pass_type','group');
 if d is null or d<private.yt_business_day(now()) or d>private.yt_business_day(now())+6 then raise exception 'invalid_reservation_day';end if;
 if pax not between 1 and 500 or ptype not in ('group','individual') then raise exception 'invalid_planned_pax';end if;
 if length(coalesce(p_payload->>'guest_name',''))>100 or length(coalesce(p_payload->>'guest_phone',''))>40 or length(coalesce(p_payload->>'remark',''))>500 then raise exception 'invalid_pass';end if;
 if pid is null then
  insert into public.yt_ambassador_passes(ambassador_id,issued_by,reservation_day,pass_type,planned_pax,guest_name,guest_phone,remark)
  values(a.id,auth.uid(),d,ptype,pax,coalesce(p_payload->>'guest_name',''),coalesce(p_payload->>'guest_phone',''),coalesce(p_payload->>'remark','')) returning * into v;
 else
  select * into v from public.yt_ambassador_passes where id=pid and ambassador_id=a.id and status='issued' for update;
  if v.id is null then raise exception 'pass_not_editable';end if;
  if exists(select 1 from public.yt_ambassador_checkins where pass_id=v.id) then raise exception 'pass_already_checked_in';end if;
  update public.yt_ambassador_passes set reservation_day=d,pass_type=ptype,planned_pax=pax,guest_name=coalesce(p_payload->>'guest_name',''),guest_phone=coalesce(p_payload->>'guest_phone',''),remark=coalesce(p_payload->>'remark',''),updated_at=now() where id=v.id returning * into v;
 end if;
 return jsonb_build_object('id',v.id,'pass_code',v.pass_code,'reservation_day',v.reservation_day,'planned_pax',v.planned_pax,'pass_type',v.pass_type,'guest_name',v.guest_name);
end $function$;

create or replace function private.yt_ambassador_pos_issue_portal()
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare d date:=private.yt_business_day(now());p jsonb;mine jsonb;today jsonb;
begin
 if auth.uid() is null or not (private.yt_pos_work_cashier() or private.yt_has_role('owner') or private.yt_owner_limited()) then raise exception 'cashier_only';end if;
 select jsonb_build_object('weekday_male',weekday_male_price,'weekday_female',weekday_female_price,'weekend_male',weekend_male_price,'weekend_female',weekend_female_price,
  'specials',coalesce((select jsonb_agg(jsonb_build_object('business_day',s.business_day,'male',s.male_price,'female',s.female_price) order by s.business_day)
  from public.yt_ambassador_special_prices s where s.business_day between d and d+6),'[]'::jsonb)) into p from public.yt_ambassador_prices where id=true;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'pass_code',x.pass_code,'reservation_day',x.reservation_day,'planned_pax',x.planned_pax,'pass_type',x.pass_type,'guest_name',x.guest_name,'guest_phone',x.guest_phone,'remark',x.remark,'status',x.status,'created_at',x.created_at,'checked_pax',coalesce(c.checked_pax,0)) order by x.reservation_day,x.created_at desc),'[]'::jsonb) into mine from public.yt_ambassador_passes x left join lateral(select sum(male_count+female_count) checked_pax from public.yt_ambassador_checkins where pass_id=x.id)c on true where x.issued_by=auth.uid() and x.reservation_day between d and d+6;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'pass_code',x.pass_code,'reservation_day',x.reservation_day,'planned_pax',x.planned_pax,'pass_type',x.pass_type,'guest_name',x.guest_name,'guest_phone',x.guest_phone,'remark',x.remark,'status',x.status,'created_at',x.created_at,'checked_pax',coalesce(c.checked_pax,0),'ambassador_name',a.display_name,'issued_by_name',wa.username) order by x.reservation_day,x.created_at desc),'[]'::jsonb) into today from public.yt_ambassador_passes x left join public.yt_ambassadors a on a.id=x.ambassador_id left join public.work_accounts wa on wa.auth_user_id=x.issued_by left join lateral(select sum(male_count+female_count) checked_pax from public.yt_ambassador_checkins where pass_id=x.id)c on true where x.reservation_day=d and x.status='issued';
 return jsonb_build_object('enabled',true,'mode',case when private.yt_owner_limited() then 'owner_limited' else 'pos_direct' end,'business_day',d,'prices',p,'passes',mine,'today_passes',today);
end $function$;


create or replace function public.yt_ambassador_pos_pass_save(p_payload jsonb) returns jsonb language sql set search_path to '' as $function$ select private.yt_ambassador_pos_pass_save(p_payload); $function$;
create or replace function public.yt_ambassador_work_pass_save(p_payload jsonb) returns jsonb language sql set search_path to '' as $function$ select private.yt_ambassador_work_pass_save(p_payload); $function$;
create or replace function public.yt_ambassador_pos_issue_portal() returns jsonb language sql set search_path to '' as $function$ select private.yt_ambassador_pos_issue_portal(); $function$;
revoke all on function public.yt_ambassador_pos_pass_save(jsonb) from public,anon;
revoke all on function public.yt_ambassador_work_pass_save(jsonb) from public,anon;
revoke all on function public.yt_ambassador_pos_issue_portal() from public,anon;
grant execute on function public.yt_ambassador_pos_pass_save(jsonb),public.yt_ambassador_work_pass_save(jsonb),public.yt_ambassador_pos_issue_portal() to authenticated,service_role;
