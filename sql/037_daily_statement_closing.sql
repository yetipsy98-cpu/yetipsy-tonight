-- Replace manual cash reconciliation with a saved Daily Statement snapshot.
-- Legacy cash columns stay in place for backward-compatible historical rows only.

create or replace function private.yt_pos_day_preview(p_day date default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
 d date:=coalesce(p_day,private.yt_business_day(now()));
 s jsonb;c jsonb;pending jsonb;items jsonb;blockers bigint;n bigint;methods jsonb;fingerprint text;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if d<'2020-01-01' or d>private.yt_business_day(now()) then raise exception 'invalid_business_day';end if;

 select coalesce(jsonb_agg(to_jsonb(x) order by x.method),'[]'::jsonb) into methods from (
  select method,sum(amount_rm) net_rm,sum(greatest(amount_rm,0)) received_rm,
   -sum(least(amount_rm,0)) refunded_rm,count(distinct order_id) orders
  from public.yt_pos_payment_entries where business_day=d group by method
 )x;

 select coalesce(jsonb_agg(to_jsonb(x) order by x.quantity desc,x.item_name),'[]'::jsonb) into items from (
  select i.product_id,i.item_name,sum(i.quantity)::bigint quantity,
   sum(i.quantity*i.unit_price_rm)::numeric gross_rm,
   coalesce(sum(u.discount_rm),0)::numeric discount_rm,
   (sum(i.quantity*i.unit_price_rm)-coalesce(sum(u.discount_rm),0))::numeric net_rm
  from public.yt_member_order_items i
  join public.yt_member_orders o on o.id=i.order_id and o.source='future_pos'
  join (select distinct order_id from public.yt_pos_payment_entries where business_day=d and kind='sale') sold on sold.order_id=o.id
  left join lateral(
   select coalesce(sum(unit.reward_discount_rm),0) discount_rm
   from public.yt_pos_item_units unit
   where unit.order_item_id=i.id and not unit.retired and unit.unit_number<=i.quantity
  )u on true
  where i.quantity>0
  group by i.product_id,i.item_name
 )x;

 select jsonb_build_object(
  'net_rm',coalesce(sum(amount_rm),0),
  'received_rm',coalesce(sum(greatest(amount_rm,0)),0),
  'refunded_rm',-coalesce(sum(least(amount_rm,0)),0),
  'cash_rm',coalesce(sum(amount_rm) filter(where method='cash'),0),
  'orders',count(distinct order_id) filter(where kind='sale'),
  'payment_orders',count(distinct order_id),
  'entries',count(*),
  'last_entry',coalesce(max(id),0),
  'gross_rm',coalesce((select sum((x->>'gross_rm')::numeric) from jsonb_array_elements(items)x),0),
  'discount_rm',coalesce((select sum((x->>'discount_rm')::numeric) from jsonb_array_elements(items)x),0),
  'units',coalesce((select sum((x->>'quantity')::bigint) from jsonb_array_elements(items)x),0),
  'cancelled_orders',(select count(*) from public.yt_member_orders o where o.source='future_pos' and o.status='cancelled' and o.updated_at>=private.yt_business_start(d) and o.updated_at<private.yt_business_start(d+1))
 ) into s
 from public.yt_pos_payment_entries where business_day=d;

 select count(*),count(*) filter(where coalesce(settlement_due_since,created_at)<=now()-interval '72 hours') into n,blockers
 from public.yt_member_orders
 where source='future_pos' and ((status in ('pending','confirmed','fulfilled') and payment_status='unpaid') or (payment_status='paid' and settlement_due_since is not null));

 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at),'[]'::jsonb) into pending from (
  select id,order_no,table_label,status,payment_status,
   case when payment_status='paid' then abs(amount_rm-private.yt_pos_received(id)) else amount_rm end as amount_rm,
   coalesce(settlement_due_since,created_at) as created_at,
   coalesce(settlement_due_since,created_at)<=now()-interval '72 hours' as overdue
  from public.yt_member_orders
  where source='future_pos' and ((status in ('pending','confirmed','fulfilled') and payment_status='unpaid') or (payment_status='paid' and settlement_due_since is not null))
  order by coalesce(settlement_due_since,created_at) limit 100
 )x;

 select to_jsonb(x) into c from public.yt_pos_day_closings x where business_day=d order by revision desc limit 1;
 fingerprint:=md5(s::text||methods::text||items::text||n::text||blockers::text||coalesce(c->>'id','')||coalesce(c->>'state',''));
 return jsonb_build_object(
  'statement_version',2,'day',d,'context',private.yt_business_context(),
  'start_at',private.yt_business_start(d),'end_at',private.yt_business_start(d+1),
  'stats',s,'items',items,'methods',methods,'pending',pending,'pending_count',n,
  'blocker_count',blockers,'closing',c,'fingerprint',fingerprint
 );
