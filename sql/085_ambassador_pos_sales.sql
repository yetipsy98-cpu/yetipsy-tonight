-- Ambassador Pass check-ins are ordinary POS sales. The pass itself stays reusable;
-- each paid POS order records one check-in and one commission entry.
create table if not exists public.yt_ambassador_pos_sales (
 order_id uuid primary key references public.yt_member_orders(id) on delete restrict,
 request_id uuid not null unique,
 pass_id uuid not null references public.yt_ambassador_passes(id) on delete restrict,
 ambassador_id uuid not null references public.yt_ambassadors(id) on delete restrict,
 business_day date not null,
 male_count integer not null check (male_count between 0 and 500),
 female_count integer not null check (female_count between 0 and 500),
 male_price numeric(10,2) not null check (male_price between 0 and 50000),
 female_price numeric(10,2) not null check (female_price between 0 and 50000),
 commission_rate numeric(5,2) not null check (commission_rate between 0 and 100),
 created_by uuid not null references auth.users(id) on delete restrict,
 created_at timestamptz not null default now(),
 check (male_count + female_count > 0)
);
create index if not exists yt_ambassador_pos_sales_pass_idx on public.yt_ambassador_pos_sales(pass_id,created_at desc);
alter table public.yt_ambassador_pos_sales enable row level security;
revoke all on public.yt_ambassador_pos_sales from public,anon,authenticated;

