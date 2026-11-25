-- Owner-only reconciliation with a single, atomic multi-product supplement.
create function private.yt_foodcourt_supplement_cart(p_data jsonb,p_day date,p_request uuid,p_note text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare lines jsonb;line jsonb;clean jsonb:='[]';product public.yt_shop_products%rowtype;
 seen uuid[]:='{}';qty integer;price numeric;total numeric:=0;ff_total numeric:=0;
 oid uuid;ino uuid;number text;stamp timestamptz:=clock_timestamp();payment text;
begin
 if auth.uid() is null or not coalesce(private.yt_work_owner(),false) then raise exception 'owner_only';end if;
 -- An older browser may retry its already-frozen single-product payload.
 lines:=case when p_data ? 'items' then p_data->'items' else jsonb_build_array(p_data) end;
 if jsonb_typeof(lines) is distinct from 'array' or jsonb_array_length(lines) not between 1 and 30 then raise exception 'invalid_order_line';end if;
 for line in select value from jsonb_array_elements(lines) loop
  if coalesce(line->>'quantity','') !~ '^[0-9]{1,3}$' or coalesce(line->>'unit_price_rm','') !~ '^[0-9]{1,4}(\.[0-9]{1,2})?$' then raise exception 'invalid_order_line';end if;
  qty:=(line->>'quantity')::integer;price:=(line->>'unit_price_rm')::numeric;
  if qty not between 1 and 500 or price not between 0.01 and 5000 then raise exception 'invalid_order_line';end if;
  select * into product from public.yt_shop_products where id=(line->>'product_id')::uuid and active for share;
  if not found or product.price_rm is null then raise exception 'product_unavailable';end if;
  if product.id=any(seen) then raise exception 'duplicate_product';end if;seen:=array_append(seen,product.id);
  if nullif(line->>'expected_price','')::numeric is distinct from product.price_rm then raise exception 'product_price_changed';end if;
  total:=total+qty*price;if total>100000 then raise exception 'order_too_large';end if;
  if exists(select 1 from public.yt_freeflow_packages p where p.product_id=product.id) then ff_total:=ff_total+qty*price;end if;
  clean:=clean||jsonb_build_array(jsonb_build_object('product_id',product.id,'name',product.title,'quantity',qty,'unit_price_rm',price));
 end loop;
 number:='YT'||to_char(stamp at time zone 'Asia/Kuala_Lumpur','YYMMDD')||'-'||lpad(nextval('public.yt_pos_order_serial'::regclass)::text,6,'0');
 payment:=case when ff_total=total then 'Freeflow-Foodcourt' else 'foodcourt' end;
 insert into public.yt_member_orders(source,status,order_no,notes,payment_status,payment_method,created_by,paid_by,paid_at,fulfilled_at,fulfilled_by,client_request_id,amount_rm,pos_business_day,backdate_approval_status,checkout_mode)
  values('future_pos','fulfilled',number,p_note,'paid',payment,auth.uid(),auth.uid(),stamp,stamp,auth.uid(),p_request,total,p_day,'not_required','pay_now') returning id into oid;
 insert into private.yt_foodcourt_history_orders(order_id,created_by) values(oid,auth.uid());
 for line in select value from jsonb_array_elements(clean) loop
  insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm,fulfilled,fulfilled_at,fulfilled_by)
   values(oid,(line->>'product_id')::uuid,line->>'name',(line->>'quantity')::integer,(line->>'unit_price_rm')::numeric,true,stamp,auth.uid()) returning id into ino;
  insert into public.yt_pos_item_units(order_item_id,unit_number,benefit_status) select ino,s,'void' from generate_series(1,(line->>'quantity')::integer)s;
 end loop;
 -- One physical receipt; the existing partition trigger allocates its categories.
 insert into public.yt_pos_payment_entries(order_id,request_id,method,amount_rm,kind,received_at,business_day,actor_id,note)
  values(oid,md5(p_request::text||':payment')::uuid,'foodcourt',total,'sale',stamp,p_day,auth.uid(),p_note);
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note) values(oid,auth.uid(),'created','cashier',p_note);
 return jsonb_build_object('order_id',oid,'order_no',number,'amount_rm',total,'settled_rm',total,'day',p_day,'items',clean);
end$$;
revoke all on function private.yt_foodcourt_supplement_cart(jsonb,date,uuid,text) from public,anon,authenticated;

-- Historical FreeFlow sales have no access session, but retain their sales labels.
-- Every extra branch is limited to orders created by the reconciliation tool.
do $$declare def text;needle text;replacement text;begin
 def:=pg_get_functiondef('private.yt_ff_payment_partition()'::regprocedure);
 needle:='if tg_op=''UPDATE'' then';
 if position(needle in def)=0 then raise exception 'partition_update_definition_changed';end if;
 def:=replace(def,needle,needle||' if exists(select 1 from private.yt_foodcourt_history_orders h where h.order_id=new.order_id) then return new;end if;');
 needle:='not exists(select 1 from public.yt_freeflow_sessions where order_id=new.order_id and anchor_item_id is not null)';
 if position(needle in def)=0 then raise exception 'partition_guard_definition_changed';end if;
 def:=replace(def,needle,'(not exists(select 1 from public.yt_freeflow_sessions where order_id=new.order_id and anchor_item_id is not null) and not exists(select 1 from private.yt_foodcourt_history_orders h join public.yt_member_order_items i on i.order_id=h.order_id join public.yt_freeflow_packages p on p.product_id=i.product_id where h.order_id=new.order_id))');
 needle:='from public.yt_freeflow_sale_lines l join public.yt_member_order_items i on i.id=l.order_item_id where i.order_id=new.order_id;';
 if position(needle in def)=0 then raise exception 'partition_target_definition_changed';end if;
 replacement:='from public.yt_member_order_items i where i.order_id=new.order_id and (exists(select 1 from public.yt_freeflow_sale_lines l where l.order_item_id=i.id) or (exists(select 1 from private.yt_foodcourt_history_orders h where h.order_id=i.order_id) and exists(select 1 from public.yt_freeflow_packages p where p.product_id=i.product_id)));';
 execute replace(def,needle,replacement);
 def:=pg_get_functiondef('private.yt_ff_item_method(uuid,text)'::regprocedure);
 needle:='exists(select 1 from public.yt_freeflow_sale_lines l where l.order_item_id=i.id)';
 if position(needle in def)=0 then raise exception 'item_method_definition_changed';end if;
 execute replace(def,needle,'(exists(select 1 from public.yt_freeflow_sale_lines l where l.order_item_id=i.id) or (exists(select 1 from private.yt_foodcourt_history_orders h where h.order_id=i.order_id) and exists(select 1 from public.yt_freeflow_packages p where p.product_id=i.product_id)))');
