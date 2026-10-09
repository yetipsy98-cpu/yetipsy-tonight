-- One shift per business day. All monetary entries and closes serialize on one lock.
create table public.yt_business_cutoffs(
 effective_day date primary key, cutoff_minutes integer not null check(cutoff_minutes between 0 and 1439),
 changed_by uuid references auth.users(id) on delete set null, changed_at timestamptz not null default now()
);
insert into public.yt_business_cutoffs(effective_day,cutoff_minutes) values('1900-01-01',360);
alter table public.yt_business_cutoffs enable row level security;
revoke all on public.yt_business_cutoffs from public,anon,authenticated;

create function private.yt_business_start(p_day date) returns timestamptz language sql stable set search_path='' as $$
 select (p_day::timestamp+make_interval(mins=>c.cutoff_minutes)) at time zone 'Asia/Kuala_Lumpur'
 from public.yt_business_cutoffs c where effective_day<=p_day order by effective_day desc limit 1
$$;
create function private.yt_business_day(p_time timestamptz) returns date language sql stable set search_path='' as $$
 select case when p_time>=private.yt_business_start((p_time at time zone 'Asia/Kuala_Lumpur')::date)
 then (p_time at time zone 'Asia/Kuala_Lumpur')::date else (p_time at time zone 'Asia/Kuala_Lumpur')::date-1 end
$$;
create function private.yt_work_owner() returns boolean language sql stable security definer set search_path='' as $$
 select private.yt_pos_work_staff() and exists(select 1 from public.work_accounts where auth_user_id=auth.uid() and role='owner')
$$;
create function private.yt_business_context() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare d date:=private.yt_business_day(now());m integer;next_config jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select cutoff_minutes into m from public.yt_business_cutoffs where effective_day<=d order by effective_day desc limit 1;
 select jsonb_build_object('effective_day',effective_day,'cutoff_minutes',cutoff_minutes) into next_config
 from public.yt_business_cutoffs where effective_day>d order by effective_day limit 1;
 return jsonb_build_object('day',d,'start_at',private.yt_business_start(d),'end_at',private.yt_business_start(d+1),'cutoff_minutes',m,'next',next_config,'server_time',now());