create or replace function private.yt_ambassador_pos_pass_lookup(p_token text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.yt_ambassadors%rowtype; v public.yt_ambassador_passes%rowtype;
 d date:=private.yt_business_day(now()); pp jsonb; code text;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 code:=regexp_replace(trim(coalesce(p_token,'')),'^(YTAMB:|ambassador:|https?://[^ ]*[?&]amb=)','', 'i');
 begin select * into v from public.yt_ambassador_passes where pass_code=code::uuid and status='issued';
 exception when invalid_text_representation then raise exception 'ambassador_pass_not_found';end;
 if v.id is null then raise exception 'ambassador_pass_not_found';end if;
 select * into a from public.yt_ambassadors where id=v.ambassador_id and active;
 if a.id is null then raise exception 'ambassador_inactive';end if;
 if a.member_user_id=auth.uid() or a.work_user_id=auth.uid() then raise exception 'cannot_redeem_own_pass';end if;
 if d<>v.reservation_day or now()<private.yt_business_start(v.reservation_day)
  or now()>=private.yt_business_start(v.reservation_day+1) then raise exception 'ambassador_pass_not_valid_today';end if;
 pp:=private.yt_ambassador_price(v.reservation_day);
 if coalesce((pp->>'male')::numeric,0)<=0 or coalesce((pp->>'female')::numeric,0)<=0 then raise exception 'ambassador_prices_not_configured';end if;
 return jsonb_build_object('pass_id',v.id,'pass_code',v.pass_code,'reservation_day',v.reservation_day,
  'pass_type',v.pass_type,'planned_pax',v.planned_pax,'guest_name',v.guest_name,'guest_phone',v.guest_phone,
  'remark',v.remark,'ambassador_name',coalesce(nullif(a.display_name,''),'Ambassador'),
  'commission_rate',a.commission_rate,'male_price',(pp->>'male')::numeric,'female_price',(pp->>'female')::numeric,
  'checked_pax',(select coalesce(sum(c.male_count+c.female_count),0) from public.yt_ambassador_checkins c where c.pass_id=v.id),
  'sales',(select coalesce(sum(c.sales),0) from public.yt_ambassador_checkins c where c.pass_id=v.id),
  'commission',(select coalesce(sum(c.commission_amount),0) from public.yt_ambassador_checkins c where c.pass_id=v.id));
end $$;

create or replace function private.yt_ambassador_pos_order_create(p_token text,p_male integer,p_female integer,p_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_ambassador_passes%rowtype; a public.yt_ambassadors%rowtype; pp jsonb; code text;
 d date:=private.yt_business_day(now()); mp numeric; fp numeric; amount numeric(12,2);
 oid uuid; ono text; old_sale public.yt_ambassador_pos_sales%rowtype; note_text text;
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
 code:=regexp_replace(trim(coalesce(p_token,'')),'^(YTAMB:|ambassador:|https?://[^ ]*[?&]amb=)','', 'i');
 begin select * into v from public.yt_ambassador_passes where pass_code=code::uuid and status='issued' for update;
 exception when invalid_text_representation then raise exception 'ambassador_pass_not_found';end;
 if v.id is null then raise exception 'ambassador_pass_not_found';end if;
 select * into a from public.yt_ambassadors where id=v.ambassador_id and active;
 if a.id is null then raise exception 'ambassador_inactive';end if;
 if a.member_user_id=auth.uid() or a.work_user_id=auth.uid() then raise exception 'cannot_redeem_own_pass';end if;
 if d<>v.reservation_day or now()<private.yt_business_start(v.reservation_day)
  or now()>=private.yt_business_start(v.reservation_day+1) then raise exception 'ambassador_pass_not_valid_today';end if;
 pp:=private.yt_ambassador_price(v.reservation_day);mp:=(pp->>'male')::numeric;fp:=(pp->>'female')::numeric;
 if coalesce(mp,0)<=0 or coalesce(fp,0)<=0 then raise exception 'ambassador_prices_not_configured';end if;
 amount:=round(p_male*mp+p_female*fp,2);
 if amount<=0 or amount>100000 then raise exception 'order_too_large';end if;
 ono:='YT'||to_char(clock_timestamp() at time zone 'Asia/Kuala_Lumpur','YYMMDD')||'-'||lpad(nextval('public.yt_pos_order_serial'::regclass)::text,6,'0');
 note_text:='Freeflow Pass · '||coalesce(nullif(a.display_name,''),'Ambassador');
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
 values(oid,p_request,v.id,a.id,d,p_male,p_female,mp,fp,a.commission_rate,auth.uid());
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note)
  values(oid,auth.uid(),'created','ambassador',note_text);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(auth.uid(),'pos.ambassador_sale_created','pos_order',oid,
   jsonb_build_object('pass_id',v.id,'male_count',p_male,'female_count',p_female,'amount_rm',amount,'business_day',d));
 return jsonb_build_object('order_id',oid,'order_no',ono,'amount_rm',amount,'status','fulfilled','idempotent',false);
end $$;

create or replace function private.yt_ambassador_pos_payment_method()
returns trigger language plpgsql security definer set search_path='' as $$
declare s public.yt_ambassador_pos_sales%rowtype; v public.yt_ambassador_passes%rowtype;
begin
 if new.source<>'future_pos' or new.payment_status<>'paid' or old.payment_status='paid' then return new;end if;
 select * into s from public.yt_ambassador_pos_sales where order_id=new.id;
 if s.order_id is null then
  if coalesce(new.payment_method,'') like 'AB_%' then raise exception 'invalid_payment_method';end if;
  return new;
 end if;
 if private.yt_business_day(coalesce(new.paid_at,now()))<>s.business_day then raise exception 'ambassador_pass_not_valid_today';end if;
 select * into v from public.yt_ambassador_passes where id=s.pass_id and status='issued';
 if v.id is null or v.reservation_day<>s.business_day then raise exception 'ambassador_pass_not_valid_today';end if;
 if new.payment_method not in ('foodcourt','cash','duitnow','card','bank_transfer','other') then raise exception 'invalid_payment_method';end if;
 new.payment_method:='AB_'||case new.payment_method when 'duitnow' then 'DuitNow' when 'cash' then 'Cash'
  when 'card' then 'Card' when 'bank_transfer' then 'Bank_Transfer' when 'foodcourt' then 'Foodcourt' else 'Other' end;
 return new;
end $$;
drop trigger if exists yt_ambassador_pos_payment_method on public.yt_member_orders;
create trigger yt_ambassador_pos_payment_method before update of payment_status,payment_method
 on public.yt_member_orders for each row execute function private.yt_ambassador_pos_payment_method();

create or replace function private.yt_ambassador_pos_capture()
returns trigger language plpgsql security definer set search_path='' as $$
declare s public.yt_ambassador_pos_sales%rowtype; ci public.yt_ambassador_checkins%rowtype;
 sales_amount numeric(12,2); commission numeric(12,2);
begin
 if new.source<>'future_pos' or new.payment_status<>'paid' or old.payment_status='paid' then return new;end if;
 select * into s from public.yt_ambassador_pos_sales where order_id=new.id;
 if s.order_id is null then return new;end if;
 sales_amount:=round(s.male_count*s.male_price+s.female_count*s.female_price,2);
 commission:=round(sales_amount*s.commission_rate/100,2);
 insert into public.yt_ambassador_checkins(request_id,pass_id,ambassador_id,checked_by,business_day,male_count,
  female_count,male_price,female_price,sales,commission_rate,commission_amount,note)
 values(new.id,s.pass_id,s.ambassador_id,new.paid_by,s.business_day,s.male_count,s.female_count,
  s.male_price,s.female_price,sales_amount,s.commission_rate,commission,'POS 收款完成')
 on conflict(request_id) do nothing returning * into ci;
 if ci.id is null then select * into ci from public.yt_ambassador_checkins where request_id=new.id;end if;
 if commission>0 then
  insert into public.yt_ambassador_ledger(ambassador_id,checkin_id,entry_type,amount,created_by,business_day,note)
  values(s.ambassador_id,ci.id,'commission',commission,new.paid_by,s.business_day,'Freeflow POS 销售佣金')
  on conflict(checkin_id) do nothing;
 end if;
 return new;
end $$;
drop trigger if exists yt_ambassador_pos_capture on public.yt_member_orders;
create trigger yt_ambassador_pos_capture after update of payment_status on public.yt_member_orders
 for each row execute function private.yt_ambassador_pos_capture();

create or replace function private.yt_ambassador_work_portal()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.yt_ambassadors%rowtype; d date:=private.yt_business_day(now()); p jsonb; prices jsonb; wallet numeric;
begin
 if auth.uid() is null then raise exception 'not_authenticated';end if;
 select * into a from public.yt_ambassadors where work_user_id=auth.uid() and active limit 1;
 if a.id is null or not private.yt_ambassador_work_access() then return jsonb_build_object('enabled',false);end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'pass_code',x.pass_code,'reservation_day',x.reservation_day,
  'pass_type',x.pass_type,'planned_pax',x.planned_pax,'guest_name',x.guest_name,'guest_phone',x.guest_phone,
  'remark',x.remark,'status',x.status,'created_at',x.created_at,'checked_pax',coalesce(c.checked_pax,0),
  'sales',coalesce(c.sales,0),'commission',coalesce(c.commission,0)) order by x.reservation_day desc,x.created_at desc),'[]'::jsonb)
 into p from public.yt_ambassador_passes x
 left join lateral(select sum(ci.male_count+ci.female_count)::integer checked_pax,sum(ci.sales)::numeric sales,
  sum(ci.commission_amount)::numeric commission from public.yt_ambassador_checkins ci where ci.pass_id=x.id)c on true
 where x.ambassador_id=a.id;
 select coalesce(sum(l.amount),0) into wallet from public.yt_ambassador_ledger l where l.ambassador_id=a.id;
 select jsonb_build_object('weekday_male',weekday_male,'weekday_female',weekday_female,'weekend_male',weekend_male,
  'weekend_female',weekend_female,'specials',coalesce((select jsonb_agg(jsonb_build_object('business_day',sp.business_day,
  'male',sp.male_price,'female',sp.female_price) order by sp.business_day desc) from public.yt_ambassador_special_prices sp),'[]'::jsonb))
 into prices from public.yt_ambassador_prices where id=true;
 return jsonb_build_object('enabled',true,'ambassador',jsonb_build_object('id',a.id,'display_name',a.display_name,
  'commission_rate',a.commission_rate),'business_day',d,'cutoff_minutes',(select cutoff_minutes from public.yt_business_cutoffs
  where effective_day<=d order by effective_day desc limit 1),'prices',prices,'rates_for_today',private.yt_ambassador_price(d),
  'wallet_balance',wallet,'passes',p);
