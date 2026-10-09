-- Keep historical item/unit IDs so prior GamePass and redemption records survive edits.
do $$declare c record;begin
 for c in select conname from pg_constraint where conrelid='public.yt_member_order_items'::regclass and contype='c' and pg_get_constraintdef(oid) like '%quantity%' loop
  execute format('alter table public.yt_member_order_items drop constraint %I',c.conname);
 end loop;
end $$;

alter table public.yt_member_order_items add constraint yt_order_quantity_revision_check check(quantity between 0 and 10000);
alter table public.yt_pos_item_units add column retired boolean not null default false;
alter table public.yt_member_orders add column revision integer not null default 0;
alter table public.yt_member_orders add column settlement_due_since timestamptz;
alter table public.yt_member_orders add column cancel_after_refund boolean not null default false;
create table public.yt_pos_order_revisions(
 id uuid primary key default gen_random_uuid(),order_id uuid not null references public.yt_member_orders(id) on delete cascade,
 revision integer not null,request_id uuid not null unique,request_payload jsonb not null,
 reason text not null,actor_id uuid references auth.users(id) on delete set null,
 before_state jsonb not null,after_state jsonb not null,revoke_benefits boolean not null default false,
 created_at timestamptz not null default now(),unique(order_id,revision)
);
create index yt_order_revisions_order_idx on public.yt_pos_order_revisions(order_id,revision desc);
alter table public.yt_pos_order_revisions enable row level security;
revoke all on public.yt_pos_order_revisions from public,anon,authenticated;

create function private.yt_pos_received(p_order uuid) returns numeric language sql stable set search_path='' as $$
 select coalesce(sum(amount_rm),0) from public.yt_pos_payment_entries where order_id=p_order
$$;
create function private.yt_pos_revision_lines(p_order uuid,p_items jsonb,p_cancel boolean default false) returns jsonb language plpgsql set search_path='' as $$
declare j jsonb;old_line public.yt_member_order_items%rowtype;p public.yt_shop_products%rowtype;
 item uuid;product uuid;qty integer;price numeric;gross numeric:=0;discount numeric:=0;line_discount numeric;units integer:=0;paid_drinks integer:=0;lines jsonb:='[]';seen uuid[]:='{}';
begin
 if p_cancel then return jsonb_build_object('lines','[]'::jsonb,'gross',0,'discount',0,'net',0);end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 30 then raise exception 'invalid_order_revision';end if;
 for j in select value from jsonb_array_elements(p_items) loop
  if coalesce(j->>'product_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or coalesce(j->>'quantity','') !~ '^[0-9]{1,2}$' then raise exception 'invalid_order_line';end if;
  product:=(j->>'product_id')::uuid;qty:=(j->>'quantity')::integer;
  if qty not between 1 and 20 then raise exception 'invalid_quantity';end if;
  item:=null;old_line:=null;
  if nullif(j->>'item_id','') is not null then
   item:=(j->>'item_id')::uuid;
   select * into old_line from public.yt_member_order_items where id=item and order_id=p_order;
   if not found or item=any(seen) then raise exception 'invalid_order_line';end if;seen:=array_append(seen,item);
  end if;
  select * into p from public.yt_shop_products where id=product for share;
  if not found or (not p.active and product is distinct from old_line.product_id) then raise exception 'product_unavailable';end if;
  price:=case when product=old_line.product_id then old_line.unit_price_rm else p.price_rm end;
  if j ? 'unit_price_rm' then
   if coalesce(j->>'unit_price_rm','') !~ '^[0-9]{1,4}(\.[0-9]{1,2})?$' then raise exception 'invalid_revision_price';end if;
   price:=(j->>'unit_price_rm')::numeric;
  end if;
  if price not between 0 and 5000 then raise exception 'invalid_revision_price';end if;
  select coalesce(sum(least(u.reward_discount_rm,price)),0),count(*) filter(where price>u.reward_discount_rm)
  into line_discount,paid_drinks from public.yt_pos_item_units u where u.order_item_id=item and u.unit_number<=qty;
  gross:=gross+qty*price;discount:=discount+line_discount;units:=units+qty;
  if gross>100000 or units>80 then raise exception 'order_too_large';end if;
  lines:=lines||jsonb_build_array(jsonb_build_object('item_id',item,'product_id',product,'name',case when product=old_line.product_id then old_line.item_name else p.title end,
   'quantity',qty,'unit_price_rm',price,'discount_rm',line_discount,'is_drink',case when product=old_line.product_id then old_line.is_drink_at_order else p.is_drink end,'series_id',p.series_id));
 end loop;
 if discount>0 and not exists(select 1 from jsonb_array_elements(lines) l where (l->>'is_drink')::boolean and (l->>'quantity')::integer*(l->>'unit_price_rm')::numeric>(l->>'discount_rm')::numeric) then raise exception 'minimum_one_paid_drink';end if;
 return jsonb_build_object('lines',lines,'gross',gross,'discount',discount,'net',greatest(0,gross-discount));
end $$;
create function private.yt_pos_order_benefits(p_order uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
 'passes',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'status',p.status,'claimed_at',p.claimed_at,'expires_at',p.expires_at)) from public.game_passes p where p.id in(select u.game_pass_id from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id where i.order_id=p_order)),'[]'::jsonb),
 'rewards',coalesce((select jsonb_agg(jsonb_build_object('id',w.id,'name',r.name,'status',w.status,'locked',exists(select 1 from public.yt_pos_reward_holds h where h.user_reward_id=w.id and h.state in ('reserved','ready')) or exists(select 1 from public.yt_pos_preorder_holds h where h.user_reward_id=w.id and h.state in ('pending','ready') and h.expires_at>now())))
  from public.user_rewards w join public.rewards r on r.id=w.reward_id join public.game_sessions s on s.id=w.session_id
  where s.pass_id in(select u.game_pass_id from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id where i.order_id=p_order)),'[]'::jsonb),
 'points',coalesce((select sum(e.points) from public.yt_point_entries e where e.direction='earn' and e.game_pass_id in(select u.game_pass_id from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id where i.order_id=p_order)
 and not exists(select 1 from public.yt_point_entries a where a.customer_id=e.customer_id and a.direction='adjust' and a.reference='OWNER-REVOKE:'||e.game_pass_id::text)),0))