end $$;
create function private.yt_business_cutoff_save(p_minutes integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare d date;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_minutes is null or p_minutes not between 0 and 1439 then raise exception 'invalid_cutoff';end if;
 perform pg_advisory_xact_lock(781943080);d:=private.yt_business_day(clock_timestamp())+1;
 insert into public.yt_business_cutoffs(effective_day,cutoff_minutes,changed_by) values(d,p_minutes,auth.uid())
 on conflict(effective_day) do update set cutoff_minutes=excluded.cutoff_minutes,changed_by=excluded.changed_by,changed_at=clock_timestamp();
 insert into public.audit_logs(actor_id,action,entity_type,metadata) values(auth.uid(),'pos.cutoff_save','business_day',jsonb_build_object('effective_day',d,'cutoff_minutes',p_minutes));
 return private.yt_business_context();
end $$;

create table public.yt_pos_payment_entries(
 id bigint generated always as identity primary key, order_id uuid not null references public.yt_member_orders(id) on delete cascade,
 request_id uuid not null unique, method text not null check(method in ('foodcourt','cash','duitnow','card','bank_transfer','other')),
 amount_rm numeric(12,2) not null check(amount_rm<>0), kind text not null check(kind in ('sale','adjustment','refund')),
 received_at timestamptz not null default now(), business_day date not null, actor_id uuid references auth.users(id) on delete set null,
 note text, created_at timestamptz not null default now()
);
create index yt_pos_payment_day_method_idx on public.yt_pos_payment_entries(business_day,method);
create index yt_pos_payment_order_idx on public.yt_pos_payment_entries(order_id);
alter table public.yt_pos_payment_entries enable row level security;
revoke all on public.yt_pos_payment_entries from public,anon,authenticated;
insert into public.yt_pos_payment_entries(order_id,request_id,method,amount_rm,kind,received_at,business_day,actor_id)
 select id,gen_random_uuid(),coalesce(payment_method,'other'),amount_rm,'sale',paid_at,private.yt_business_day(paid_at),paid_by
 from public.yt_member_orders where source='future_pos' and payment_status='paid' and amount_rm>0;

create table public.yt_pos_day_closings(
 id uuid primary key default gen_random_uuid(),business_day date not null,revision integer not null,
 state text not null check(state in ('closed','reopened')),request_id uuid not null unique,
 opening_cash numeric(12,2) not null check(opening_cash>=0),cash_out numeric(12,2) not null check(cash_out>=0),
 expected_cash numeric(12,2) not null,actual_cash numeric(12,2) not null check(actual_cash>=0),difference_rm numeric(12,2) not null,
 snapshot jsonb not null,notes text,closed_at timestamptz not null default now(),closed_by uuid references auth.users(id) on delete set null,
 reopened_at timestamptz,reopened_by uuid references auth.users(id) on delete set null,reopen_reason text,
 unique(business_day,revision)
);
create index yt_pos_day_close_day_idx on public.yt_pos_day_closings(business_day,revision desc);
alter table public.yt_pos_day_closings enable row level security;
revoke all on public.yt_pos_day_closings from public,anon,authenticated;

-- Cashier cannot bypass Owner approval for aged order completion/cancellation.
create function private.yt_pos_day_order_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(781943080);
 if TG_OP='UPDATE' and old.source='future_pos' and old.payment_status='unpaid'
 and old.status in ('pending','confirmed','fulfilled') and old.created_at<=clock_timestamp()-interval '72 hours'
 and (new.status is distinct from old.status or new.payment_status is distinct from old.payment_status)
 and not private.yt_work_owner() and coalesce(auth.jwt()->>'role','')<>'service_role'
 then raise exception 'aged_order_owner_required';end if;
 return new;
end $$;
create trigger yt_pos_00_day_guard before insert or update on public.yt_member_orders for each row execute function private.yt_pos_day_order_guard();

create function private.yt_pos_payment_capture() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.source='future_pos' and new.payment_status='paid' and old.payment_status<>'paid' and new.amount_rm>0 then
  insert into public.yt_pos_payment_entries(order_id,request_id,method,amount_rm,kind,received_at,business_day,actor_id)
  values(new.id,gen_random_uuid(),new.payment_method,new.amount_rm,'sale',new.paid_at,private.yt_business_day(new.paid_at),new.paid_by);
 end if;return new;
end $$;
create trigger yt_pos_z_payment_capture after update of payment_status on public.yt_member_orders for each row execute function private.yt_pos_payment_capture();
create function private.yt_pos_payment_reopen() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(781943080);
 update public.yt_pos_day_closings set state='reopened',reopened_at=clock_timestamp(),reopened_by=auth.uid(),reopen_reason='新增收款／退款，需重新日结'
 where business_day=new.business_day and state='closed';return new;
end $$;
create trigger yt_pos_payment_reopen after insert on public.yt_pos_payment_entries for each row execute function private.yt_pos_payment_reopen();

create function private.yt_pos_day_preview(p_day date default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare d date:=coalesce(p_day,private.yt_business_day(now()));s jsonb;c jsonb;pending jsonb;blockers bigint;n bigint;methods jsonb;fingerprint text;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if d<'2020-01-01' or d>private.yt_business_day(now()) then raise exception 'invalid_business_day';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.method),'[]') into methods from (
 select method,sum(amount_rm) net_rm,sum(greatest(amount_rm,0)) received_rm,-sum(least(amount_rm,0)) refunded_rm,count(distinct order_id) orders
 from public.yt_pos_payment_entries where business_day=d group by method)x;
 select jsonb_build_object('net_rm',coalesce(sum(amount_rm),0),'received_rm',coalesce(sum(greatest(amount_rm,0)),0),
 'refunded_rm',-coalesce(sum(least(amount_rm,0)),0),'cash_rm',coalesce(sum(amount_rm) filter(where method='cash'),0),
 'orders',count(distinct order_id),'entries',count(*),'last_entry',coalesce(max(id),0)) into s from public.yt_pos_payment_entries where business_day=d;
 select count(*),count(*) filter(where created_at<=now()-interval '72 hours') into n,blockers
 from public.yt_member_orders where source='future_pos' and status in ('pending','confirmed','fulfilled') and payment_status='unpaid';
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]') into pending from (
 select id,order_no,table_label,status,amount_rm,created_at,created_at<=now()-interval '72 hours' as overdue
 from public.yt_member_orders where source='future_pos' and status in ('pending','confirmed','fulfilled') and payment_status='unpaid'
 order by created_at limit 100)x;
 select to_jsonb(x) into c from public.yt_pos_day_closings x where business_day=d order by revision desc limit 1;
 fingerprint:=md5(s::text||methods::text||n::text||blockers::text||coalesce(c->>'id','')||coalesce(c->>'state',''));
 return jsonb_build_object('day',d,'context',private.yt_business_context(),'start_at',private.yt_business_start(d),'end_at',private.yt_business_start(d+1),
 'stats',s,'methods',methods,'pending',pending,'pending_count',n,'blocker_count',blockers,'closing',c,'fingerprint',fingerprint);
