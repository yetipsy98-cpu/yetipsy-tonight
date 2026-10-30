-- Include sequential challenges in the cashier's start / hold prep flow.
create or replace function private.yt_store_box_checkout_prep_quote(p_order uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare o public.yt_member_orders%rowtype; rows jsonb;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only'; end if;
 select * into o from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found'; end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.name,x.item_id),'[]'::jsonb) into rows from (
  select i.id item_id,i.item_name name,i.quantity,
   case when r.selection_mode='levels' then 'package' else r.mode end mode,
   r.total_units*i.quantity capacity,r.selection_mode,r.request_limit,r.components,r.unit_label,
   case
    when r.selection_mode='levels' then (
     select coalesce(jsonb_agg(jsonb_build_object(
      'key','c'||n||'-u'||g.unit_no,
      'name',split_part(split_part(c->>'name','@YTLEVEL@',2),'::',1),
      'quantity',1,
      'options',to_jsonb(string_to_array(split_part(c->>'name','::',2),'~~'))
     ) order by g.unit_no,n),'[]'::jsonb)
     from generate_series(1,i.quantity) g(unit_no)
     cross join lateral jsonb_array_elements(r.components) with ordinality j(c,n)
    )
    when jsonb_array_length(r.components)>0 then (
     select coalesce(jsonb_agg(jsonb_build_object('key',e->>'key','name',e->>'name','quantity',(e->>'quantity')::int*i.quantity) order by n),'[]'::jsonb)
     from jsonb_array_elements(r.components) with ordinality j(e,n)
    )
    else jsonb_build_array(jsonb_build_object('key','default','name',i.item_name,'quantity',r.total_units*i.quantity))
   end available
  from public.yt_member_order_items i join public.yt_store_box_product_rules r on r.product_id=i.product_id
  where i.order_id=p_order and i.quantity>0 and r.active
 ) x;
 return jsonb_build_object('order_id',p_order,'can_prepare',o.payment_status='unpaid' and o.status in('confirmed','fulfilled'),'items',rows);
end $function$;

create or replace function private.yt_store_box_cashier_request(p_box uuid,p_selections jsonb,p_request uuid,p_initial boolean default false)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare actor uuid:=auth.uid(); b public.yt_store_boxes%rowtype; sel jsonb:='[]'::jsonb;
 entry jsonb; candidate jsonb; total_qty int:=0; v_qty int; v_key text; v_name text;
 r public.yt_store_box_requests%rowtype; level_label text; option_name text; level_options text[]; first_key text;
begin
 if not (private.yt_pos_work_cashier() or private.yt_work_owner()) then raise exception 'cashier_only'; end if;
 if p_box is null or p_request is null or p_selections is null or jsonb_typeof(p_selections)<>'array' or jsonb_array_length(p_selections)<1 or jsonb_array_length(p_selections)>20 then raise exception 'invalid_store_box_selection'; end if;
 perform pg_advisory_xact_lock(781943084);
 select * into r from public.yt_store_box_requests where client_request_id=p_request for update;
 if found then
  if r.box_id<>p_box or not (r.selections @> p_selections and jsonb_array_length(r.selections)=jsonb_array_length(p_selections)) then raise exception 'request_conflict'; end if;
  return jsonb_build_object('request_id',r.id,'quantity',r.quantity,'idempotent',true);
 end if;
 select * into b from public.yt_store_boxes where id=p_box for update;
 if not found or b.status not in('unclaimed','active') or b.storage_expires_at<=clock_timestamp() then raise exception 'store_box_not_available'; end if;
 if exists(select 1 from public.yt_store_box_requests where box_id=p_box and status in('pending','accepted','preparing')) then raise exception 'store_box_request_already_active'; end if;
 if b.selection_mode='levels' then
  select c->>'key' into first_key from jsonb_array_elements(b.components) with ordinality x(c,n)
   where coalesce((c->>'served_units')::integer,0)<(c->>'total_units')::integer order by n limit 1;
  if jsonb_array_length(p_selections)<>1 or p_selections->0->>'key'<>first_key then raise exception 'store_box_level_order_required'; end if;
 end if;
 for entry in select value from jsonb_array_elements(p_selections) loop
  v_key:=nullif(btrim(entry->>'key'),'');
  if v_key is null or coalesce(entry->>'quantity','')!~'^[0-9]{1,2}$' then raise exception 'invalid_store_box_selection'; end if;
  v_qty:=(entry->>'quantity')::integer;
  if v_qty<1 then raise exception 'invalid_store_box_selection'; end if;
  if exists(select 1 from jsonb_array_elements(sel) x where x->>'key'=v_key) then raise exception 'duplicate_store_box_component'; end if;
  select value into candidate from jsonb_array_elements(b.components) where value->>'key'=v_key;
  if candidate is null or (candidate->>'total_units')::integer-(candidate->>'served_units')::integer<v_qty then raise exception 'store_box_component_unavailable'; end if;
  v_name:=candidate->>'name';
  if b.selection_mode='levels' then
   if v_qty<>1 then raise exception 'challenge_one_cup_only'; end if;
   level_label:=split_part(split_part(candidate->>'name','@YTLEVEL@',2),'::',1);
   select array_agg(btrim(x)) into level_options from unnest(string_to_array(split_part(candidate->>'name','::',2),'~~')) x;
   option_name:=btrim(coalesce(entry->>'option',''));
   if not option_name=any(coalesce(level_options,array[]::text[])) then raise exception 'invalid_store_box_selection'; end if;
   v_name:=level_label||' · '||option_name;
   sel:=sel||jsonb_build_array(jsonb_build_object('key',v_key,'name',v_name,'option',option_name,'quantity',v_qty));
  else
   sel:=sel||jsonb_build_array(jsonb_build_object('key',v_key,'name',v_name,'quantity',v_qty));
  end if;
  total_qty:=total_qty+v_qty;
 end loop;
 if total_qty<1 or total_qty>99 or total_qty>b.total_units-b.served_units then raise exception 'store_box_quantity_unavailable'; end if;
 if b.mode='challenge' and total_qty<>1 then raise exception 'challenge_one_cup_only'; end if;
 insert into public.yt_store_box_requests(box_id,customer_id,quantity,component_key,component_name,selections,client_request_id,table_label,expires_at,status,accepted_by,accepted_at)
 values(b.id,b.customer_id,total_qty,sel->0->>'key',sel->0->>'name',sel,p_request,b.table_label,clock_timestamp()+interval '8 hours','accepted',actor,clock_timestamp()) returning * into r;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,actor_id,customer_id,metadata)
 values(b.id,r.id,'drink_requested',total_qty,actor,b.customer_id,jsonb_build_object('source',case when p_initial then 'cashier_checkout' else 'cashier_direct' end,'selections',sel));
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,actor_id,customer_id,metadata)
 values(b.id,r.id,'drink_request_accepted',total_qty,actor,b.customer_id,jsonb_build_object('source','cashier_auto_accept'));
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(actor,'store_box.cashier_prep','store_box',b.id,jsonb_build_object('request_id',r.id,'quantity',total_qty,'initial',p_initial,'box_number',b.box_number));
 return jsonb_build_object('request_id',r.id,'quantity',total_qty,'selections',sel,'idempotent',false);
end $function$;