end $$;

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
 if d is null or d<private.yt_business_day(now()) or d>private.yt_business_day(now())+180 then raise exception 'invalid_reservation_day';end if;
 if pax not between 1 and 500 or ptype not in ('group','individual') then raise exception 'invalid_planned_pax';end if;
 if length(coalesce(p_payload->>'guest_name',''))>100 or length(coalesce(p_payload->>'guest_phone',''))>40
  or length(coalesce(p_payload->>'remark',''))>500 then raise exception 'invalid_pass';end if;
 if pid is null then
  insert into public.yt_ambassador_passes(ambassador_id,reservation_day,pass_type,planned_pax,guest_name,guest_phone,remark)
  values(a.id,d,ptype,pax,coalesce(p_payload->>'guest_name',''),coalesce(p_payload->>'guest_phone',''),coalesce(p_payload->>'remark',''))
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

create or replace function public.yt_ambassador_pos_pass_lookup(p_token text)
returns jsonb language sql security invoker set search_path='' as $$ select private.yt_ambassador_pos_pass_lookup(p_token) $$;
create or replace function public.yt_ambassador_pos_order_create(p_token text,p_male integer,p_female integer,p_request uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.yt_ambassador_pos_order_create(p_token,p_male,p_female,p_request) $$;
create or replace function public.yt_ambassador_work_portal()
returns jsonb language sql security invoker set search_path='' as $$ select private.yt_ambassador_work_portal() $$;
create or replace function public.yt_ambassador_work_pass_save(p_payload jsonb)
returns jsonb language sql security invoker set search_path='' as $$ select private.yt_ambassador_work_pass_save(p_payload) $$;
revoke all on function private.yt_ambassador_pos_pass_lookup(text),private.yt_ambassador_pos_order_create(text,integer,integer,uuid),
 private.yt_ambassador_work_portal(),private.yt_ambassador_work_pass_save(jsonb),private.yt_ambassador_pos_payment_method(),
 private.yt_ambassador_pos_capture() from public,anon,authenticated;
grant execute on function private.yt_ambassador_pos_pass_lookup(text),private.yt_ambassador_pos_order_create(text,integer,integer,uuid),
 private.yt_ambassador_work_portal(),private.yt_ambassador_work_pass_save(jsonb) to authenticated;
revoke all on function public.yt_ambassador_pos_pass_lookup(text),public.yt_ambassador_pos_order_create(text,integer,integer,uuid),
 public.yt_ambassador_work_portal(),public.yt_ambassador_work_pass_save(jsonb) from public,anon;
grant execute on function public.yt_ambassador_pos_pass_lookup(text),public.yt_ambassador_pos_order_create(text,integer,integer,uuid),
 public.yt_ambassador_work_portal(),public.yt_ambassador_work_pass_save(jsonb) to authenticated;
revoke all on function public.yt_ambassador_checkin(jsonb) from public,anon,authenticated;
revoke all on function private.yt_ambassador_checkin(jsonb) from public,anon,authenticated;

create or replace function private.yt_pos_day_preview(p_day date default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare d date:=coalesce(p_day,private.yt_business_day(now())); s jsonb; c jsonb; pending jsonb; items jsonb;
 blockers bigint; n bigint; methods jsonb; fingerprint text;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if d<'2020-01-01' or d>private.yt_business_day(now()) then raise exception 'invalid_business_day';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.method),'[]'::jsonb) into methods from (
  select method,sum(amount_rm) net_rm,sum(greatest(amount_rm,0)) received_rm,-sum(least(amount_rm,0)) refunded_rm,count(distinct order_id) orders
  from public.yt_pos_payment_entries where business_day=d group by method
 )x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.quantity desc,x.item_name),'[]'::jsonb) into items from (
  select i.product_id,i.item_name,sum(i.quantity)::bigint quantity,sum(i.quantity*i.unit_price_rm)::numeric gross_rm,
   coalesce(sum(u.discount_rm),0)::numeric discount_rm,(sum(i.quantity*i.unit_price_rm)-coalesce(sum(u.discount_rm),0))::numeric net_rm
  from public.yt_member_order_items i join public.yt_member_orders o on o.id=i.order_id and o.source='future_pos'
  join (select distinct order_id from public.yt_pos_payment_entries where business_day=d and kind='sale') sold on sold.order_id=o.id
  left join lateral(select coalesce(sum(unit.reward_discount_rm),0) discount_rm from public.yt_pos_item_units unit
   where unit.order_item_id=i.id and not unit.retired and unit.unit_number<=i.quantity)u on true
  where i.quantity>0 group by i.product_id,i.item_name
 )x;
 select jsonb_build_object('net_rm',coalesce(sum(amount_rm),0),'received_rm',coalesce(sum(greatest(amount_rm,0)),0),
  'refunded_rm',-coalesce(sum(least(amount_rm,0)),0),'cash_rm',coalesce(sum(amount_rm) filter(where method in ('cash','AB_Cash')),0),
  'orders',count(distinct order_id) filter(where kind='sale'),'payment_orders',count(distinct order_id),'entries',count(*),
  'last_entry',coalesce(max(id),0),'gross_rm',coalesce((select sum((x->>'gross_rm')::numeric) from jsonb_array_elements(items)x),0),
  'discount_rm',coalesce((select sum((x->>'discount_rm')::numeric) from jsonb_array_elements(items)x),0),
  'units',coalesce((select sum((x->>'quantity')::bigint) from jsonb_array_elements(items)x),0),
  'cancelled_orders',(select count(*) from public.yt_member_orders o where o.source='future_pos' and o.status='cancelled'
   and o.updated_at>=private.yt_business_start(d) and o.updated_at<private.yt_business_start(d+1))) into s
 from public.yt_pos_payment_entries where business_day=d;
 select count(*),count(*) filter(where coalesce(settlement_due_since,created_at)<=now()-interval '72 hours') into n,blockers
 from public.yt_member_orders where source='future_pos' and ((status in ('pending','confirmed','fulfilled') and payment_status='unpaid')
  or (payment_status='paid' and settlement_due_since is not null));
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]'::jsonb) into pending from (
  select id,order_no,table_label,status,payment_status,
   case when payment_status='paid' then abs(amount_rm-private.yt_pos_received(id)) else amount_rm end amount_rm,
   coalesce(settlement_due_since,created_at) created_at,coalesce(settlement_due_since,created_at)<=now()-interval '72 hours' overdue
  from public.yt_member_orders where source='future_pos'
  and ((status in ('pending','confirmed','fulfilled') and payment_status='unpaid') or (payment_status='paid' and settlement_due_since is not null))
  order by coalesce(settlement_due_since,created_at) limit 100
 )x;
 select to_jsonb(x) into c from public.yt_pos_day_closings x where business_day=d order by revision desc limit 1;
 fingerprint:=md5(s::text||methods::text||items::text||n::text||blockers::text||coalesce(c->>'id','')||coalesce(c->>'state',''));
 return jsonb_build_object('statement_version',2,'day',d,'context',private.yt_business_context(),
  'start_at',private.yt_business_start(d),'end_at',private.yt_business_start(d+1),'stats',s,'items',items,'methods',methods,
  'pending',pending,'pending_count',n,'blocker_count',blockers,'closing',c,'fingerprint',fingerprint);