end $$;

create function private.yt_pos_day_statement_close(
 p_day date,p_notes text,p_request uuid,p_fingerprint text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;v public.yt_pos_day_closings%rowtype;rev integer;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if p_request is null or p_day is null or length(coalesce(p_notes,''))>600 then raise exception 'invalid_day_close';end if;
 perform pg_advisory_xact_lock(781943080);
 select * into v from public.yt_pos_day_closings where request_id=p_request;
 if found then
  if v.business_day<>p_day or coalesce(v.notes,'')<>coalesce(p_notes,'') then raise exception 'request_conflict';end if;
  return to_jsonb(v);
 end if;
 r:=private.yt_pos_day_preview(p_day);
 if (r->>'blocker_count')::bigint>0 then raise exception 'aged_orders_block_day_close';end if;
 if r#>>'{closing,state}'='closed' then raise exception 'business_day_already_closed';end if;
 if p_fingerprint is null or p_fingerprint<>r->>'fingerprint' then raise exception 'day_close_changed_reload';end if;
 if (r->>'pending_count')::bigint>0 and length(btrim(coalesce(p_notes,'')))<2 then raise exception 'day_close_note_required';end if;
 select coalesce(max(revision),0)+1 into rev from public.yt_pos_day_closings where business_day=p_day;
 insert into public.yt_pos_day_closings(
  business_day,revision,state,request_id,opening_cash,cash_out,expected_cash,actual_cash,difference_rm,snapshot,notes,closed_by
 ) values(p_day,rev,'closed',p_request,0,0,0,0,0,r,p_notes,auth.uid()) returning * into v;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(auth.uid(),'pos.day_statement_close','day_close',v.id,jsonb_build_object(
  'day',p_day,'revision',rev,'net_rm',r#>>'{stats,net_rm}','orders',r#>>'{stats,orders}',
  'units',r#>>'{stats,units}','pending',r->>'pending_count'
 ));
 return to_jsonb(v);
end $$;

create function public.yt_pos_day_statement_close(
 p_day date,p_notes text,p_request uuid,p_fingerprint text
) returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_pos_day_statement_close(p_day,p_notes,p_request,p_fingerprint)
$$;

-- The workbench no longer exposes or uses the legacy cash-count close action.
revoke all on function private.yt_pos_day_close(date,numeric,numeric,numeric,text,uuid,text) from public,anon,authenticated;
revoke all on function public.yt_pos_day_close(date,numeric,numeric,numeric,text,uuid,text) from public,anon,authenticated;
revoke all on function private.yt_pos_day_statement_close(date,text,uuid,text) from public,anon;
revoke all on function public.yt_pos_day_statement_close(date,text,uuid,text) from public,anon;
grant execute on function private.yt_pos_day_statement_close(date,text,uuid,text) to authenticated;
grant execute on function public.yt_pos_day_statement_close(date,text,uuid,text) to authenticated;

