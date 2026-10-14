-- POS Ambassador issue and cart handoff: no-commission POS-issued passes, seven-day booking window.
alter table public.yt_ambassador_passes alter column ambassador_id drop not null;
alter table public.yt_ambassador_passes add column if not exists issued_by uuid references auth.users(id) on delete restrict;
alter table public.yt_ambassador_checkins alter column ambassador_id drop not null;
alter table public.yt_ambassador_pos_sales alter column ambassador_id drop not null;

create or replace function private.yt_ambassador_work_pass_save(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.yt_ambassadors%rowtype; v public.yt_ambassador_passes%rowtype;
 pid uuid; d date; pax integer; ptype text;
begin
 if not private.yt_ambassador_work_access() then raise exception 'ambassador_work_only';end if;
 select * into a from public.yt_ambassadors where work_user_id=auth.uid() and active limit 1;
 begin pid:=nullif(p_payload->>'id','')::uuid;d:=nullif(p_payload->>'reservation_day','')::date;
  pax:=nullif(p_payload->>'planned_pax','')::integer;exception when others then raise exception 'invalid_pass';end;
 ptype:=coalesce(p_payload->>'pass_type','group');
 if d is null or d<private.yt_business_day(now()) or d>private.yt_business_day(now())+7 then raise exception 'invalid_reservation_day';end if;
 if pax not between 1 and 500 or ptype not in ('group','individual') then raise exception 'invalid_planned_pax';end if;
 if length(coalesce(p_payload->>'guest_name',''))>100 or length(coalesce(p_payload->>'guest_phone',''))>40
  or length(coalesce(p_payload->>'remark',''))>500 then raise exception 'invalid_pass';end if;
 if pid is null then
  insert into public.yt_ambassador_passes(ambassador_id,issued_by,reservation_day,pass_type,planned_pax,guest_name,guest_phone,remark)
  values(a.id,auth.uid(),d,ptype,pax,coalesce(p_payload->>'guest_name',''),coalesce(p_payload->>'guest_phone',''),coalesce(p_payload->>'remark',''))
  returning * into v;
 else
  select * into v from public.yt_ambassador_passes where id=pid and ambassador_id=a.id and status='issued' for update;
  if v.id is null then raise exception 'pass_not_editable';end if;
  if exists(select 1 from public.yt_ambassador_checkins where pass_id=v.id) then raise exception 'pass_already_checked_in';end if;
  update public.yt_ambassador_passes set reservation_day=d,pass_type=ptype,planned_pax=pax,guest_name=coalesce(p_payload->>'guest_name',''),
   guest_phone=coalesce(p_payload->>'guest_phone',''),remark=coalesce(p_payload->>'remark',''),updated_at=now()
   where id=v.id returning * into v;
 end if;
 return jsonb_build_object('id',v.id,'pass_code',v.pass_code,'reservation_day',v.reservation_day,'planned_pax',v.planned_pax,
  'pass_type',v.pass_type,'guest_name',v.guest_name);
end $$;

create or replace function private.yt_ambassador_pos_issue_portal()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare d date:=private.yt_business_day(now()); p jsonb; today jsonb; mine jsonb;
begin
 if auth.uid() is null or not (private.yt_pos_work_cashier() or private.yt_has_role('owner')) then raise exception 'cashier_only';end if;
 select jsonb_build_object('weekday_male',weekday_male,'weekday_female',weekday_female,
  'weekend_male',weekend_male,'weekend_female',weekend_female,
  'specials',coalesce((select jsonb_agg(jsonb_build_object('business_day',s.business_day,'male',s.male_price,'female',s.female_price)
    order by s.business_day) from public.yt_ambassador_special_prices s where s.business_day between d and d+7),'[]'::jsonb))
 into p from public.yt_ambassador_prices where id=true;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'pass_code',x.pass_code,'reservation_day',x.reservation_day,
  'pass_type',x.pass_type,'planned_pax',x.planned_pax,'guest_name',x.guest_name,'guest_phone',x.guest_phone,
  'remark',x.remark,'status',x.status,'created_at',x.created_at,'checked_pax',coalesce(c.checked_pax,0))
  order by x.reservation_day,x.created_at desc),'[]'::jsonb)
 into mine from public.yt_ambassador_passes x
 left join lateral(select sum(ci.male_count+ci.female_count)::integer checked_pax from public.yt_ambassador_checkins ci where ci.pass_id=x.id)c on true
 where x.issued_by=auth.uid() and x.ambassador_id is null;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'pass_code',x.pass_code,'reservation_day',x.reservation_day,
  'pass_type',x.pass_type,'planned_pax',x.planned_pax,'guest_name',x.guest_name,'guest_phone',x.guest_phone,
  'status',x.status,'created_at',x.created_at,'ambassador_name',coalesce(nullif(a.display_name,''),''),
  'issued_by_name',coalesce(nullif(pr.display_name,''),wa.username,'POS'),
  'checked_pax',coalesce(c.checked_pax,0),'checked_male',coalesce(c.checked_male,0),'checked_female',coalesce(c.checked_female,0))
  order by x.created_at),'[]'::jsonb)
 into today from public.yt_ambassador_passes x
 left join public.yt_ambassadors a on a.id=x.ambassador_id
 left join public.work_accounts wa on wa.auth_user_id=x.issued_by
 left join public.profiles pr on pr.id=x.issued_by
 left join lateral(select sum(ci.male_count+ci.female_count)::integer checked_pax,
  sum(ci.male_count)::integer checked_male,sum(ci.female_count)::integer checked_female
  from public.yt_ambassador_checkins ci where ci.pass_id=x.id)c on true
 where x.reservation_day=d and x.status='issued';
 return jsonb_build_object('enabled',true,'mode','pos_direct','business_day',d,'prices',p,'passes',mine,'today_passes',today);