end $$;
create function private.yt_pos_day_close(p_day date,p_opening numeric,p_cash_out numeric,p_actual numeric,p_notes text,p_request uuid,p_fingerprint text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;v public.yt_pos_day_closings%rowtype;e numeric;rev integer;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if p_request is null or p_day is null or p_opening is null or p_actual is null or p_cash_out is null
 or p_opening::text in ('NaN','Infinity','-Infinity') or p_actual::text in ('NaN','Infinity','-Infinity') or p_cash_out::text in ('NaN','Infinity','-Infinity')
 or p_opening not between 0 and 1000000 or p_actual not between 0 and 1000000 or p_cash_out not between 0 and 1000000
 or p_opening<>round(p_opening,2) or p_actual<>round(p_actual,2) or p_cash_out<>round(p_cash_out,2) or length(coalesce(p_notes,''))>600
 then raise exception 'invalid_day_close';end if;
 perform pg_advisory_xact_lock(781943080);
 select * into v from public.yt_pos_day_closings where request_id=p_request;
 if found then
  if v.business_day<>p_day or v.opening_cash<>p_opening or v.actual_cash<>p_actual or v.cash_out<>p_cash_out or coalesce(v.notes,'')<>coalesce(p_notes,'') then raise exception 'request_conflict';end if;
  return to_jsonb(v);
 end if;
 r:=private.yt_pos_day_preview(p_day);
 if (r->>'blocker_count')::bigint>0 then raise exception 'aged_orders_block_day_close';end if;
 if r#>>'{closing,state}'='closed' then raise exception 'business_day_already_closed';end if;
 if p_fingerprint is null or p_fingerprint<>r->>'fingerprint' then raise exception 'day_close_changed_reload';end if;
 e:=p_opening+(r#>>'{stats,cash_rm}')::numeric-p_cash_out;
 if e<0 then raise exception 'cash_out_exceeds_expected';end if;
 if (p_actual<>e or (r->>'pending_count')::bigint>0 or p_cash_out>0) and length(btrim(coalesce(p_notes,'')))<2 then raise exception 'day_close_note_required';end if;
 select coalesce(max(revision),0)+1 into rev from public.yt_pos_day_closings where business_day=p_day;
 insert into public.yt_pos_day_closings(business_day,revision,state,request_id,opening_cash,cash_out,expected_cash,actual_cash,difference_rm,snapshot,notes,closed_by)
 values(p_day,rev,'closed',p_request,p_opening,p_cash_out,e,p_actual,p_actual-e,r,p_notes,auth.uid()) returning * into v;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.day_close','day_close',v.id,jsonb_build_object('day',p_day,'revision',rev,'difference_rm',p_actual-e,'pending',r->>'pending_count'));
 return to_jsonb(v);
end $$;
create function private.yt_pos_day_reopen(p_day date,p_reason text) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_pos_day_closings%rowtype;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if length(btrim(coalesce(p_reason,''))) not between 2 and 300 then raise exception 'reason_required';end if;
 perform pg_advisory_xact_lock(781943080);
 select * into v from public.yt_pos_day_closings where business_day=p_day order by revision desc limit 1 for update;
 if not found or v.state<>'closed' then raise exception 'business_day_not_closed';end if;
 update public.yt_pos_day_closings set state='reopened',reopened_at=clock_timestamp(),reopened_by=auth.uid(),reopen_reason=p_reason where id=v.id returning * into v;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.day_reopen','day_close',v.id,jsonb_build_object('reason',p_reason));return to_jsonb(v);
end $$;

create function private.yt_pos_aged_resolve(p_order uuid,p_action text,p_reason text,p_method text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_member_orders%rowtype;r jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if length(btrim(coalesce(p_reason,''))) not between 2 and 300 or p_action is null or p_action not in ('complete','cancel') then raise exception 'reason_required';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found or v.payment_status<>'unpaid' or v.status not in ('pending','confirmed','fulfilled') then raise exception 'order_not_unpaid';end if;
 if p_action='complete' then
  if v.status='pending' then perform private.yt_pos_action(p_order,'accept',p_reason);end if;
  if v.status<>'fulfilled' then perform private.yt_pos_action(p_order,'fulfilled',p_reason);end if;
  r:=private.yt_pos_action(p_order,'paid',p_reason,p_method);
 else
  -- Releasing holds preserves the customer's unused wallet reward.
  update public.yt_pos_reward_holds set state='released',updated_at=clock_timestamp() where order_id=p_order and state in ('ready','reserved');
  update public.yt_member_orders set status='cancelled',rejected_by=auth.uid(),rejected_at=clock_timestamp(),reject_reason=p_reason,updated_at=clock_timestamp() where id=p_order;
  update public.yt_pos_order_chits set status='cancelled' where order_id=p_order;
  r:=jsonb_build_object('ok',true,'order_id',p_order,'action','cancel');
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.owner_resolve','pos_order',p_order,jsonb_build_object('action',p_action,'reason',p_reason));return r;
end $$;

create function public.yt_business_context() returns jsonb language sql security invoker set search_path='' as $$select private.yt_business_context()$$;
create function public.yt_business_cutoff_save(p_minutes integer) returns jsonb language sql security invoker set search_path='' as $$select private.yt_business_cutoff_save(p_minutes)$$;
create function public.yt_pos_day_preview(p_day date default null) returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_day_preview(p_day)$$;
create function public.yt_pos_day_close(p_day date,p_opening numeric,p_cash_out numeric,p_actual numeric,p_notes text,p_request uuid,p_fingerprint text) returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_day_close(p_day,p_opening,p_cash_out,p_actual,p_notes,p_request,p_fingerprint)$$;
create function public.yt_pos_day_reopen(p_day date,p_reason text) returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_day_reopen(p_day,p_reason)$$;
create function public.yt_pos_aged_resolve(p_order uuid,p_action text,p_reason text,p_method text default null) returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_aged_resolve(p_order,p_action,p_reason,p_method)$$;
revoke all on function private.yt_business_start(date),private.yt_business_day(timestamptz),private.yt_work_owner(),private.yt_pos_day_order_guard(),private.yt_pos_payment_capture(),private.yt_pos_payment_reopen() from public,anon,authenticated;
revoke all on function private.yt_business_context(),private.yt_business_cutoff_save(integer),private.yt_pos_day_preview(date),private.yt_pos_day_close(date,numeric,numeric,numeric,text,uuid,text),private.yt_pos_day_reopen(date,text),private.yt_pos_aged_resolve(uuid,text,text,text) from public,anon;
revoke all on function public.yt_business_context(),public.yt_business_cutoff_save(integer),public.yt_pos_day_preview(date),public.yt_pos_day_close(date,numeric,numeric,numeric,text,uuid,text),public.yt_pos_day_reopen(date,text),public.yt_pos_aged_resolve(uuid,text,text,text) from public,anon;
grant execute on function private.yt_business_context(),private.yt_business_cutoff_save(integer),private.yt_pos_day_preview(date),private.yt_pos_day_close(date,numeric,numeric,numeric,text,uuid,text),private.yt_pos_day_reopen(date,text),private.yt_pos_aged_resolve(uuid,text,text,text) to authenticated;
grant execute on function public.yt_business_context(),public.yt_business_cutoff_save(integer),public.yt_pos_day_preview(date),public.yt_pos_day_close(date,numeric,numeric,numeric,text,uuid,text),public.yt_pos_day_reopen(date,text),public.yt_pos_aged_resolve(uuid,text,text,text) to authenticated;

CREATE OR REPLACE FUNCTION private.yt_pos_orders_day(p_scope text DEFAULT 'active'::text, p_day date DEFAULT NULL, p_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_result jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_scope not in ('active','pending','paid','all','mine')
  or p_limit is null or p_limit<1 or p_limit>150 then raise exception 'invalid_filter';end if;
 if p_scope='pending' and not private.yt_pos_work_cashier()
  then raise exception 'cashier_only';end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc),'[]'::jsonb)
 into v_result from (
  select x.id,x.order_no,x.table_label,x.notes,x.status,x.payment_status,
   x.amount_rm,x.created_at,x.updated_at,x.created_by,
   wa.username as created_by_name,x.accepted_at,x.fulfilled_at,x.paid_at,x.payment_method,
   exists(select 1 from public.yt_pos_order_chits chit where chit.order_id=x.id and chit.status='queued') as has_chit,
   coalesce((select jsonb_agg(jsonb_build_object(
     'id',i.id,'product_id',i.product_id,'name',i.item_name,
     'quantity',i.quantity,'price_rm',i.unit_price_rm) order by i.item_name)
    from public.yt_member_order_items i where i.order_id=x.id),'[]'::jsonb) as items
  from public.yt_member_orders x
  left join public.work_accounts wa on wa.auth_user_id=x.created_by
  where x.source='future_pos'
  and (
   (p_scope='active' and x.status in ('pending','confirmed','fulfilled') and x.payment_status='unpaid')
    or (p_scope='pending' and x.status='pending')
    or (p_scope='paid' and x.payment_status='paid' and x.paid_at>=private.yt_business_start(coalesce(p_day,private.yt_business_day(now()))) and x.paid_at<private.yt_business_start(coalesce(p_day,private.yt_business_day(now()))+1))
    or (p_scope='all')
    or (p_scope='mine' and x.created_by=auth.uid())
  )
  order by case when p_scope='paid' then x.paid_at else x.created_at end desc
  limit p_limit
 ) o;
 return v_result;
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_owner_report_v8(p_start date, p_end date, p_member_page integer DEFAULT 1, p_search text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare today date:=private.yt_business_day(now());
 a timestamptz;z timestamptz;t timestamptz;m timestamptz; result jsonb; stats jsonb; days jsonb; pay jsonb; products jsonb; orders jsonb; members jsonb; member_total bigint;
begin
 if not private.yt_has_role('owner') or not private.yt_pos_work_staff() then raise exception 'owner_only';end if;
 if p_start is null or p_end is null or p_start>p_end or p_end-p_start>365 or p_member_page is null or p_member_page<1 or p_member_page>10000 or p_search is null or length(p_search)>80 then raise exception 'invalid_report_range';end if;
 a=private.yt_business_start(p_start);z=private.yt_business_start(p_end+1);
 t=private.yt_business_start(today);m=private.yt_business_start(date_trunc('month',today::timestamp)::date);
 select jsonb_build_object('today_amount',coalesce(sum(amount_rm) filter(where paid_at>=t and paid_at<private.yt_business_start(today+1)),0),
  'today_orders',count(*) filter(where paid_at>=t and paid_at<private.yt_business_start(today+1)),
  'month_amount',coalesce(sum(amount_rm) filter(where paid_at>=m and paid_at<private.yt_business_start((date_trunc('month',today::timestamp)+interval '1 month')::date)),0),
  'month_orders',count(*) filter(where paid_at>=m and paid_at<private.yt_business_start((date_trunc('month',today::timestamp)+interval '1 month')::date)))
 into stats from public.yt_member_orders where source='future_pos' and payment_status='paid' and status='fulfilled' and paid_at>=m;
 select stats||jsonb_build_object('range_amount',coalesce(sum(o.amount_rm),0),'range_orders',count(*),
  'range_gross',coalesce(sum(i.gross),0),'range_discount',coalesce(sum(i.gross-o.amount_rm),0),
  'range_items',coalesce(sum(i.quantity),0),'average_order',coalesce(round(avg(o.amount_rm),2),0)) into stats
 from public.yt_member_orders o cross join lateral(select coalesce(sum(quantity*unit_price_rm),0) gross,coalesce(sum(quantity),0) quantity from public.yt_member_order_items where order_id=o.id) i
 where o.source='future_pos' and o.payment_status='paid' and o.status='fulfilled' and o.paid_at>=a and o.paid_at<z;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.day),'[]'::jsonb) into days from(
  select private.yt_business_day(paid_at) as day,count(*) orders,sum(amount_rm) amount_rm
  from public.yt_member_orders where source='future_pos' and payment_status='paid' and status='fulfilled' and paid_at>=a and paid_at<z group by 1) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.amount_rm desc),'[]'::jsonb) into pay from(
  select coalesce(payment_method,'未记录') method,count(*) orders,sum(amount_rm) amount_rm
  from public.yt_member_orders where source='future_pos' and payment_status='paid' and status='fulfilled' and paid_at>=a and paid_at<z group by 1) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.quantity desc,x.item_name),'[]'::jsonb) into products from(
  select i.product_id,i.item_name,sum(i.quantity) quantity,sum(i.quantity*i.unit_price_rm) gross_rm,
   sum(i.quantity*i.unit_price_rm-coalesce(u.discount,0)) net_rm
  from public.yt_member_order_items i join public.yt_member_orders o on o.id=i.order_id
  left join lateral(select sum(reward_discount_rm) discount from public.yt_pos_item_units where order_item_id=i.id) u on true
  where o.source='future_pos' and o.payment_status='paid' and o.status='fulfilled' and o.paid_at>=a and o.paid_at<z
  group by i.product_id,i.item_name order by quantity desc,i.item_name limit 20) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.paid_at desc),'[]'::jsonb) into orders from(
  select id,order_no,table_label,paid_at,payment_method,amount_rm from public.yt_member_orders
  where source='future_pos' and payment_status='paid' and status='fulfilled' and paid_at>=a and paid_at<z order by paid_at desc,id limit 50) x;
 select count(*) into member_total from public.pin_accounts p left join public.profiles f on f.id=p.auth_user_id
 where not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)
 and (p_search='' or position(lower(p_search) in lower(coalesce(f.display_name,'')||' '||p.phone))>0);
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id),'[]'::jsonb) into members from(
  select p.auth_user_id id,p.phone,coalesce(nullif(f.display_name,''),'会员') display_name,p.created_at,
   coalesce(w.balance,0) points,
   (select count(*) from public.user_rewards r where r.customer_id=p.auth_user_id and r.status='available' and r.expires_at>now()) wallet_rewards,
   (select count(*) from public.game_passes g where g.customer_id=p.auth_user_id and g.status='claimed' and g.expires_at>now()) game_passes,
   (select coalesce(sum(i.unit_price_rm-u.reward_discount_rm),0) from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id join public.yt_member_orders o on o.id=i.order_id
     where u.assigned_customer_id=p.auth_user_id and o.payment_status='paid' and o.source='future_pos') attributed_amount,
   greatest((select max(claimed_at) from public.game_passes where customer_id=p.auth_user_id),
    (select max(started_at) from public.game_sessions where customer_id=p.auth_user_id),
    (select max(redeemed_at) from public.redemptions where customer_id=p.auth_user_id)) last_activity
  from public.pin_accounts p left join public.profiles f on f.id=p.auth_user_id left join public.yt_point_wallets w on w.customer_id=p.auth_user_id
  where not exists(select 1 from public.work_accounts wa where wa.auth_user_id=p.auth_user_id)
   and (p_search='' or position(lower(p_search) in lower(coalesce(f.display_name,'')||' '||p.phone))>0)
  order by p.created_at desc,p.auth_user_id limit 40 offset (p_member_page-1)*40) x;
 result=jsonb_build_object('generated_at',now(),'timezone','Asia/Kuala_Lumpur','start',p_start,'end',p_end,'stats',stats,'days',days,'payments',pay,'products',products,'orders',orders,
  'members',members,'member_page',p_member_page,'member_page_size',40,'member_filtered_total',member_total,
  'member_stats',jsonb_build_object(
   'total',(select count(*) from public.pin_accounts p where not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)),
   'month_new',(select count(*) from public.pin_accounts p where created_at>=m and created_at<private.yt_business_start(today+1) and not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)),
   'active_30d',(select count(distinct customer_id) from(
     select customer_id from public.game_passes where claimed_at>=now()-interval '30 days'
     union select customer_id from public.game_sessions where started_at>=now()-interval '30 days'
     union select customer_id from public.redemptions where redeemed_at>=now()-interval '30 days') q where customer_id is not null and exists(select 1 from public.pin_accounts pa where pa.auth_user_id=q.customer_id) and not exists(select 1 from public.work_accounts wa where wa.auth_user_id=q.customer_id)),
   'point_balance',(select coalesce(sum(balance),0) from public.yt_point_wallets)),
  'live',jsonb_build_object(
   'pending_orders',(select count(*) from public.yt_member_orders where source='future_pos' and status='pending' and payment_status='unpaid'),
   'preparing_orders',(select count(*) from public.yt_member_orders where source='future_pos' and status='confirmed' and payment_status='unpaid'),
   'unpaid_orders',(select count(*) from public.yt_member_orders where source='future_pos' and status='fulfilled' and payment_status='unpaid'),
   'active_products',(select count(*) from public.yt_shop_products where active),
   'active_series',(select count(*) from public.yt_pos_series where active and benefit_mode in('games','choose') and game_plays=1),
   'active_campaigns',(select count(*) from public.campaigns where active and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>now())),
   'active_rewards',(select count(*) from public.rewards r where r.active and exists(select 1 from public.yt_pos_reward_rules b where b.reward_id=r.id and b.mode<>'disabled')),
   'unbound_rewards',(select count(*) from public.rewards r where r.active and not exists(select 1 from public.yt_pos_reward_rules b where b.reward_id=r.id and b.mode<>'disabled')),
   'active_banners',(select count(*) from public.yt_home_banners where enabled),
   'work_accounts',(select count(*) from public.work_accounts where active),
   'unclaimed_passes',(select count(*) from public.game_passes where status='issued' and expires_at>now()),
   'claimed_passes',(select count(*) from public.game_passes where status='claimed' and expires_at>now()),
   'open_game_sessions',(select count(*) from public.game_sessions where status='started' and started_at>=now()-interval '1 day'),
   'wallet_rewards',(select count(*) from public.user_rewards where status='available' and expires_at>now()),
   'expiring_rewards',(select count(*) from public.user_rewards where status='available' and expires_at>now() and expires_at<=now()+interval '7 days'),
   'active_offers',(select count(*) from public.reward_offers where active and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>now()) and (max_claims is null or claimed_count<max_claims)),
   'held_rewards',(select count(*) from public.yt_pos_reward_holds where state in('reserved','ready') and expires_at>now()),
   'low_stock_pool_entries',(select count(*) from public.reward_pool_entries p join public.campaigns c on c.id=p.campaign_id where c.active and p.weight>0 and p.max_total is not null and p.max_total-p.issued_total<=5)),
  'reward_activity',jsonb_build_object(
   'issued',(select count(*) from public.user_rewards where created_at>=a and created_at<z),
   'redeemed',(select count(*) from public.redemptions where redeemed_at>=a and redeemed_at<z),
   'passes_claimed',(select count(*) from public.game_passes where claimed_at>=a and claimed_at<z),
   'games_completed',(select count(*) from public.game_sessions where status='completed' and completed_at>=a and completed_at<z),
   'points_earned',(select coalesce(sum(points),0) from public.yt_point_entries where direction='earn' and created_at>=a and created_at<z),
   'points_spent',(select coalesce(sum(points),0) from public.yt_point_entries where direction='spend' and created_at>=a and created_at<z)));
 result=result||jsonb_build_object(
  'months',coalesce((select jsonb_agg(to_jsonb(x) order by x.month) from(
   select to_char(private.yt_business_day(paid_at),'YYYY-MM') as month,count(*) orders,sum(amount_rm) amount_rm
   from public.yt_member_orders where source='future_pos' and payment_status='paid' and status='fulfilled' and paid_at>=a and paid_at<z group by 1) x),'[]'::jsonb),
  'cashiers',coalesce((select jsonb_agg(to_jsonb(x) order by x.amount_rm desc) from(
   select coalesce(w.username,'原工作账号') username,count(*) orders,sum(o.amount_rm) amount_rm
   from public.yt_member_orders o left join public.work_accounts w on w.auth_user_id=o.paid_by
   where o.source='future_pos' and o.payment_status='paid' and o.status='fulfilled' and o.paid_at>=a and o.paid_at<z group by w.username) x),'[]'::jsonb),
  'reward_types',coalesce((select jsonb_agg(to_jsonb(x) order by x.reward_name) from(
   select r.name reward_name,
    (select count(*) from public.user_rewards u where u.reward_id=r.id and u.created_at>=a and u.created_at<z) issued,
    (select count(*) from public.user_rewards u join public.redemptions d on d.user_reward_id=u.id where u.reward_id=r.id and d.redeemed_at>=a and d.redeemed_at<z) redeemed,
    (select count(*) from public.user_rewards u where u.reward_id=r.id and u.status='available' and u.expires_at>now()) outstanding,
    (select count(*) from public.user_rewards u where u.reward_id=r.id and u.status='available' and u.expires_at>now() and u.expires_at<=now()+interval '7 days') expiring
   from public.rewards r order by r.name,r.id limit 100) x),'[]'::jsonb));
 return result||jsonb_build_object('business_day',today);
