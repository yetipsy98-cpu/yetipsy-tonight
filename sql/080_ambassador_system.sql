
-- Yetipsy Ambassador: isolated commission/pass system with existing work/member auth.
create table public.yt_ambassadors (
 id uuid primary key default gen_random_uuid(),
 member_user_id uuid references auth.users(id) on delete set null,
 work_user_id uuid references auth.users(id) on delete set null,
 display_name text not null default '' check (char_length(display_name) <= 100),
 phone text not null default '' check (char_length(phone) <= 40),
 commission_rate numeric(5,2) not null default 0 check (commission_rate between 0 and 100),
 active boolean not null default true,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create unique index yt_ambassadors_member_unique on public.yt_ambassadors(member_user_id) where member_user_id is not null;
create unique index yt_ambassadors_work_unique on public.yt_ambassadors(work_user_id) where work_user_id is not null;

create table public.yt_ambassador_prices (
 id boolean primary key default true check (id),
 weekday_male numeric(10,2) not null default 0 check (weekday_male between 0 and 50000),
 weekday_female numeric(10,2) not null default 0 check (weekday_female between 0 and 50000),
 weekend_male numeric(10,2) not null default 0 check (weekend_male between 0 and 50000),
 weekend_female numeric(10,2) not null default 0 check (weekend_female between 0 and 50000),
 updated_by uuid references auth.users(id) on delete set null,
 updated_at timestamptz not null default now()
);
insert into public.yt_ambassador_prices(id) values(true) on conflict do nothing;

create table public.yt_ambassador_special_prices (
 business_day date primary key,
 male_price numeric(10,2) not null check (male_price between 0 and 50000),
 female_price numeric(10,2) not null check (female_price between 0 and 50000),
 updated_by uuid references auth.users(id) on delete set null,
 updated_at timestamptz not null default now()
);

create table public.yt_ambassador_passes (
 id uuid primary key default gen_random_uuid(),
 pass_code uuid not null unique default gen_random_uuid(),
 ambassador_id uuid not null references public.yt_ambassadors(id) on delete restrict,
 reservation_day date not null,
 pass_type text not null default 'group' check (pass_type in ('group','individual')),
 planned_pax integer not null check (planned_pax between 1 and 500),
 guest_name text not null default '' check (char_length(guest_name) <= 100),
 guest_phone text not null default '' check (char_length(guest_phone) <= 40),
 remark text not null default '' check (char_length(remark) <= 500),
 status text not null default 'issued' check (status in ('issued','void')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index yt_ambassador_passes_owner_day_idx on public.yt_ambassador_passes(ambassador_id,reservation_day desc);
create index yt_ambassador_passes_code_idx on public.yt_ambassador_passes(pass_code) where status='issued';

create table public.yt_ambassador_checkins (
 id uuid primary key default gen_random_uuid(),
 request_id uuid not null unique,
 pass_id uuid not null references public.yt_ambassador_passes(id) on delete restrict,
 ambassador_id uuid not null references public.yt_ambassadors(id) on delete restrict,
 checked_by uuid not null references auth.users(id) on delete restrict,
 business_day date not null,
 male_count integer not null check (male_count between 0 and 500),
 female_count integer not null check (female_count between 0 and 500),
 male_price numeric(10,2) not null check (male_price between 0 and 50000),
 female_price numeric(10,2) not null check (female_price between 0 and 50000),
 sales numeric(12,2) not null check (sales >= 0),
 commission_rate numeric(5,2) not null check (commission_rate between 0 and 100),
 commission_amount numeric(12,2) not null check (commission_amount >= 0),
 note text not null default '' check (char_length(note) <= 300),
 created_at timestamptz not null default now(),
 check (male_count + female_count > 0)
);
create index yt_ambassador_checkins_day_idx on public.yt_ambassador_checkins(business_day,created_at desc);
create index yt_ambassador_checkins_ambassador_idx on public.yt_ambassador_checkins(ambassador_id,created_at desc);

create table public.yt_ambassador_ledger (
 id uuid primary key default gen_random_uuid(),
 ambassador_id uuid not null references public.yt_ambassadors(id) on delete restrict,
 checkin_id uuid unique references public.yt_ambassador_checkins(id) on delete restrict,
 entry_type text not null check (entry_type in ('commission','payout')),
 amount numeric(12,2) not null check (amount <> 0),
 method text not null default '',
 note text not null default '' check (char_length(note) <= 300),
 created_by uuid not null references auth.users(id) on delete restrict,
 business_day date not null,
 created_at timestamptz not null default now(),
 check ((entry_type='commission' and checkin_id is not null and amount > 0) or
        (entry_type='payout' and checkin_id is null and amount < 0))
);
create index yt_ambassador_ledger_wallet_idx on public.yt_ambassador_ledger(ambassador_id,created_at desc);

alter table public.yt_ambassadors enable row level security;
alter table public.yt_ambassador_prices enable row level security;
alter table public.yt_ambassador_special_prices enable row level security;
alter table public.yt_ambassador_passes enable row level security;
alter table public.yt_ambassador_checkins enable row level security;
alter table public.yt_ambassador_ledger enable row level security;
revoke all on public.yt_ambassadors,public.yt_ambassador_prices,public.yt_ambassador_special_prices,
 public.yt_ambassador_passes,public.yt_ambassador_checkins,public.yt_ambassador_ledger from public,anon,authenticated;

create or replace function private.yt_ambassador_price(p_day date)
returns jsonb language sql stable security definer set search_path='' as $$
 select case when s.business_day is not null then jsonb_build_object('male',s.male_price,'female',s.female_price,'kind','special')
   when extract(dow from p_day)::integer in (5,6) then jsonb_build_object('male',p.weekend_male,'female',p.weekend_female,'kind','weekend')
   else jsonb_build_object('male',p.weekday_male,'female',p.weekday_female,'kind','weekday') end
 from public.yt_ambassador_prices p
 left join public.yt_ambassador_special_prices s on s.business_day=p_day
 where p.id=true
$$;

create or replace function private.yt_ambassador_assert_owner()
returns void language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.yt_has_role('owner') then raise exception 'owner_only'; end if;
end $$;

create or replace function private.yt_ambassador_assert_work()
returns void language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(
  select 1 from public.work_accounts wa join public.staff_roles sr on sr.user_id=wa.auth_user_id
  join public.yt_ambassadors a on a.work_user_id=wa.auth_user_id and a.active
  where wa.auth_user_id=auth.uid() and wa.active and not wa.must_change_password
   and wa.role in ('staff','cashier') and sr.active and sr.role=wa.role
 ) then raise exception 'ambassador_work_only'; end if;
end $$;

create or replace function private.yt_ambassador_portal()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.yt_ambassadors%rowtype; d date:=private.yt_business_day(now()); p jsonb; prices jsonb; wallet numeric;
begin
 if auth.uid() is null then raise exception 'not_authenticated'; end if;
 select * into a from public.yt_ambassadors where member_user_id=auth.uid() and active limit 1;
 if a.id is null then return jsonb_build_object('enabled',false); end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',x.id,'pass_code',x.pass_code,'reservation_day',x.reservation_day,'pass_type',x.pass_type,
   'planned_pax',x.planned_pax,'guest_name',x.guest_name,'guest_phone',x.guest_phone,'remark',x.remark,
   'status',x.status,'created_at',x.created_at,
   'checked_pax',coalesce(c.checked_pax,0),'sales',coalesce(c.sales,0),'commission',coalesce(c.commission,0)
 ) order by x.reservation_day desc,x.created_at desc),'[]'::jsonb)
 into p from public.yt_ambassador_passes x
 left join lateral (select sum(ci.male_count+ci.female_count)::integer checked_pax,
  sum(ci.sales)::numeric sales,sum(ci.commission_amount)::numeric commission
  from public.yt_ambassador_checkins ci where ci.pass_id=x.id) c on true
 where x.ambassador_id=a.id;
 select coalesce(sum(l.amount),0) into wallet from public.yt_ambassador_ledger l where l.ambassador_id=a.id;
 select jsonb_build_object('weekday_male',weekday_male,'weekday_female',weekday_female,
  'weekend_male',weekend_male,'weekend_female',weekend_female,
  'specials',coalesce((select jsonb_agg(jsonb_build_object('business_day',s.business_day,'male',s.male_price,'female',s.female_price) order by s.business_day desc) from public.yt_ambassador_special_prices s),'[]'::jsonb)
 ) into prices from public.yt_ambassador_prices where id=true;
 return jsonb_build_object('enabled',true,'ambassador',jsonb_build_object('id',a.id,'display_name',a.display_name,'commission_rate',a.commission_rate),
  'business_day',d,'cutoff_minutes',(select cutoff_minutes from public.yt_business_cutoffs where effective_day<=d order by effective_day desc limit 1),
  'prices',prices,'rates_for_today',private.yt_ambassador_price(d),'wallet_balance',wallet,'passes',p);