end $$;

create or replace function private.yt_ambassador_pos_pass_save(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_ambassador_passes%rowtype; pid uuid; d date; pax integer; ptype text;
begin
 if auth.uid() is null or not (private.yt_pos_work_cashier() or private.yt_has_role('owner')) then raise exception 'cashier_only';end if;
 begin pid:=nullif(p_payload->>'id','')::uuid;d:=nullif(p_payload->>'reservation_day','')::date;
  pax:=nullif(p_payload->>'planned_pax','')::integer;exception when others then raise exception 'invalid_pass';end;
 ptype:=coalesce(p_payload->>'pass_type','group');
 if d is null or d<private.yt_business_day(now()) or d>private.yt_business_day(now())+7 then raise exception 'invalid_reservation_day';end if;
 if pax not between 1 and 500 or ptype not in ('group','individual') then raise exception 'invalid_planned_pax';end if;
 if length(coalesce(p_payload->>'guest_name',''))>100 or length(coalesce(p_payload->>'guest_phone',''))>40
  or length(coalesce(p_payload->>'remark',''))>500 then raise exception 'invalid_pass';end if;
 if pid is null then
  insert into public.yt_ambassador_passes(ambassador_id,issued_by,reservation_day,pass_type,planned_pax,guest_name,guest_phone,remark)
  values(null,auth.uid(),d,ptype,pax,coalesce(p_payload->>'guest_name',''),coalesce(p_payload->>'guest_phone',''),coalesce(p_payload->>'remark',''))
  returning * into v;
 else
  select * into v from public.yt_ambassador_passes where id=pid and issued_by=auth.uid() and ambassador_id is null and status='issued' for update;
  if v.id is null then raise exception 'pass_not_editable';end if;
  if exists(select 1 from public.yt_ambassador_checkins where pass_id=v.id) then raise exception 'pass_already_checked_in';end if;
  update public.yt_ambassador_passes set reservation_day=d,pass_type=ptype,planned_pax=pax,guest_name=coalesce(p_payload->>'guest_name',''),
   guest_phone=coalesce(p_payload->>'guest_phone',''),remark=coalesce(p_payload->>'remark',''),updated_at=now()
   where id=v.id returning * into v;
 end if;
 return jsonb_build_object('id',v.id,'pass_code',v.pass_code,'reservation_day',v.reservation_day,'planned_pax',v.planned_pax,'pass_type',v.pass_type);
end $$;

create or replace function private.yt_ambassador_pos_pass_lookup(p_token text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.yt_ambassadors%rowtype; v public.yt_ambassador_passes%rowtype; d date:=private.yt_business_day(now()); pp jsonb; code text; issuer text;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 code:=(regexp_match(trim(coalesce(p_token,'')),'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'))[1];
 if code is null then raise exception 'ambassador_pass_not_found';end if;
 begin select * into v from public.yt_ambassador_passes where pass_code=code::uuid and status='issued';
 exception when invalid_text_representation then raise exception 'ambassador_pass_not_found';end;
 if v.id is null then raise exception 'ambassador_pass_not_found';end if;
 if v.issued_by=auth.uid() then raise exception 'cannot_redeem_own_pass';end if;
 if v.ambassador_id is not null then
  select * into a from public.yt_ambassadors where id=v.ambassador_id and active;
  if a.id is null then raise exception 'ambassador_inactive';end if;
  if a.member_user_id=auth.uid() or a.work_user_id=auth.uid() then raise exception 'cannot_redeem_own_pass';end if;
 end if;
 if d<>v.reservation_day or now()<private.yt_business_start(v.reservation_day)
  or now()>=private.yt_business_start(v.reservation_day+1) then raise exception 'ambassador_pass_not_valid_today';end if;
 pp:=private.yt_ambassador_price(v.reservation_day);
 if coalesce((pp->>'male')::numeric,0)<=0 or coalesce((pp->>'female')::numeric,0)<=0 then raise exception 'ambassador_prices_not_configured';end if;
 select coalesce(nullif(p.display_name,''),wa.username,'POS') into issuer from public.profiles p
  full join public.work_accounts wa on wa.auth_user_id=p.id where p.id=v.issued_by or wa.auth_user_id=v.issued_by limit 1;
 return jsonb_build_object('pass_id',v.id,'pass_code',v.pass_code,'reservation_day',v.reservation_day,
  'pass_type',v.pass_type,'planned_pax',v.planned_pax,'guest_name',v.guest_name,'guest_phone',v.guest_phone,
  'remark',v.remark,'ambassador_id',v.ambassador_id,'ambassador_name',case when v.ambassador_id is null then 'POS 直发' else coalesce(nullif(a.display_name,''),'Ambassador') end,
  'issued_by_name',issuer,'commission_rate',coalesce(a.commission_rate,0),'male_price',(pp->>'male')::numeric,'female_price',(pp->>'female')::numeric,
  'checked_pax',(select coalesce(sum(c.male_count+c.female_count),0) from public.yt_ambassador_checkins c where c.pass_id=v.id),
  'sales',(select coalesce(sum(c.sales),0) from public.yt_ambassador_checkins c where c.pass_id=v.id),
  'commission',(select coalesce(sum(c.commission_amount),0) from public.yt_ambassador_checkins c where c.pass_id=v.id));
end $$;

create or replace function private.yt_ambassador_pos_order_create(p_token text,p_male integer,p_female integer,p_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_ambassador_passes%rowtype; a public.yt_ambassadors%rowtype; pp jsonb; code text;
 d date:=private.yt_business_day(now()); mp numeric; fp numeric; amount numeric(12,2);
 oid uuid; ono text; old_sale public.yt_ambassador_pos_sales%rowtype; note_text text; rate numeric(5,2);
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_request is null or p_male is null or p_female is null or p_male<0 or p_female<0 or p_male+p_female<1 or p_male+p_female>500 then
  raise exception 'invalid_guest_count';end if;
 perform pg_advisory_xact_lock(hashtextextended('yt-ambassador-order:'||p_request::text,0));
 select * into old_sale from public.yt_ambassador_pos_sales where request_id=p_request;
 if old_sale.order_id is not null then
  if old_sale.created_by<>auth.uid() or old_sale.male_count<>p_male or old_sale.female_count<>p_female then raise exception 'request_conflict';end if;
  select order_no into ono from public.yt_member_orders where id=old_sale.order_id;
  return jsonb_build_object('order_id',old_sale.order_id,'order_no',ono,'idempotent',true);
 end if;
 code:=(regexp_match(trim(coalesce(p_token,'')),'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'))[1];
 if code is null then raise exception 'ambassador_pass_not_found';end if;
 begin select * into v from public.yt_ambassador_passes where pass_code=code::uuid and status='issued' for update;
 exception when invalid_text_representation then raise exception 'ambassador_pass_not_found';end;
 if v.id is null then raise exception 'ambassador_pass_not_found';end if;
 if v.issued_by=auth.uid() then raise exception 'cannot_redeem_own_pass';end if;
 if v.ambassador_id is not null then
  select * into a from public.yt_ambassadors where id=v.ambassador_id and active;
  if a.id is null then raise exception 'ambassador_inactive';end if;
  if a.member_user_id=auth.uid() or a.work_user_id=auth.uid() then raise exception 'cannot_redeem_own_pass';end if;
 end if;
 if d<>v.reservation_day or now()<private.yt_business_start(v.reservation_day)
  or now()>=private.yt_business_start(v.reservation_day+1) then raise exception 'ambassador_pass_not_valid_today';end if;
 pp:=private.yt_ambassador_price(v.reservation_day);mp:=(pp->>'male')::numeric;fp:=(pp->>'female')::numeric;
 if coalesce(mp,0)<=0 or coalesce(fp,0)<=0 then raise exception 'ambassador_prices_not_configured';end if;
 rate:=coalesce(a.commission_rate,0);amount:=round(p_male*mp+p_female*fp,2);
 if amount<=0 or amount>100000 then raise exception 'order_too_large';end if;
 ono:='YT'||to_char(clock_timestamp() at time zone 'Asia/Kuala_Lumpur','YYMMDD')||'-'||lpad(nextval('public.yt_pos_order_serial'::regclass)::text,6,'0');
 note_text:='Freeflow Pass · '||case when v.ambassador_id is null then 'POS 直发' else coalesce(nullif(a.display_name,''),'Ambassador') end;
 insert into public.yt_member_orders(source,status,order_no,table_label,notes,payment_status,created_by,created_at,updated_at,
  client_request_id,amount_rm,accepted_at,accepted_by,fulfilled_at,fulfilled_by)
 values('future_pos','fulfilled',ono,'Freeflow',note_text,'unpaid',auth.uid(),clock_timestamp(),clock_timestamp(),
  p_request,amount,clock_timestamp(),auth.uid(),clock_timestamp(),auth.uid()) returning id into oid;
 if p_male>0 then
  insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm,is_drink_at_order)
   values(oid,null,'Freeflow Male',p_male,mp,false);
 end if;
 if p_female>0 then
  insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm,is_drink_at_order)
   values(oid,null,'Freeflow Female',p_female,fp,false);
 end if;
 insert into public.yt_ambassador_pos_sales(order_id,request_id,pass_id,ambassador_id,business_day,male_count,female_count,
  male_price,female_price,commission_rate,created_by)
 values(oid,p_request,v.id,v.ambassador_id,d,p_male,p_female,mp,fp,rate,auth.uid());
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note)
  values(oid,auth.uid(),'created','ambassador',note_text);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(auth.uid(),'pos.ambassador_sale_created','pos_order',oid,
   jsonb_build_object('pass_id',v.id,'male_count',p_male,'female_count',p_female,'amount_rm',amount,'business_day',d,'commission_rate',rate));
 return jsonb_build_object('order_id',oid,'order_no',ono,'amount_rm',amount,'status','fulfilled','commission_rate',rate,'idempotent',false);