end$$;

-- A correction can move value between FreeFlow and regular goods without changing
-- cash received. Reclassify positive receipt allocations, never invent a refund or
-- an extra receipt for a zero-net change. Immutable revision snapshots remain intact.
create function private.yt_foodcourt_reclassify(p_order uuid,p_request uuid) returns void
language plpgsql security definer set search_path='' as $$
declare target numeric;received numeric;transfer numeric;take numeric;to_ff boolean;
 e public.yt_pos_payment_entries%rowtype;m text;
begin
 if not coalesce(private.yt_work_owner(),false) then raise exception 'owner_only';end if;
 if not exists(select 1 from private.yt_foodcourt_history_orders h where h.order_id=p_order) then return;end if;
 select least(o.amount_rm,coalesce((select sum(greatest(0,i.quantity*i.unit_price_rm-coalesce((select sum(u.reward_discount_rm) from public.yt_pos_item_units u where u.order_item_id=i.id and not u.retired),0))) from public.yt_member_order_items i join public.yt_freeflow_packages p on p.product_id=i.product_id where i.order_id=o.id),0)) into target from public.yt_member_orders o where o.id=p_order;
 select coalesce(sum(amount_rm),0) into received from public.yt_pos_payment_entries where order_id=p_order and method like 'Freeflow-%';
 transfer:=target-received;if transfer=0 then return;end if;to_ff:=transfer>0;transfer:=abs(transfer);
 for e in select * from public.yt_pos_payment_entries where order_id=p_order and amount_rm>0 and (method like 'Freeflow-%')<>to_ff order by received_at desc,id desc for update loop
  take:=least(transfer,e.amount_rm);m:=lower(replace(e.method,'Freeflow-',''));
  if to_ff then m:='Freeflow-'||case m when 'cash' then 'Cash' when 'duitnow' then 'DuitNow' when 'card' then 'Card' when 'foodcourt' then 'Foodcourt' when 'bank_transfer' then 'Bank_Transfer' else 'Other' end;end if;
  if take=e.amount_rm then update public.yt_pos_payment_entries set method=m where id=e.id;
  else
   update public.yt_pos_payment_entries set amount_rm=amount_rm-take where id=e.id;
   insert into public.yt_pos_payment_entries(order_id,request_id,method,amount_rm,kind,received_at,business_day,actor_id,note,freeflow_partitioned)
    values(e.order_id,md5(p_request::text||':allocation:'||e.id::text)::uuid,m,take,e.kind,e.received_at,e.business_day,e.actor_id,e.note,true);
  end if;
  transfer:=transfer-take;exit when transfer=0;
 end loop;
 if transfer<>0 then raise exception 'allocation_balance_mismatch';end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'foodcourt.payment_allocation','pos_order',p_order,jsonb_build_object('request_id',p_request,'before_freeflow_rm',received,'after_freeflow_rm',target,'cash_unchanged',true));
end$$;
revoke all on function private.yt_foodcourt_reclassify(uuid,uuid) from public,anon,authenticated;

do $$declare def text;needle text;start_at integer;end_at integer;begin
 def:=pg_get_functiondef('private.yt_foodcourt_reconcile(text,jsonb)'::regprocedure);
 needle:='if not coalesce(private.yt_pos_work_cashier(),false) then raise exception ''cashier_only'';end if;';
 if position(needle in def)=0 then raise exception 'reconcile_role_definition_changed';end if;
 def:=replace(def,needle,'if auth.uid() is null or not coalesce(private.yt_work_owner(),false) then raise exception ''owner_only'';end if;');
 needle:='''name'',p.title,''price_rm'',p.price_rm';
 if position(needle in def)=0 then raise exception 'reconcile_catalog_definition_changed';end if;
 def:=replace(def,needle,'''name'',p.title,''price_rm'',p.price_rm,''category'',coalesce(nullif(p.category,''''),''其他'')');
 start_at:=position(' if p_action=''supplement'' then' in def);
 end_at:=position('  perform 1 from public.yt_freeflow_sessions where yt_freeflow_sessions.order_id=v_order' in def);
 if start_at=0 or end_at<=start_at then raise exception 'reconcile_supplement_definition_changed';end if;
 def:=substring(def from 1 for start_at-1)||' if p_action=''supplement'' then
  result:=private.yt_foodcourt_supplement_cart(p_data,d,rid,reason);
  v_order:=(result->>''order_id'')::uuid;
 else
'||substring(def from end_at);
 needle:='insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),''foodcourt.''||p_action';
 if position(needle in def)=0 then raise exception 'reconcile_audit_definition_changed';end if;
 def:=replace(def,needle,'perform private.yt_foodcourt_reclassify(v_order,rid);'||chr(10)||' '||needle);
 execute def;
end$$;