end $$;

create or replace function private.yt_ambassador_pass_save(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.yt_ambassadors%rowtype; v public.yt_ambassador_passes%rowtype; pid uuid; d date; cnt integer;
begin
 if auth.uid() is null then raise exception 'not_authenticated'; end if;
 select * into a from public.yt_ambassadors where member_user_id=auth.uid() and active limit 1;
 if a.id is null then raise exception 'ambassador_member_only'; end if;
 begin pid:=nullif(p_payload->>'id','')::uuid; exception when others then raise exception 'invalid_pass'; end;
 begin d:=nullif(p_payload->>'reservation_day','')::date; exception when others then raise exception 'invalid_reservation_day'; end;
 if d is null or d<private.yt_business_day(now()) or d>private.yt_business_day(now())+180 then raise exception 'invalid_reservation_day'; end if;
 if coalesce((p_payload->>'planned_pax')::integer,0) not between 1 and 500 then raise exception 'invalid_planned_pax'; end if;
 if coalesce(p_payload->>'pass_type','group') not in ('group','individual') then raise exception 'invalid_pass_type'; end if;
 if length(coalesce(p_payload->>'guest_name',''))>100 or length(coalesce(p_payload->>'guest_phone',''))>40 or length(coalesce(p_payload->>'remark',''))>500 then raise exception 'invalid_pass'; end if;
 if pid is null then
  insert into public.yt_ambassador_passes(ambassador_id,reservation_day,pass_type,planned_pax,guest_name,guest_phone,remark)
  values(a.id,d,coalesce(p_payload->>'pass_type','group'),(p_payload->>'planned_pax')::integer,
   coalesce(p_payload->>'guest_name',''),coalesce(p_payload->>'guest_phone',''),coalesce(p_payload->>'remark',''))
  returning * into v;
 else
  select * into v from public.yt_ambassador_passes where id=pid and ambassador_id=a.id and status='issued' for update;
  if v.id is null then raise exception 'pass_not_editable'; end if;
  select count(*) into cnt from public.yt_ambassador_checkins where pass_id=v.id;
  if cnt>0 then raise exception 'pass_already_checked_in'; end if;
  update public.yt_ambassador_passes set reservation_day=d,pass_type=coalesce(p_payload->>'pass_type','group'),
   planned_pax=(p_payload->>'planned_pax')::integer,guest_name=coalesce(p_payload->>'guest_name',''),
   guest_phone=coalesce(p_payload->>'guest_phone',''),remark=coalesce(p_payload->>'remark',''),updated_at=now()
   where id=v.id returning * into v;
 end if;
 return jsonb_build_object('id',v.id,'pass_code',v.pass_code,'reservation_day',v.reservation_day,
  'planned_pax',v.planned_pax,'pass_type',v.pass_type,'guest_name',v.guest_name);
end $$;

create or replace function private.yt_ambassador_work_access()
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(
  select 1 from public.work_accounts wa join public.staff_roles sr on sr.user_id=wa.auth_user_id
   join public.yt_ambassadors a on a.work_user_id=wa.auth_user_id and a.active
  where wa.auth_user_id=auth.uid() and wa.active and not wa.must_change_password
   and wa.role in ('staff','cashier') and sr.active and sr.role=wa.role
 )
$$;

create or replace function private.yt_ambassador_pass_lookup(p_token text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.yt_ambassadors%rowtype; v public.yt_ambassador_passes%rowtype; d date:=private.yt_business_day(now()); pp jsonb;
begin
 perform private.yt_ambassador_assert_work();
 select * into v from public.yt_ambassador_passes where pass_code=(regexp_replace(trim(p_token),'^(YTAMB:|ambassador:|https?://[^ ]*[?&]amb=)','', 'i'))::uuid and status='issued';
 if v.id is null then raise exception 'ambassador_pass_not_found'; end if;
 select * into a from public.yt_ambassadors where id=v.ambassador_id and active;
 if a.id is null then raise exception 'ambassador_inactive'; end if;
 if a.member_user_id=auth.uid() or a.work_user_id=auth.uid() then raise exception 'cannot_redeem_own_pass'; end if;
 if d<>v.reservation_day or now()<private.yt_business_start(v.reservation_day) or now()>=private.yt_business_start(v.reservation_day+1) then raise exception 'ambassador_pass_not_valid_today'; end if;
 pp:=private.yt_ambassador_price(v.reservation_day);
 if coalesce((pp->>'male')::numeric,0)<=0 or coalesce((pp->>'female')::numeric,0)<=0 then raise exception 'ambassador_prices_not_configured'; end if;
 return jsonb_build_object('pass_id',v.id,'pass_code',v.pass_code,'reservation_day',v.reservation_day,'pass_type',v.pass_type,
  'planned_pax',v.planned_pax,'guest_name',v.guest_name,'guest_phone',v.guest_phone,'remark',v.remark,
  'ambassador_name',coalesce(nullif(a.display_name,''),'Ambassador'),'commission_rate',a.commission_rate,
  'male_price',(pp->>'male')::numeric,'female_price',(pp->>'female')::numeric,
  'checked_pax',(select coalesce(sum(c.male_count+c.female_count),0) from public.yt_ambassador_checkins c where c.pass_id=v.id),
  'sales',(select coalesce(sum(c.sales),0) from public.yt_ambassador_checkins c where c.pass_id=v.id),
  'commission',(select coalesce(sum(c.commission_amount),0) from public.yt_ambassador_checkins c where c.pass_id=v.id));
exception when invalid_text_representation then raise exception 'ambassador_pass_not_found';
end $$;

create or replace function private.yt_ambassador_checkin(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_ambassador_passes%rowtype; a public.yt_ambassadors%rowtype; ci public.yt_ambassador_checkins%rowtype;
 d date:=private.yt_business_day(now()); req uuid; m integer; f integer; p jsonb; mp numeric; fp numeric; s numeric; comm numeric; done integer;
begin
 perform private.yt_ambassador_assert_work();
 begin req:=nullif(p_payload->>'request_id','')::uuid; exception when others then raise exception 'invalid_request_id'; end;
 begin v.id:=nullif(p_payload->>'pass_id','')::uuid; exception when others then raise exception 'invalid_pass'; end;
 begin m:=coalesce((p_payload->>'male_count')::integer,0); f:=coalesce((p_payload->>'female_count')::integer,0); exception when others then raise exception 'invalid_guest_count'; end;
 if req is null or v.id is null or m<0 or f<0 or m+f<1 or m+f>500 then raise exception 'invalid_guest_count'; end if;
 select * into ci from public.yt_ambassador_checkins where request_id=req;
 if ci.id is not null then return jsonb_build_object('id',ci.id,'sales',ci.sales,'commission',ci.commission_amount,'duplicate',true); end if;
 select * into v from public.yt_ambassador_passes where id=v.id and status='issued' for update;
 if v.id is null then raise exception 'ambassador_pass_not_found'; end if;
 select * into a from public.yt_ambassadors where id=v.ambassador_id and active;
 if a.id is null then raise exception 'ambassador_inactive'; end if;
 if a.member_user_id=auth.uid() or a.work_user_id=auth.uid() then raise exception 'cannot_redeem_own_pass'; end if;
 if d<>v.reservation_day or now()<private.yt_business_start(v.reservation_day) or now()>=private.yt_business_start(v.reservation_day+1) then raise exception 'ambassador_pass_not_valid_today'; end if;
 p:=private.yt_ambassador_price(v.reservation_day); mp:=(p->>'male')::numeric; fp:=(p->>'female')::numeric;
 if mp<=0 or fp<=0 then raise exception 'ambassador_prices_not_configured'; end if;
 s:=round(m*mp+f*fp,2); comm:=round(s*a.commission_rate/100,2);
 insert into public.yt_ambassador_checkins(request_id,pass_id,ambassador_id,checked_by,business_day,male_count,female_count,male_price,female_price,sales,commission_rate,commission_amount,note)
 values(req,v.id,a.id,auth.uid(),d,m,f,mp,fp,s,a.commission_rate,comm,left(coalesce(p_payload->>'note',''),300))
 on conflict(request_id) do nothing returning * into ci;
 if ci.id is null then select * into ci from public.yt_ambassador_checkins where request_id=req; return jsonb_build_object('id',ci.id,'sales',ci.sales,'commission',ci.commission_amount,'duplicate',true); end if;
 insert into public.yt_ambassador_ledger(ambassador_id,checkin_id,entry_type,amount,created_by,business_day,note)
 values(a.id,ci.id,'commission',comm,auth.uid(),d,'Pass 核销佣金');
 select coalesce(sum(male_count+female_count),0) into done from public.yt_ambassador_checkins where pass_id=v.id;
 return jsonb_build_object('id',ci.id,'sales',s,'commission',comm,'commission_rate',a.commission_rate,
  'checked_pax',done,'planned_pax',v.planned_pax,'over_planned',done>v.planned_pax,'duplicate',false);
end $$;

create or replace function private.yt_ambassador_owner_data()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare d date:=private.yt_business_day(now()); a jsonb; people jsonb; price jsonb; checks jsonb; payouts jsonb;
begin
 perform private.yt_ambassador_assert_owner();
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'member_user_id',x.member_user_id,'work_user_id',x.work_user_id,
  'display_name',x.display_name,'phone',x.phone,'commission_rate',x.commission_rate,'active',x.active,
  'wallet_balance',coalesce(w.balance,0),'sales_total',coalesce(w.sales,0),'commission_total',coalesce(w.earned,0),
  'paid_total',coalesce(w.paid,0),'checkin_count',coalesce(w.checkins,0))
  order by x.active desc,x.display_name),'[]'::jsonb)
 into a from public.yt_ambassadors x
 left join lateral (select sum(l.amount) balance,sum(case when l.entry_type='commission' then l.amount else 0 end) earned,
  sum(case when l.entry_type='payout' then -l.amount else 0 end) paid,
  (select sum(c.sales) from public.yt_ambassador_checkins c where c.ambassador_id=x.id) sales,
  (select count(*) from public.yt_ambassador_checkins c where c.ambassador_id=x.id) checkins
  from public.yt_ambassador_ledger l where l.ambassador_id=x.id) w on true;
 select coalesce(jsonb_agg(jsonb_build_object('user_id',p.id,'display_name',coalesce(p.display_name,''),'phone',coalesce(p.phone,'')) order by p.display_name),'[]'::jsonb)
 into people from public.profiles p;
 select jsonb_build_object('weekday_male',weekday_male,'weekday_female',weekday_female,
  'weekend_male',weekend_male,'weekend_female',weekend_female,
  'specials',coalesce((select jsonb_agg(jsonb_build_object('business_day',s.business_day,'male',s.male_price,'female',s.female_price) order by s.business_day desc) from public.yt_ambassador_special_prices s),'[]'::jsonb)
 ) into price from public.yt_ambassador_prices where id=true;
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'ambassador_name',coalesce(nullif(a.display_name,''),'Ambassador'),
  'reservation_day',v.reservation_day,'checked_by',coalesce(p.display_name,wa.username,''),'male_count',c.male_count,
  'female_count',c.female_count,'sales',c.sales,'commission',c.commission_amount,'business_day',c.business_day,'created_at',c.created_at)
  order by c.created_at desc),'[]'::jsonb)
 into checks from (select * from public.yt_ambassador_checkins order by created_at desc limit 100) c
 join public.yt_ambassadors a on a.id=c.ambassador_id join public.yt_ambassador_passes v on v.id=c.pass_id
 left join public.profiles p on p.id=c.checked_by left join public.work_accounts wa on wa.auth_user_id=c.checked_by;
 select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'ambassador_name',coalesce(nullif(a.display_name,''),'Ambassador'),
  'amount',-l.amount,'method',l.method,'note',l.note,'business_day',l.business_day,'created_at',l.created_at)
  order by l.created_at desc),'[]'::jsonb)
 into payouts from (select * from public.yt_ambassador_ledger where entry_type='payout' order by created_at desc limit 100) l
 join public.yt_ambassadors a on a.id=l.ambassador_id;
 return jsonb_build_object('business_day',d,'ambassadors',a,'members',people,'work_users',
  (select coalesce(jsonb_agg(jsonb_build_object('user_id',wa.auth_user_id,'username',wa.username,'role',wa.role,
   'display_name',coalesce(nullif(p.display_name,''),wa.username),'phone',coalesce(p.phone,'')) order by wa.username),'[]'::jsonb)
   from public.work_accounts wa join public.staff_roles sr on sr.user_id=wa.auth_user_id and sr.active and sr.role=wa.role
   left join public.profiles p on p.id=wa.auth_user_id where wa.active and not wa.must_change_password and wa.role in ('staff','cashier')),
  'prices',price,'checkins',checks,'payouts',payouts);
