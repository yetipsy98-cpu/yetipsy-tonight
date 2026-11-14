-- Append-only editing for accepted unpaid tabs. Old item IDs, offers and payments stay intact.
create or replace function private.yt_pos_append(p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();o public.yt_member_orders%rowtype;p public.yt_shop_products%rowtype;
 req uuid;payload jsonb;prior jsonb;lines jsonb:='[]';line jsonb;new_item_id uuid;qty integer;total_qty integer:=0;delta numeric:=0;note text;new_notes text;needs_work boolean:=false;new_status text;result jsonb;day date;age_reason boolean;
begin
 if actor is null or not (private.yt_work_owner() or private.yt_pos_work_cashier()) then raise exception 'cashier_only';end if;
 if p_action is null or p_action not in('context','save') then raise exception 'invalid_action';end if;
 select * into o from public.yt_member_orders where id=(p_data->>'order_id')::uuid and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 if p_action='save' then
  req:=(p_data->>'request_id')::uuid;if req is null then raise exception 'invalid_order_append';end if;
  payload:=p_data||jsonb_build_object('actor',actor);
  select metadata into prior from public.audit_logs where action='pos.order_append' and entity_id=o.id and metadata->>'request_id'=req::text;
  if found then if prior->'payload' is distinct from payload then raise exception 'request_conflict';end if;return prior->'result'||jsonb_build_object('idempotent',true);end if;
 end if;
 if o.payment_status<>'unpaid' or o.status not in('confirmed','fulfilled') or o.cancel_after_refund then raise exception 'append_unpaid_only';end if;
 if o.backdate_approval_status='pending' then raise exception 'backdate_approval_pending';end if;
 if exists(select 1 from public.yt_pos_duitnow_proofs where order_id=o.id and status='pending') then raise exception 'append_payment_review_pending';end if;
 age_reason:=o.created_at<=clock_timestamp()-interval '72 hours';
 if age_reason and not private.yt_work_owner() then raise exception 'aged_order_owner_required';end if;
 if p_action='context' then
  return jsonb_build_object('id',o.id,'order_no',o.order_no,'table_label',o.table_label,'amount_rm',o.amount_rm,'updated_at',o.updated_at,
   'business_day',coalesce(o.pos_business_day,private.yt_business_day(o.created_at)),'requires_reason',age_reason,'products',private.yt_pos_catalog());
 end if;
 if nullif(p_data->>'expected_updated','')::timestamptz is distinct from o.updated_at then raise exception 'order_changed_reload';end if;
 note:=btrim(coalesce(p_data->>'note',''));
 if char_length(note)>160 or (age_reason and char_length(note)<2) then raise exception 'append_note_invalid';end if;
 new_notes:=case when note='' then o.notes else concat_ws(E'\n',nullif(o.notes,''),'加单备注：'||note) end;
 if char_length(coalesce(new_notes,''))>600 then raise exception 'append_note_invalid';end if;
 if p_data->'items' is null or jsonb_typeof(p_data->'items')<>'array' or jsonb_array_length(p_data->'items') not between 1 and 30 then raise exception 'invalid_order_append';end if;
 for line in select value from jsonb_array_elements(p_data->'items') loop
  if coalesce(line->>'quantity','')!~'^[0-9]{1,2}$' then raise exception 'invalid_quantity';end if;
  qty:=(line->>'quantity')::integer;if qty not between 1 and 20 then raise exception 'invalid_quantity';end if;
  select * into p from public.yt_shop_products where id=(line->>'product_id')::uuid and active for share;
  if not found then raise exception 'product_unavailable';end if;
  if nullif(line->>'expected_price','')::numeric is distinct from p.price_rm then raise exception 'append_price_changed';end if;
  delta:=delta+p.price_rm*qty;total_qty:=total_qty+qty;
  if p.price_rm<0 or total_qty>80 or o.amount_rm+delta>100000 then raise exception 'order_too_large';end if;
  needs_work:=needs_work or not exists(select 1 from public.yt_store_box_product_rules where product_id=p.id and active);
  lines:=lines||jsonb_build_array(jsonb_build_object('product_id',p.id,'name',p.title,'quantity',qty,'price',p.price_rm,'is_drink',p.is_drink));
 end loop;
 if (select coalesce(sum(quantity),0) from public.yt_member_order_items where order_id=o.id and item_name not in('Freeflow Male','Freeflow Female'))+total_qty>80 then raise exception 'order_too_large';end if;
 perform pg_advisory_xact_lock(781943080);
 -- An order served as a whole may not have item flags set. Mark only pre-existing rows.
 if o.status='fulfilled' then update public.yt_member_order_items set fulfilled=true,fulfilled_at=coalesce(fulfilled_at,o.fulfilled_at,clock_timestamp()),fulfilled_by=coalesce(fulfilled_by,o.fulfilled_by,actor) where order_id=o.id and not fulfilled;end if;
 for line in select value from jsonb_array_elements(lines) loop
  insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm,is_drink_at_order)
   values(o.id,(line->>'product_id')::uuid,line->>'name',(line->>'quantity')::integer,(line->>'price')::numeric,(line->>'is_drink')::boolean) returning id into new_item_id;
  insert into public.yt_pos_item_units(order_item_id,unit_number) select new_item_id,n from generate_series(1,(line->>'quantity')::integer)n;
 end loop;
 needs_work:=needs_work and o.backdate_approval_status is distinct from 'approved';
 new_status:=case when o.backdate_approval_status='approved' then o.status when needs_work or o.status='confirmed' then 'confirmed' else 'fulfilled' end;
 update public.yt_member_orders set amount_rm=amount_rm+delta,notes=new_notes,status=new_status,updated_at=clock_timestamp(),
  fulfilled_at=case when new_status='confirmed' then null else fulfilled_at end,fulfilled_by=case when new_status='confirmed' then null else fulfilled_by end where id=o.id;
 if needs_work then insert into public.yt_pos_order_chits(order_id) values(o.id) on conflict(order_id) do update set status='queued',issued_at=clock_timestamp(),printed_at=null,printed_by=null;end if;
 day:=coalesce(o.pos_business_day,private.yt_business_day(o.created_at));
 update public.yt_pos_day_closings set state='reopened',reopened_at=clock_timestamp(),reopened_by=actor,reopen_reason='挂单加单：'||o.order_no where business_day=day and state='closed';
 result:=jsonb_build_object('order_id',o.id,'order_no',o.order_no,'added_quantity',total_qty,'added_rm',delta,'amount_rm',o.amount_rm+delta,'queued',needs_work,'status',new_status);
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note) values(o.id,actor,'edited','cashier','挂单追加 '||total_qty||' 件商品；RM'||delta||case when note<>'' then '；'||note else '' end);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'pos.order_append','pos_order',o.id,jsonb_build_object('request_id',req,'payload',payload,'result',result,'before_amount',o.amount_rm,'lines',lines,'business_day',day));
 return result;
