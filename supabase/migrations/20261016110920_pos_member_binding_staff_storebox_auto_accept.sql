-- Let every POS staff role attach a customer before checkout; points remain issued by the existing binding trigger only when the order is paid and eligible.
CREATE OR REPLACE FUNCTION private.yt_play_bind_member(p_order uuid, p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_customer uuid;begin
 if not (private.yt_pos_work_staff() or private.yt_work_owner()) then raise exception 'cashier_only';end if;
 select customer_id into v_customer from public.yt_play_member_tokens
 where token_hash=private.yt_play_hash(p_token) and expires_at>clock_timestamp();
 if v_customer is null then raise exception 'member_code_expired';end if;
 return private.yt_play_finalize_binding(p_order,v_customer,'member_qr');
end $function$;


-- Requests initiated by Cashier or Owner are already accepted and can go straight to KDS.
CREATE OR REPLACE FUNCTION private.yt_store_box_cashier_request(p_box uuid, p_selections jsonb, p_request uuid, p_initial boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid:=auth.uid();b public.yt_store_boxes%rowtype;sel jsonb:='[]'::jsonb;
 entry jsonb;candidate jsonb;total_qty int:=0;v_qty int;v_key text;v_name text;
 r public.yt_store_box_requests%rowtype;
begin
 if not (private.yt_pos_work_cashier() or private.yt_work_owner()) then raise exception 'cashier_only';end if;
 if p_box is null or p_request is null or p_selections is null or jsonb_typeof(p_selections)<>'array'
  or jsonb_array_length(p_selections)<1 or jsonb_array_length(p_selections)>20 then raise exception 'invalid_store_box_selection';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into r from public.yt_store_box_requests where client_request_id=p_request for update;
 if found then
  if r.box_id<>p_box or not (r.selections @> p_selections and jsonb_array_length(r.selections)=jsonb_array_length(p_selections)) then raise exception 'request_conflict';end if;
  return jsonb_build_object('request_id',r.id,'quantity',r.quantity,'idempotent',true);
 end if;
 select * into b from public.yt_store_boxes where id=p_box for update;
 if not found or b.status not in('unclaimed','active') or b.storage_expires_at<=clock_timestamp()
  or (p_initial and (not b.cashier_managed or b.customer_id is not null))
  or (not p_initial and not (b.customer_id is not null and b.status='active' or b.cashier_managed and b.customer_id is null))
 then raise exception 'store_box_not_available';end if;
 if exists(select 1 from public.yt_store_box_requests where box_id=p_box and status in('pending','accepted','preparing')) then raise exception 'store_box_request_already_active';end if;
 for entry in select value from jsonb_array_elements(p_selections) loop
  v_key:=nullif(btrim(entry->>'key'),'');
  if v_key is null or coalesce(entry->>'quantity','')!~'^[0-9]{1,2}$' then raise exception 'invalid_store_box_selection';end if;
  v_qty:=(entry->>'quantity')::integer;
  if v_qty<1 then raise exception 'invalid_store_box_selection';end if;
  if exists(select 1 from jsonb_array_elements(sel) x where x->>'key'=v_key) then raise exception 'duplicate_store_box_component';end if;
  select value into candidate from jsonb_array_elements(b.components) where value->>'key'=v_key;
  if candidate is null or (candidate->>'total_units')::integer-(candidate->>'served_units')::integer<v_qty then raise exception 'store_box_component_unavailable';end if;
  v_name:=candidate->>'name';sel:=sel||jsonb_build_array(jsonb_build_object('key',v_key,'name',v_name,'quantity',v_qty));total_qty:=total_qty+v_qty;
 end loop;
 if total_qty<1 or total_qty>99 or total_qty>b.total_units-b.served_units then raise exception 'store_box_quantity_unavailable';end if;
 if b.mode='challenge' and total_qty<>1 then raise exception 'challenge_one_cup_only';end if;
 insert into public.yt_store_box_requests(box_id,customer_id,quantity,component_key,component_name,selections,client_request_id,table_label,expires_at,status,accepted_by,accepted_at)
 values(b.id,b.customer_id,total_qty,sel->0->>'key',sel->0->>'name',sel,p_request,b.table_label,clock_timestamp()+interval '8 hours','accepted',actor,clock_timestamp())
 returning * into r;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,actor_id,customer_id,metadata)
 values(b.id,r.id,'drink_requested',total_qty,actor,b.customer_id,jsonb_build_object('source',case when p_initial then 'cashier_checkout' else 'cashier_direct' end,'selections',sel));
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,actor_id,customer_id,metadata)
 values(b.id,r.id,'drink_request_accepted',total_qty,actor,b.customer_id,jsonb_build_object('source','cashier_auto_accept'));
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(actor,'store_box.cashier_prep','store_box',b.id,jsonb_build_object('request_id',r.id,'quantity',total_qty,'initial',p_initial,'box_number',b.box_number));
 return jsonb_build_object('request_id',r.id,'quantity',total_qty,'selections',sel,'idempotent',false);
end $function$