end $$;

create or replace function private.yt_ambassador_owner_save(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare aid uuid; mem uuid; workid uuid; rate numeric; name text; phone text; active_flag boolean; result public.yt_ambassadors%rowtype;
begin
 perform private.yt_ambassador_assert_owner();
 begin aid:=nullif(p_payload->>'id','')::uuid; mem:=nullif(p_payload->>'member_user_id','')::uuid; workid:=nullif(p_payload->>'work_user_id','')::uuid;
  rate:=coalesce((p_payload->>'commission_rate')::numeric,0); exception when others then raise exception 'invalid_ambassador'; end;
 name:=left(trim(coalesce(p_payload->>'display_name','')),100); phone:=left(trim(coalesce(p_payload->>'phone','')),40); active_flag:=coalesce((p_payload->>'active')::boolean,true);
 if mem is null and workid is null then raise exception 'ambassador_identity_required'; end if;
 if mem is not null and not exists(select 1 from public.profiles where id=mem) then raise exception 'ambassador_member_not_found'; end if;
 if workid is not null and not exists(select 1 from public.work_accounts wa join public.staff_roles sr on sr.user_id=wa.auth_user_id and sr.active and sr.role=wa.role
  where wa.auth_user_id=workid and wa.active and not wa.must_change_password and wa.role in ('staff','cashier')) then raise exception 'ambassador_work_user_not_found'; end if;
 if rate<0 or rate>100 then raise exception 'invalid_commission_rate'; end if;
 if aid is null then
  insert into public.yt_ambassadors(member_user_id,work_user_id,display_name,phone,commission_rate,active,created_by)
   values(mem,workid,name,phone,rate,active_flag,auth.uid()) returning * into result;
 else
  update public.yt_ambassadors set member_user_id=mem,work_user_id=workid,display_name=name,phone=phone,
   commission_rate=rate,active=active_flag,updated_at=now() where id=aid returning * into result;
  if result.id is null then raise exception 'ambassador_not_found'; end if;
 end if;
 return jsonb_build_object('id',result.id);
end $$;

create or replace function private.yt_ambassador_price_save(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d date; mp numeric; fp numeric; sp public.yt_ambassador_prices%rowtype;
begin
 perform private.yt_ambassador_assert_owner();
 if p_payload ? 'special_day' then
  begin d:=(p_payload->>'special_day')::date; mp:=(p_payload->>'male')::numeric; fp:=(p_payload->>'female')::numeric;
  exception when others then raise exception 'invalid_ambassador_prices'; end;
  if d<private.yt_business_day(now()) or mp<0 or fp<0 or mp>50000 or fp>50000 then raise exception 'invalid_ambassador_prices'; end if;
  if coalesce((p_payload->>'remove')::boolean,false) then delete from public.yt_ambassador_special_prices where business_day=d;
  else insert into public.yt_ambassador_special_prices(business_day,male_price,female_price,updated_by)
   values(d,mp,fp,auth.uid()) on conflict(business_day) do update set male_price=excluded.male_price,female_price=excluded.female_price,updated_by=auth.uid(),updated_at=now(); end if;
 else
  begin
   update public.yt_ambassador_prices set weekday_male=(p_payload->>'weekday_male')::numeric,
   weekday_female=(p_payload->>'weekday_female')::numeric,weekend_male=(p_payload->>'weekend_male')::numeric,
   weekend_female=(p_payload->>'weekend_female')::numeric,updated_by=auth.uid(),updated_at=now()
   where id=true returning * into sp;
  exception when others then raise exception 'invalid_ambassador_prices'; end;
  if sp.id is null then raise exception 'ambassador_prices_not_configured'; end if;
 end if;
 return jsonb_build_object('ok',true);
end $$;

create or replace function private.yt_ambassador_payout(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare aid uuid; amt numeric; method text; note text; bal numeric; id uuid; d date:=private.yt_business_day(now());
begin
 perform private.yt_ambassador_assert_owner();
 begin aid:=(p_payload->>'ambassador_id')::uuid; amt:=(p_payload->>'amount')::numeric; exception when others then raise exception 'invalid_payout'; end;
 method:=left(trim(coalesce(p_payload->>'method','')),40); note:=left(trim(coalesce(p_payload->>'note','')),300);
 if amt<=0 or amt>1000000 or method='' then raise exception 'invalid_payout'; end if;
 perform 1 from public.yt_ambassadors where id=aid and active for update;
 if not found then raise exception 'ambassador_not_found'; end if;
 select coalesce(sum(amount),0) into bal from public.yt_ambassador_ledger where ambassador_id=aid;
 if amt>bal then raise exception 'payout_exceeds_balance'; end if;
 insert into public.yt_ambassador_ledger(ambassador_id,entry_type,amount,method,note,created_by,business_day)
 values(aid,'payout',-amt,method,note,auth.uid(),d) returning public.yt_ambassador_ledger.id into id;
 return jsonb_build_object('id',id,'balance',bal-amt);
end $$;

-- Keep public API as invoker wrappers; authorization and privileged access stay in private.
grant usage on schema private to authenticated;
revoke all on function private.yt_ambassador_portal() from public,anon;
revoke all on function private.yt_ambassador_pass_save(jsonb) from public,anon;
revoke all on function private.yt_ambassador_work_access() from public,anon;
revoke all on function private.yt_ambassador_pass_lookup(text) from public,anon;
revoke all on function private.yt_ambassador_checkin(jsonb) from public,anon;
revoke all on function private.yt_ambassador_owner_data() from public,anon;
revoke all on function private.yt_ambassador_owner_save(jsonb) from public,anon;
revoke all on function private.yt_ambassador_price_save(jsonb) from public,anon;
revoke all on function private.yt_ambassador_payout(jsonb) from public,anon;
grant execute on function private.yt_ambassador_portal() to authenticated;
grant execute on function private.yt_ambassador_pass_save(jsonb) to authenticated;
grant execute on function private.yt_ambassador_work_access() to authenticated;
grant execute on function private.yt_ambassador_pass_lookup(text) to authenticated;
grant execute on function private.yt_ambassador_checkin(jsonb) to authenticated;
grant execute on function private.yt_ambassador_owner_data() to authenticated;
grant execute on function private.yt_ambassador_owner_save(jsonb) to authenticated;
grant execute on function private.yt_ambassador_price_save(jsonb) to authenticated;
grant execute on function private.yt_ambassador_payout(jsonb) to authenticated;

create or replace function public.yt_ambassador_portal() returns jsonb language sql set search_path='' as $$ select private.yt_ambassador_portal() $$;
create or replace function public.yt_ambassador_pass_save(p_payload jsonb) returns jsonb language sql set search_path='' as $$ select private.yt_ambassador_pass_save(p_payload) $$;
create or replace function public.yt_ambassador_work_access() returns boolean language sql set search_path='' as $$ select private.yt_ambassador_work_access() $$;
create or replace function public.yt_ambassador_pass_lookup(p_token text) returns jsonb language sql set search_path='' as $$ select private.yt_ambassador_pass_lookup(p_token) $$;
create or replace function public.yt_ambassador_checkin(p_payload jsonb) returns jsonb language sql set search_path='' as $$ select private.yt_ambassador_checkin(p_payload) $$;
create or replace function public.yt_ambassador_owner_data() returns jsonb language sql set search_path='' as $$ select private.yt_ambassador_owner_data() $$;
create or replace function public.yt_ambassador_owner_save(p_payload jsonb) returns jsonb language sql set search_path='' as $$ select private.yt_ambassador_owner_save(p_payload) $$;
create or replace function public.yt_ambassador_price_save(p_payload jsonb) returns jsonb language sql set search_path='' as $$ select private.yt_ambassador_price_save(p_payload) $$;
create or replace function public.yt_ambassador_payout(p_payload jsonb) returns jsonb language sql set search_path='' as $$ select private.yt_ambassador_payout(p_payload) $$;

revoke all on function public.yt_ambassador_portal() from public,anon;
revoke all on function public.yt_ambassador_pass_save(jsonb) from public,anon;
revoke all on function public.yt_ambassador_work_access() from public,anon;
revoke all on function public.yt_ambassador_pass_lookup(text) from public,anon;
revoke all on function public.yt_ambassador_checkin(jsonb) from public,anon;
revoke all on function public.yt_ambassador_owner_data() from public,anon;
revoke all on function public.yt_ambassador_owner_save(jsonb) from public,anon;
revoke all on function public.yt_ambassador_price_save(jsonb) from public,anon;
revoke all on function public.yt_ambassador_payout(jsonb) from public,anon;
grant execute on function public.yt_ambassador_portal() to authenticated;
grant execute on function public.yt_ambassador_pass_save(jsonb) to authenticated;
grant execute on function public.yt_ambassador_work_access() to authenticated;
grant execute on function public.yt_ambassador_pass_lookup(text) to authenticated;
grant execute on function public.yt_ambassador_checkin(jsonb) to authenticated;
grant execute on function public.yt_ambassador_owner_data() to authenticated;
grant execute on function public.yt_ambassador_owner_save(jsonb) to authenticated;
grant execute on function public.yt_ambassador_price_save(jsonb) to authenticated;
grant execute on function public.yt_ambassador_payout(jsonb) to authenticated;