end$$;
revoke all on function private.yt_pos_append(text,jsonb) from public,anon,authenticated;
grant execute on function private.yt_pos_append(text,jsonb) to authenticated;
create or replace function public.yt_pos_append(p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_append(p_action,p_data)$$;
revoke all on function public.yt_pos_append(text,jsonb) from public,anon,authenticated;
grant execute on function public.yt_pos_append(text,jsonb) to authenticated;
create unique index if not exists yt_pos_append_request on public.audit_logs(entity_id,(metadata->>'request_id')) where action='pos.order_append';

CREATE OR REPLACE FUNCTION private.yt_freeflow_pax(actor uuid, p_action text, data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare o public.yt_member_orders%rowtype;s public.yt_ambassador_pos_sales%rowtype;g public.yt_freeflow_sessions%rowtype;
 male integer;female integer;delta numeric;req uuid;prior jsonb;payload jsonb;owed numeric;line_id uuid;business date;
begin
 if actor is null or actor is distinct from auth.uid() or not (private.yt_pos_work_cashier() or private.yt_work_owner()) then raise exception 'cashier_only';end if;
 if p_action not in('pax_preview','pax_add','collect_delta') then raise exception 'invalid_freeflow_action';end if;
 perform pg_advisory_xact_lock(hashtextextended('freeflow-session:'||(data->>'order_id'),0));
 select * into g from public.yt_freeflow_sessions where order_id=(data->>'order_id')::uuid for update;
 select * into o from public.yt_member_orders where id=(data->>'order_id')::uuid and source='future_pos' for update;
 select * into s from public.yt_ambassador_pos_sales where order_id=o.id for update;
 if s.order_id is null or o.status in('pending','cancelled','refunded') or o.payment_status not in('unpaid','paid') or o.cancel_after_refund then raise exception 'freeflow_order_invalid';end if;
 if p_action='collect_delta' then
  if o.payment_status<>'paid' or coalesce((data->>'confirmed')::boolean,false) is not true then raise exception 'actual_payment_required';end if;
  return private.yt_pos_adjustment_pay(o.id,(data->>'amount')::numeric,data->>'method',coalesce(nullif(btrim(data->>'note'),''),'FreeFlow 加人数补差价'),(data->>'request_id')::uuid);
 end if;
 if p_action='pax_add' then
  male:=(data->>'male')::integer;female:=(data->>'female')::integer;req:=(data->>'request_id')::uuid;
  if male is null or female is null or male<0 or female<0 or male+female<1 or male+female>500 or req is null then raise exception 'invalid_guest_count';end if;
  payload:=data||jsonb_build_object('actor',actor);
  select metadata into prior from public.audit_logs where action='freeflow.pax_add' and entity_id=o.id and metadata->>'request_id'=req::text;
  if found then
   if prior->'payload' is distinct from payload then raise exception 'request_conflict';end if;
   return jsonb_build_object('order_id',o.id,'idempotent',true);
  end if;
  if g.status='closed' then raise exception 'freeflow_unavailable';end if;
  if s.male_count+s.female_count+male+female>500 then raise exception 'invalid_guest_count';end if;
  if (data->>'expected_male')::integer is distinct from s.male_count or (data->>'expected_female')::integer is distinct from s.female_count then raise exception 'freeflow_pax_changed';end if;
  if o.amount_rm<>round(s.male_count*s.male_price+s.female_count*s.female_price,2)+(select coalesce(sum(quantity*unit_price_rm),0) from public.yt_member_order_items where order_id=o.id and item_name not in('Freeflow Male','Freeflow Female')) then raise exception 'freeflow_order_changed';end if;
  delta:=round(male*s.male_price+female*s.female_price,2);
  if delta<=0 or o.amount_rm+delta>100000 then raise exception 'order_too_large';end if;
  perform pg_advisory_xact_lock(781943080);
  if male>0 then
   select id into line_id from public.yt_member_order_items where order_id=o.id and item_name='Freeflow Male' and unit_price_rm=s.male_price order by id limit 1 for update;
   if found then update public.yt_member_order_items set quantity=quantity+male where id=line_id;
   else insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm,is_drink_at_order) values(o.id,null,'Freeflow Male',male,s.male_price,false);end if;
  end if;
  if female>0 then
   select id into line_id from public.yt_member_order_items where order_id=o.id and item_name='Freeflow Female' and unit_price_rm=s.female_price order by id limit 1 for update;
   if found then update public.yt_member_order_items set quantity=quantity+female where id=line_id;
   else insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm,is_drink_at_order) values(o.id,null,'Freeflow Female',female,s.female_price,false);end if;
  end if;
  update public.yt_ambassador_pos_sales set male_count=male_count+male,female_count=female_count+female where order_id=o.id;
  update public.yt_member_orders set amount_rm=amount_rm+delta,settlement_due_since=case when payment_status='paid' then coalesce(settlement_due_since,clock_timestamp()) else settlement_due_since end,updated_at=clock_timestamp() where id=o.id;
  update public.yt_freeflow_sessions set capacity=s.male_count+s.female_count+male+female where order_id=o.id;
  business:=coalesce(o.pos_business_day,s.business_day);
  update public.yt_pos_day_closings set state='reopened',reopened_at=clock_timestamp(),reopened_by=actor,reopen_reason='FreeFlow 加人数：'||o.order_no where business_day=business and state='closed';
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'freeflow.pax_add','pos_order',o.id,
   jsonb_build_object('request_id',req,'payload',payload,'before_male',s.male_count,'before_female',s.female_count,'male',male,'female',female,'delta_rm',delta,'business_day',business,'effective_immediately',true));
  insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note) values(o.id,actor,'edited','cashier','FreeFlow 加人数：男 +'||male||' / 女 +'||female||'；差价 RM'||delta||' 可稍后支付');
  return jsonb_build_object('order_id',o.id,'added',male+female,'delta_rm',delta,'effective',true);
 end if;
 owed:=case when o.payment_status='paid' then o.amount_rm-private.yt_pos_received(o.id) else o.amount_rm end;
 return jsonb_build_object('order_id',o.id,'order_no',o.order_no,'male',s.male_count,'female',s.female_count,'male_price',s.male_price,'female_price',s.female_price,
 'amount_rm',o.amount_rm,'received_rm',private.yt_pos_received(o.id),'balance_rm',owed,'payment_status',o.payment_status,'capacity',s.male_count+s.female_count,'can_add',coalesce(g.status<>'closed',true));