end;$function$;

create function public.yt_pos_orders_day(p_scope text default 'active',p_day date default null,p_limit integer default 60) returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_orders_day(p_scope,p_day,p_limit)$$;
revoke all on function public.yt_pos_orders_day(text,date,integer),private.yt_pos_orders_day(text,date,integer) from public,anon;
grant execute on function public.yt_pos_orders_day(text,date,integer),private.yt_pos_orders_day(text,date,integer) to authenticated;


CREATE OR REPLACE FUNCTION private.yt_owner_reset_v8(p_actor uuid, p_session text, p_action text, p_challenge uuid DEFAULT NULL::uuid, p_request uuid DEFAULT NULL::uuid, p_done bigint[] DEFAULT '{}'::bigint[], p_scopes text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v private.yt_owner_reset_challenges%rowtype; s text[]; counts jsonb:='{}'; result jsonb; c uuid;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'owner_only';end if;
 if p_session is null or p_session !~ '^[0-9a-f]{64}$' then raise exception 'not_authenticated';end if;
 if not exists(select 1 from public.work_accounts a join public.staff_roles r on r.user_id=a.auth_user_id
  where a.auth_user_id=p_actor and a.role='owner' and a.active and not a.must_change_password and r.role='owner' and r.active)
 then raise exception 'owner_only';end if;
 if p_action in ('status','batch','ack') then
  result=private.yt_owner_reset_v7(p_actor,p_session,p_action,p_challenge,p_request,p_done);
  select * into v from private.yt_owner_reset_challenges where id=(result->>'challenge')::uuid and actor_id=p_actor;
  return result||jsonb_build_object('scopes',coalesce(v.scopes,'{}'::text[]));
 end if;
 if p_action='prepare' then
  if p_request is null then raise exception 'invalid_reset_request';end if;
  if p_scopes is null or cardinality(p_scopes)=0 or cardinality(p_scopes)>6 or exists(
   select 1 from unnest(p_scopes) x where x is null or x not in ('records','members','catalog','campaigns','team','banners'))
  then raise exception 'invalid_reset_scope';end if;
  select array_agg(distinct x order by x) into s from unnest(p_scopes) x;
  if s&&array['members','catalog','campaigns','team']::text[] and not ('records'=any(s)) then s=array_append(s,'records');end if;
  select array_agg(x order by x) into s from unnest(s) x;
  if exists(select 1 from private.yt_owner_reset_challenges where state='committed') then raise exception 'reset_cleanup_pending';end if;
  if 'records'=any(s) then counts=counts||jsonb_build_object('订单',(select count(*) from public.yt_member_orders),'Game Pass',(select count(*) from public.game_passes),'钱包奖励',(select count(*) from public.user_rewards),'积分记录',(select count(*) from public.yt_point_entries));end if;
  if 'members'=any(s) then counts=counts||jsonb_build_object('会员账号',(select count(*) from public.pin_accounts where auth_user_id<>p_actor and not exists(select 1 from public.work_accounts w where w.auth_user_id=pin_accounts.auth_user_id)));end if;
  if 'catalog'=any(s) then counts=counts||jsonb_build_object('商品',(select count(*) from public.yt_shop_products),'权益系列',(select count(*) from public.yt_pos_series));end if;
  if 'campaigns'=any(s) then counts=counts||jsonb_build_object('活动',(select count(*) from public.campaigns),'奖励种类',(select count(*) from public.rewards));end if;
  if 'team'=any(s) then counts=counts||jsonb_build_object('其他工作账号',(select count(*) from public.work_accounts where auth_user_id<>p_actor));end if;
  if 'banners'=any(s) then counts=counts||jsonb_build_object('广告',(select count(*) from public.yt_home_banners),'广告文件',(select count(*) from storage.objects where bucket_id='yetipsy-home-banners'));end if;
  insert into private.yt_owner_reset_challenges(actor_id,session_key,request_id,counts,scopes)
   values(p_actor,p_session,p_request,counts,s) on conflict(actor_id,session_key,request_id) do nothing;
  select * into v from private.yt_owner_reset_challenges where actor_id=p_actor and session_key=p_session and request_id=p_request;
  if v.scopes<>s then raise exception 'reset_scope_conflict';end if;
  if v.state<>'pending' or v.expires_at<=now() then raise exception 'reset_confirmation_expired';end if;
  return jsonb_build_object('challenge',v.id,'counts',v.counts,'scopes',v.scopes,'expires_at',v.expires_at);
 end if;
 if p_action<>'commit' or p_challenge is null then raise exception 'invalid_reset_request';end if;
 perform pg_advisory_xact_lock(781943071);
 select * into v from private.yt_owner_reset_challenges where id=p_challenge and actor_id=p_actor and session_key=p_session for update;
 if not found then raise exception 'reset_confirmation_expired';end if;
 if v.state in ('committed','complete') then return jsonb_build_object('challenge',v.id,'state',v.state,'scopes',v.scopes);end if;
 if v.state<>'pending' or v.expires_at<=now() then raise exception 'reset_confirmation_expired';end if;
 if exists(select 1 from private.yt_owner_reset_challenges where state='committed' and id<>v.id) then raise exception 'reset_cleanup_pending';end if;
 s=v.scopes;
 if cardinality(s)=6 then
  delete from public.yt_business_cutoffs;insert into public.yt_business_cutoffs(effective_day,cutoff_minutes) values('1900-01-01',360);
 end if;
 -- Only this immutable first-confirmation snapshot controls deletion.
 if 'banners'=any(s) then
  insert into private.yt_owner_reset_cleanup(challenge_id,kind,target) select v.id,'asset',name from storage.objects where bucket_id='yetipsy-home-banners';
 end if;
 insert into private.yt_owner_reset_cleanup(challenge_id,kind,target)
 select v.id,'user',u.id::text from auth.users u where u.id<>p_actor and (
  ('members'=any(s) and 'team'=any(s))
  or ('members'=any(s) and exists(select 1 from public.pin_accounts a where a.auth_user_id=u.id) and not exists(select 1 from public.work_accounts a where a.auth_user_id=u.id))
  or ('team'=any(s) and exists(select 1 from public.work_accounts a where a.auth_user_id=u.id)));
 if 'records'=any(s) then
  -- Fixed transaction tables; configuration and account tables are retained.
  truncate table private.yt_offer_code_attempts,private.yt_offer_short_codes,private.yt_pos_draft_submissions,
   private.yt_redeem_code_attempts,private.yt_redeem_short_codes,
   public.audit_logs,public.game_passes,public.game_sessions,public.idempotency_keys,
   public.pin_auth_limits,public.pin_lookup_limits,public.pin_reset_tokens,public.redeem_tokens,public.redemptions,
   public.reward_offer_claims,public.reward_offers,public.user_rewards,public.work_auth_limits,
   public.yt_game_best_records,public.yt_game_leaderboard_preferences,public.yt_integration_events,
   public.yt_member_enrollments,public.yt_member_order_items,public.yt_member_orders,public.yt_point_entries,public.yt_point_wallets,
   public.yt_pos_payment_entries,public.yt_pos_day_closings,public.yt_pos_item_units,public.yt_pos_order_chits,public.yt_pos_order_events,public.yt_pos_pass_bundle_items,public.yt_pos_pass_bundles,
   public.yt_pos_preorder_holds,public.yt_pos_reward_holds,public.yt_promo_grants,public.yt_referral_links restart identity;
  update public.reward_pool_entries set issued_total=0,issued_today=0,issued_day=null;
  -- Deleted enrollment/grant history must not automatically grant old members new gifts.
  update public.yt_loyalty_config set welcome_enabled=false,referral_enabled=false,updated_at=now();
 end if;
 if 'campaigns'=any(s) then
  delete from public.yt_pos_reward_rules;delete from public.reward_pool_entries;delete from public.campaign_games;
  delete from public.yt_point_tiers;delete from public.yt_loyalty_config;
  delete from public.rewards;delete from public.campaigns;
  insert into public.yt_loyalty_config(id) values(true);
  insert into public.campaigns(name,active) values('默认活动',false) returning id into c;
  insert into public.campaign_games(campaign_id,game_id) select c,id from public.games where active;
 end if;
 if 'catalog'=any(s) then
  delete from public.yt_pos_reward_rules where product_id is not null or series_id is not null;
  delete from public.yt_shop_products;delete from public.yt_pos_series;
 end if;
 if 'banners'=any(s) then delete from public.yt_home_banners;end if;
 if s&&array['members','team']::text[] then
  update public.yt_home_banners set updated_by=null where updated_by::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  update public.yt_loyalty_config set updated_by=null where updated_by::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  update public.yt_pos_reward_rules set updated_by=null where updated_by::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  update public.work_accounts set created_by=null where created_by::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.pin_accounts where auth_user_id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.member_details where user_id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.work_accounts where auth_user_id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.staff_roles where user_id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
  delete from public.profiles where id::text in(select target from private.yt_owner_reset_cleanup where challenge_id=v.id and kind='user');
 end if;
 update private.yt_owner_reset_challenges set state='cancelled' where state='pending' and id<>v.id;
 update private.yt_owner_reset_challenges set state='committed' where id=v.id;
 return jsonb_build_object('challenge',v.id,'state','committed','scopes',v.scopes);
end;$function$;


CREATE OR REPLACE FUNCTION private.yt_pos_action(p_order uuid, p_action text, p_reason text DEFAULT NULL::text, p_method text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_member_orders%rowtype;v_cashier boolean:=private.yt_pos_work_cashier();
 v_actor uuid:=auth.uid();v_reason text:=nullif(btrim(coalesce(p_reason,'')),'');
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_order is null or p_action not in ('accept','reject','fulfilled','paid','cancel')
 then raise exception 'invalid_action';end if;
 select * into v from public.yt_member_orders
  where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 if v.created_at<=clock_timestamp()-interval '72 hours' and private.yt_work_owner() and length(btrim(coalesce(p_reason,'')))<2 then raise exception 'reason_required';end if; if p_action='accept' then
  if not v_cashier then raise exception 'cashier_only';end if;
  if v.status<>'pending' or v.payment_status<>'unpaid' then raise exception 'order_not_pending';end if;
  update public.yt_member_orders set status='confirmed',accepted_by=v_actor,
   accepted_at=clock_timestamp(),updated_at=clock_timestamp()
  where id=p_order;
  -- Only approved non-Cashier orders generate order chits.
  insert into public.yt_pos_order_chits(order_id)values(p_order)
    on conflict(order_id) do update
    set status='queued',issued_at=clock_timestamp(),printed_at=null,printed_by=null;
 elsif p_action='reject' then
  if not v_cashier then raise exception 'cashier_only';end if;
  if v.status<>'pending' or v.payment_status<>'unpaid' then raise exception 'order_not_pending';end if;
  if length(coalesce(v_reason,''))<2 or length(v_reason)>300 then raise exception 'reason_required';end if;
  update public.yt_member_orders set status='cancelled',
   rejected_by=v_actor,rejected_at=clock_timestamp(),reject_reason=v_reason,updated_at=clock_timestamp()
   where id=p_order;
 elsif p_action='fulfilled' then
  if v.status<>'confirmed' or v.payment_status<>'unpaid' then raise exception 'order_not_accepted';end if;
  update public.yt_member_orders set status='fulfilled',
   fulfilled_by=v_actor,fulfilled_at=clock_timestamp(),updated_at=clock_timestamp()
   where id=p_order;
 elsif p_action='paid' then
  if not v_cashier then raise exception 'cashier_only';end if;
  if v.status<>'fulfilled' or v.payment_status<>'unpaid' then raise exception 'order_not_served';end if;
  if p_method is null or btrim(p_method)='' then p_method:='foodcourt';end if;
  if p_method not in ('foodcourt','cash','duitnow','card','bank_transfer','other') then raise exception 'invalid_payment_method';end if;
  update public.yt_member_orders set payment_status='paid',
   paid_by=v_actor,paid_at=clock_timestamp(),payment_method=p_method,
   updated_at=clock_timestamp() where id=p_order;
 elsif p_action='cancel' then
  if not v_cashier then raise exception 'cashier_only';end if;
  if v.status not in ('pending','confirmed') or v.payment_status<>'unpaid' then raise exception 'order_cannot_cancel';end if;
  if length(coalesce(v_reason,''))<2 or length(v_reason)>300 then raise exception 'reason_required';end if;
  update public.yt_member_orders set status='cancelled',
   rejected_by=v_actor,rejected_at=clock_timestamp(),reject_reason=v_reason,updated_at=clock_timestamp()
  where id=p_order;
  update public.yt_pos_order_chits set status='cancelled' where order_id=p_order;
 end if;
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note)
 values(p_order,v_actor,case when p_action='fulfilled' then 'fulfilled'
  when p_action='paid' then 'paid' when p_action in ('reject','cancel') then
   case when p_action='reject' then 'rejected' else 'cancelled' end
  else 'accepted' end,
 case when v_cashier then 'cashier' else 'staff' end,
 case when p_action='paid' then p_method else v_reason end);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(v_actor,'pos.'||p_action,'pos_order',p_order,
  jsonb_build_object('payment_method',p_method,'note',v_reason));
 return jsonb_build_object('ok',true,'order_id',p_order,'action',p_action,'status',
  case when p_action='accept' then 'confirmed' when p_action='fulfilled' then 'fulfilled'
       when p_action in ('reject','cancel') then 'cancelled' else v.status end,
  'payment_status',case when p_action='paid' then 'paid' else v.payment_status end);
end;$function$;