$$;
create function private.yt_pos_revoke_order_benefits(p_order uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare ids uuid[];e record;b bigint;report jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select array_agg(u.game_pass_id order by u.game_pass_id) into ids from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id where i.order_id=p_order and u.game_pass_id is not null;
 if ids is null then return private.yt_pos_order_benefits(p_order);end if;
 perform 1 from public.game_sessions where pass_id=any(ids) order by id for update;
 perform 1 from public.game_passes where id=any(ids) order by id for update;
 perform 1 from public.user_rewards w join public.game_sessions s on s.id=w.session_id where s.pass_id=any(ids) order by w.id for update of w;
 report:=private.yt_pos_order_benefits(p_order);
 if exists(select 1 from jsonb_array_elements(report->'rewards') w where w->>'status'='redeemed') then raise exception 'issued_reward_already_redeemed';end if;
 if exists(select 1 from jsonb_array_elements(report->'rewards') w where (w->>'locked')::boolean) then raise exception 'issued_reward_locked';end if;
 perform 1 from public.yt_point_wallets where customer_id in(select customer_id from public.yt_point_entries where game_pass_id=any(ids) and direction='earn') order by customer_id for update;
 for e in select customer_id,sum(points) points from public.yt_point_entries x where x.game_pass_id=any(ids) and direction='earn' and not exists(select 1 from public.yt_point_entries a where a.customer_id=x.customer_id and a.direction='adjust' and a.reference='OWNER-REVOKE:'||x.game_pass_id::text) group by customer_id loop
  select balance into b from public.yt_point_wallets where customer_id=e.customer_id;
  if coalesce(b,0)<e.points then raise exception 'issued_points_balance_insufficient';end if;
 end loop;
 for e in select * from public.yt_point_entries x where x.game_pass_id=any(ids) and direction='earn' and not exists(select 1 from public.yt_point_entries a where a.customer_id=x.customer_id and a.direction='adjust' and a.reference='OWNER-REVOKE:'||x.game_pass_id::text) order by customer_id,id loop
  update public.yt_point_wallets set balance=balance-e.points,lifetime_spent=lifetime_spent+e.points,updated_at=clock_timestamp() where customer_id=e.customer_id;
  insert into public.yt_point_entries(customer_id,direction,points,reference) values(e.customer_id,'adjust',e.points,'OWNER-REVOKE:'||e.game_pass_id::text);
 end loop;
 update public.user_rewards w set status='revoked' from public.game_sessions s where w.session_id=s.id and s.pass_id=any(ids) and w.status in ('available','expired');
 update public.game_sessions set status='cancelled' where pass_id=any(ids) and status='started';
 update public.game_passes set status='revoked' where id=any(ids) and status<>'revoked';
 update public.yt_pos_pass_bundles set status='expired',expires_at=clock_timestamp() where order_id=p_order and status='issued';
 update public.yt_pos_item_units set benefit_status='void' where game_pass_id=any(ids);
 return report;
end $$;

create function private.yt_pos_owner_revision_preview(p_order uuid,p_items jsonb,p_cancel boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_member_orders%rowtype;r jsonb;received numeric;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos';
 if not found or v.status in ('cancelled','refunded') then raise exception 'order_not_editable';end if;
 r:=private.yt_pos_revision_lines(p_order,p_items,p_cancel);received:=private.yt_pos_received(p_order);
 return r||jsonb_build_object('order_id',p_order,'updated_at',v.updated_at,'before_amount_rm',v.amount_rm,'received_rm',received,
 'balance_rm',case when v.payment_status='paid' then (r->>'net')::numeric-received else (r->>'net')::numeric end,'benefits',private.yt_pos_order_benefits(p_order));
end $$;
create function private.yt_pos_owner_order_context(p_order uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare b jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 b:=private.yt_pos_bill_v8(p_order);
 return b||jsonb_build_object('items',coalesce((select jsonb_agg(jsonb_build_object('id',id,'product_id',product_id,'name',item_name,'quantity',quantity,'price_rm',unit_price_rm) order by id) from public.yt_member_order_items where order_id=p_order and quantity>0),'[]'::jsonb),
 'benefits',private.yt_pos_order_benefits(p_order),'received_rm',private.yt_pos_received(p_order),
 'revisions',coalesce((select jsonb_agg(to_jsonb(x) order by x.revision desc) from(select revision,reason,created_at,revoke_benefits,before_state->'amount_rm' before_amount,after_state->'amount_rm' after_amount from public.yt_pos_order_revisions where order_id=p_order order by revision desc limit 20)x),'[]'::jsonb));
end $$;

-- OWNER APPLY: a revision changes the bill, never invents a payment.
create function private.yt_pos_owner_revision_apply(p_order uuid,p_items jsonb,p_reason text,p_table text,p_note text,p_expected_updated timestamptz,p_request uuid,p_revoke boolean default false,p_cancel boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_member_orders%rowtype;old jsonb;r jsonb;j jsonb;item uuid;idx integer;keep uuid[]:='{}';received numeric;balance numeric;payload jsonb;done public.yt_pos_order_revisions%rowtype;after_state jsonb;benefits jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_order is null or p_request is null or p_expected_updated is null or p_revoke is null or p_cancel is null or length(btrim(coalesce(p_reason,''))) not between 3 and 300 or length(coalesce(p_table,''))>32 or length(coalesce(p_note,''))>600 then raise exception 'invalid_order_revision';end if;
 payload:=jsonb_build_object('order',p_order,'items',p_items,'reason',p_reason,'table',p_table,'note',p_note,'expected',p_expected_updated,'revoke',p_revoke,'cancel',p_cancel);
 select * into v from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 select * into done from public.yt_pos_order_revisions where request_id=p_request;
 if found then if done.request_payload<>payload then raise exception 'request_conflict';end if;return done.after_state||jsonb_build_object('ok',true,'retried',true);end if;
 if v.status in ('cancelled','refunded') then raise exception 'order_not_editable';end if;
 if v.updated_at<>p_expected_updated then raise exception 'order_changed_reload';end if;
 perform pg_advisory_xact_lock(781943080);
 if exists(select 1 from public.yt_pos_reward_holds where order_id=p_order and state in ('ready','reserved')) and not p_cancel then raise exception 'release_coupon_before_edit';end if;
 r:=private.yt_pos_revision_lines(p_order,p_items,p_cancel);received:=private.yt_pos_received(p_order);
 old:=to_jsonb(v)||jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(i) order by id),'[]') from public.yt_member_order_items i where order_id=p_order),'benefits',private.yt_pos_order_benefits(p_order),'received_rm',received);
 if p_revoke then benefits:=private.yt_pos_revoke_order_benefits(p_order);end if;
 if p_cancel then
  update public.yt_pos_reward_holds set state='released',updated_at=clock_timestamp() where order_id=p_order and state in ('ready','reserved');
  update public.yt_pos_preorder_holds set state='released',updated_at=clock_timestamp() where attached_order_id=p_order and state='attached';
 end if;
 for j in select value from jsonb_array_elements(r->'lines') loop
  item:=nullif(j->>'item_id','')::uuid;
  if item is null then
   insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm)
   values(p_order,(j->>'product_id')::uuid,j->>'name',(j->>'quantity')::integer,(j->>'unit_price_rm')::numeric) returning id into item;
  else
   update public.yt_member_order_items set product_id=(j->>'product_id')::uuid,item_name=j->>'name',quantity=(j->>'quantity')::integer,unit_price_rm=(j->>'unit_price_rm')::numeric,
   is_drink_at_order=(j->>'is_drink')::boolean,series_id_at_order=nullif(j->>'series_id','')::uuid where id=item;
  end if;
  keep:=array_append(keep,item);
  update public.yt_pos_item_units set retired=unit_number>(j->>'quantity')::integer,
   reward_discount_rm=case when unit_number<=(j->>'quantity')::integer then least(reward_discount_rm,(j->>'unit_price_rm')::numeric) else reward_discount_rm end where order_item_id=item;
  for idx in 1..(j->>'quantity')::integer loop insert into public.yt_pos_item_units(order_item_id,unit_number) values(item,idx) on conflict do nothing;end loop;
 end loop;
 update public.yt_member_order_items set quantity=0 where order_id=p_order and not(id=any(keep));
 update public.yt_pos_item_units u set retired=true from public.yt_member_order_items i where i.id=u.order_item_id and i.order_id=p_order and i.quantity=0;
 balance:=(r->>'net')::numeric-received;
 update public.yt_member_orders set amount_rm=(r->>'net')::numeric,table_label=nullif(btrim(coalesce(p_table,'')),''),notes=nullif(btrim(coalesce(p_note,'')),''),revision=v.revision+1,
 cancel_after_refund=p_cancel,settlement_due_since=case when v.payment_status='paid' and balance<>0 then coalesce(v.settlement_due_since,clock_timestamp()) else null end,
 status=case when p_cancel and v.payment_status='unpaid' then 'cancelled' when p_cancel and balance=0 then 'refunded' else v.status end,
 payment_status=case when p_cancel and v.payment_status='paid' and balance=0 then 'refunded' else v.payment_status end,updated_at=clock_timestamp() where id=p_order returning * into v;
 if p_cancel then update public.yt_pos_order_chits set status='cancelled' where order_id=p_order;end if;
 after_state:=to_jsonb(v)||jsonb_build_object('items',r->'lines','received_rm',received,'balance_rm',case when v.payment_status='unpaid' then v.amount_rm else balance end,'revoked_benefits',benefits);
 insert into public.yt_pos_order_revisions(order_id,revision,request_id,request_payload,reason,actor_id,before_state,after_state,revoke_benefits)
 values(p_order,v.revision,p_request,payload,p_reason,auth.uid(),old,after_state,p_revoke);
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note) values(p_order,auth.uid(),'edited','cashier',p_reason);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.owner_revision','pos_order',p_order,jsonb_build_object('revision',v.revision,'reason',p_reason,'before_amount',old->'amount_rm','after_amount',v.amount_rm,'balance_rm',balance,'revoke_benefits',p_revoke,'cancel',p_cancel));
 return after_state||jsonb_build_object('ok',true);