end $$;

create or replace function public.yt_ambassador_pos_issue_portal()
returns jsonb language sql security invoker set search_path='' as $$ select private.yt_ambassador_pos_issue_portal() $$;
create or replace function public.yt_ambassador_pos_pass_save(p_payload jsonb)
returns jsonb language sql security invoker set search_path='' as $$ select private.yt_ambassador_pos_pass_save(p_payload) $$;

revoke all on function private.yt_ambassador_pos_issue_portal(),private.yt_ambassador_pos_pass_save(jsonb),
 private.yt_ambassador_work_pass_save(jsonb),private.yt_ambassador_pos_pass_lookup(text),
 private.yt_ambassador_pos_order_create(text,integer,integer,uuid) from public,anon,authenticated;
grant execute on function private.yt_ambassador_pos_issue_portal(),private.yt_ambassador_pos_pass_save(jsonb),
 private.yt_ambassador_work_pass_save(jsonb),private.yt_ambassador_pos_pass_lookup(text),
 private.yt_ambassador_pos_order_create(text,integer,integer,uuid) to authenticated;
revoke all on function public.yt_ambassador_pos_issue_portal(),public.yt_ambassador_pos_pass_save(jsonb) from public,anon;
grant execute on function public.yt_ambassador_pos_issue_portal(),public.yt_ambassador_pos_pass_save(jsonb) to authenticated;