end $$;
revoke all on function private.yt_pos_day_preview(date) from public,anon,authenticated;
grant execute on function private.yt_pos_day_preview(date) to authenticated;


-- Keep fresh installs aligned with migration 086.
-- Exempt only Ambassador Freeflow POS sales from drink/reward checkout rules.
-- They are paid through yt_pos_action like all other POS orders, with their own
-- AB_ method and check-in/commission capture triggers.
create or replace function private.yt_pos_checkout_minimum()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.source='future_pos' and old.payment_status='unpaid' and new.payment_status='paid'
  and not exists(select 1 from public.yt_ambassador_pos_sales where order_id=new.id)
  and not (private.yt_pos_order_minimum(new.id)->>'minimum_met')::boolean
 then raise exception 'minimum_one_paid_drink';end if;
 return new;
end $$;

create or replace function private.yt_pos_checkout_quote()
returns trigger language plpgsql security definer set search_path='' as $$
declare n_bad integer; v_discount numeric; v_moon numeric:=0; v_moon_bad integer:=0;
begin
 if old.payment_status='unpaid' and new.payment_status='paid' and old.source='future_pos' then
  if exists(select 1 from public.yt_ambassador_pos_sales where order_id=new.id) then return new;end if;
  select count(*) filter(where state<>'ready' or expires_at<=clock_timestamp()),
   coalesce(sum(case when state='ready' and expires_at>clock_timestamp() then discount_rm else 0 end),0)
   into n_bad,v_discount from public.yt_pos_reward_holds where order_id=new.id and state in('reserved','ready');
  if n_bad>0 then raise exception 'coupon_hold_not_ready_or_expired';end if;
  select coalesce(sum(case when kind='R0' then 5 else 0 end),0),
   count(*) filter(where valid_until<(clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date)
   into v_moon,v_moon_bad from public.yt_moon_guest_codes where reserved_order_id=new.id and status='reserved';
  if v_moon_bad>0 then raise exception 'moon_expired';end if;
  if v_discount+v_moon>old.amount_rm then raise exception 'discount_exceeds_bill';end if;
  if v_moon>0 and old.amount_rm<=v_discount+v_moon then raise exception 'moon_minimum_payable';end if;
  if not (private.yt_pos_order_minimum(new.id)->>'minimum_met')::boolean then raise exception 'minimum_one_paid_drink';end if;
  new.amount_rm:=old.amount_rm-v_discount-v_moon;
 end if;
 return new;
end $$;

create or replace function private.yt_pos_checkout_redeem()
returns trigger language plpgsql security definer set search_path='' as $$
declare h public.yt_pos_reward_holds%rowtype; w public.user_rewards%rowtype; v_red uuid;
 v_time timestamptz:=clock_timestamp();
begin
 if not (old.payment_status='unpaid' and new.payment_status='paid' and old.source='future_pos')
  or exists(select 1 from public.yt_ambassador_pos_sales where order_id=new.id) then return new;end if;
 for h in select * from public.yt_pos_reward_holds where order_id=new.id and state in('reserved','ready') order by id for update loop
  if h.state<>'ready' or h.expires_at<=clock_timestamp() then raise exception 'coupon_hold_not_ready_or_expired';end if;
  select * into w from public.user_rewards where id=h.user_reward_id for update;
  if not found or w.status<>'available' or w.expires_at<=clock_timestamp() then raise exception 'coupon_no_longer_available';end if;
  if exists(select 1 from public.redemptions where user_reward_id=w.id) then raise exception 'coupon_already_redeemed';end if;
  if not exists(select 1 from public.yt_pos_item_units u where u.order_item_id=h.order_item_id and u.unit_number=h.unit_number
   and u.reward_redemption_id is null and u.game_pass_id is null) then raise exception 'coupon_cart_item_missing';end if;
  insert into public.redemptions(user_reward_id,customer_id,staff_id,request_id,redeemed_at)
   values(w.id,w.customer_id,new.paid_by,h.id,v_time) returning id into v_red;
  update public.user_rewards set status='redeemed',redeemed_at=v_time where id=w.id;
  update public.redeem_tokens set consumed_at=v_time where user_reward_id=w.id and consumed_at is null;
  update public.yt_pos_item_units set reward_redemption_id=v_red,reward_discount_rm=h.discount_rm
   where order_item_id=h.order_item_id and unit_number=h.unit_number;
  update public.yt_pos_reward_holds set state='settled',redemption_id=v_red,settled_at=v_time,updated_at=v_time where id=h.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
   values(new.paid_by,'pos.coupon_checked_out','pos_order',new.id,
    jsonb_build_object('hold_id',h.id,'redemption_id',v_red,'item_id',h.order_item_id,'discount_rm',h.discount_rm));
 end loop;
 return new;
end $$;