end $$;
create function private.yt_pos_adjustment_pay(p_order uuid,p_amount numeric,p_method text,p_note text,p_request uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_member_orders%rowtype;e public.yt_pos_payment_entries%rowtype;balance numeric;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_request is null or p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount=0 or abs(p_amount)>100000 or p_amount<>round(p_amount,2) or p_method is null or p_method not in ('foodcourt','cash','duitnow','card','bank_transfer','other') or length(btrim(coalesce(p_note,''))) not between 2 and 300 then raise exception 'invalid_adjustment_payment';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 select * into e from public.yt_pos_payment_entries where request_id=p_request;
 if found then if e.order_id<>p_order or e.amount_rm<>p_amount or e.method<>p_method or coalesce(e.note,'')<>p_note then raise exception 'request_conflict';end if;return private.yt_pos_owner_order_context(p_order);end if;
 if v.payment_status<>'paid' then raise exception 'order_not_paid';end if;
 balance:=v.amount_rm-private.yt_pos_received(p_order);
 if balance=0 or sign(balance)<>sign(p_amount) or abs(p_amount)>abs(balance) then raise exception 'adjustment_exceeds_balance';end if;
 perform pg_advisory_xact_lock(781943080);
 insert into public.yt_pos_payment_entries(order_id,request_id,method,amount_rm,kind,received_at,business_day,actor_id,note)
 values(p_order,p_request,p_method,p_amount,case when p_amount<0 then 'refund' else 'adjustment' end,clock_timestamp(),private.yt_business_day(clock_timestamp()),auth.uid(),p_note);
 balance:=v.amount_rm-private.yt_pos_received(p_order);
 update public.yt_member_orders set settlement_due_since=case when balance=0 then null else coalesce(settlement_due_since,clock_timestamp()) end,
 payment_status=case when cancel_after_refund and balance=0 then 'refunded' else payment_status end,
 status=case when cancel_after_refund and balance=0 then 'refunded' else status end,updated_at=clock_timestamp() where id=p_order;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.adjustment_payment','pos_order',p_order,jsonb_build_object('amount_rm',p_amount,'method',p_method,'note',p_note,'remaining',balance));
 return private.yt_pos_owner_order_context(p_order);
end $$;

create function public.yt_pos_owner_order_context(p_order uuid) returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_owner_order_context(p_order)$$;
create function public.yt_pos_owner_revision_preview(p_order uuid,p_items jsonb,p_cancel boolean default false) returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_owner_revision_preview(p_order,p_items,p_cancel)$$;
create function public.yt_pos_owner_revision_apply(p_order uuid,p_items jsonb,p_reason text,p_table text,p_note text,p_expected_updated timestamptz,p_request uuid,p_revoke boolean default false,p_cancel boolean default false) returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_owner_revision_apply(p_order,p_items,p_reason,p_table,p_note,p_expected_updated,p_request,p_revoke,p_cancel)$$;
create function public.yt_pos_adjustment_pay(p_order uuid,p_amount numeric,p_method text,p_note text,p_request uuid) returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_adjustment_pay(p_order,p_amount,p_method,p_note,p_request)$$;
revoke all on function private.yt_pos_received(uuid),private.yt_pos_revision_lines(uuid,jsonb,boolean),private.yt_pos_order_benefits(uuid),private.yt_pos_revoke_order_benefits(uuid) from public,anon,authenticated;
revoke all on function public.yt_pos_owner_order_context(uuid),public.yt_pos_owner_revision_preview(uuid,jsonb,boolean),public.yt_pos_owner_revision_apply(uuid,jsonb,text,text,text,timestamptz,uuid,boolean,boolean),public.yt_pos_adjustment_pay(uuid,numeric,text,text,uuid) from public,anon;
revoke all on function private.yt_pos_owner_order_context(uuid),private.yt_pos_owner_revision_preview(uuid,jsonb,boolean),private.yt_pos_owner_revision_apply(uuid,jsonb,text,text,text,timestamptz,uuid,boolean,boolean),private.yt_pos_adjustment_pay(uuid,numeric,text,text,uuid) from public,anon;
grant execute on function public.yt_pos_owner_order_context(uuid),public.yt_pos_owner_revision_preview(uuid,jsonb,boolean),public.yt_pos_owner_revision_apply(uuid,jsonb,text,text,text,timestamptz,uuid,boolean,boolean),public.yt_pos_adjustment_pay(uuid,numeric,text,text,uuid) to authenticated;
grant execute on function private.yt_pos_owner_order_context(uuid),private.yt_pos_owner_revision_preview(uuid,jsonb,boolean),private.yt_pos_owner_revision_apply(uuid,jsonb,text,text,text,timestamptz,uuid,boolean,boolean),private.yt_pos_adjustment_pay(uuid,numeric,text,text,uuid) to authenticated;