end$function$;
CREATE OR REPLACE FUNCTION private.yt_pos_adjustment_pay(p_order uuid, p_amount numeric, p_method text, p_note text, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_member_orders%rowtype;e public.yt_pos_payment_entries%rowtype;balance numeric;entry_method text;ff_received numeric;
begin
 if not private.yt_work_owner() and not (private.yt_pos_work_cashier() and p_amount>0 and exists(select 1 from public.yt_ambassador_pos_sales where order_id=p_order) and exists(select 1 from public.audit_logs where action='freeflow.pax_add' and entity_id=p_order)) then raise exception 'owner_only';end if;
 if p_request is null or p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount=0 or abs(p_amount)>100000 or p_amount<>round(p_amount,2) or p_method is null or p_method not in ('foodcourt','cash','duitnow','card','bank_transfer','other') or length(btrim(coalesce(p_note,''))) not between 2 and 300 then raise exception 'invalid_adjustment_payment';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 entry_method:=case when exists(select 1 from public.yt_ambassador_pos_sales where order_id=p_order) then 'AB_'||case p_method when 'cash' then 'Cash' when 'duitnow' then 'DuitNow' when 'card' then 'Card' when 'bank_transfer' then 'Bank_Transfer' when 'foodcourt' then 'Foodcourt' else 'Other' end else p_method end;
 select * into e from public.yt_pos_payment_entries where request_id=p_request;
 if found then if e.order_id<>p_order or e.amount_rm<>p_amount or (e.method<>entry_method and e.method<>p_method) or coalesce(e.note,'')<>p_note then raise exception 'request_conflict';end if;return private.yt_pos_owner_order_context(p_order);end if;
 if v.payment_status<>'paid' then raise exception 'order_not_paid';end if;
 balance:=v.amount_rm-private.yt_pos_received(p_order);
 if balance=0 or sign(balance)<>sign(p_amount) or abs(p_amount)>abs(balance) then raise exception 'adjustment_exceeds_balance';end if;
 perform pg_advisory_xact_lock(781943080);
 insert into public.yt_pos_payment_entries(order_id,request_id,method,amount_rm,kind,received_at,business_day,actor_id,note)
 values(p_order,p_request,entry_method,p_amount,case when p_amount<0 then 'refund' else 'adjustment' end,clock_timestamp(),coalesce(v.pos_business_day,(select sale.business_day from public.yt_pos_payment_entries sale where sale.order_id=v.id and sale.kind='sale' order by sale.received_at,sale.id limit 1),private.yt_business_day(v.created_at)),auth.uid(),p_note);
 balance:=v.amount_rm-private.yt_pos_received(p_order);
 update public.yt_member_orders set settlement_due_since=case when balance=0 then null else coalesce(settlement_due_since,clock_timestamp()) end,
 payment_status=case when cancel_after_refund and balance=0 then 'refunded' else payment_status end,
 status=case when cancel_after_refund and balance=0 then 'refunded' else status end,updated_at=clock_timestamp() where id=p_order;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.adjustment_payment','pos_order',p_order,jsonb_build_object('amount_rm',p_amount,'method',p_method,'note',p_note,'remaining',balance));
 if p_amount>0 and exists(select 1 from public.yt_ambassador_pos_sales where order_id=p_order) then
  ff_received:=greatest(0,private.yt_pos_received(p_order)-(select coalesce(sum(quantity*unit_price_rm),0) from public.yt_member_order_items where order_id=p_order and item_name not in('Freeflow Male','Freeflow Female')));
  update public.yt_ambassador_checkins c set male_count=s.male_count,female_count=s.female_count,
   sales=least(s.male_count*s.male_price+s.female_count*s.female_price,ff_received),commission_amount=round(least(s.male_count*s.male_price+s.female_count*s.female_price,ff_received)*s.commission_rate/100,2)
   from public.yt_ambassador_pos_sales s where s.order_id=p_order and c.request_id=p_order;
  insert into public.yt_ambassador_ledger(ambassador_id,checkin_id,entry_type,amount,created_by,business_day,note)
   select c.ambassador_id,c.id,'commission',c.commission_amount,auth.uid(),c.business_day,'FreeFlow 加人数已收款佣金' from public.yt_ambassador_checkins c
   where c.request_id=p_order and c.commission_amount>0 on conflict(checkin_id) do update set amount=excluded.amount;
 end if;
 return private.yt_pos_owner_order_context(p_order);
end $function$;
