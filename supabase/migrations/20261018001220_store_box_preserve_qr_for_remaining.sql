-- Preserve an active claim QR while any Store Box units remain.
-- Only close the QR after the last serving is confirmed in KDS.
create or replace function private.yt_store_box_cashier_direct_issue(p_order_item uuid,p_selections jsonb,p_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 actor uuid:=auth.uid();i public.yt_member_order_items%rowtype;o public.yt_member_orders%rowtype;
 rule_row public.yt_store_box_product_rules%rowtype;b public.yt_store_boxes%rowtype;
 existing_request public.yt_store_box_requests%rowtype;box_components jsonb;source_item uuid;result jsonb;
begin
 if not (private.yt_pos_work_cashier() or private.yt_work_owner()) then raise exception 'cashier_only';end if;
 if p_order_item is null or p_request is null or p_selections is null or jsonb_typeof(p_selections)<>'array'
  or jsonb_array_length(p_selections)<1 or jsonb_array_length(p_selections)>20 then raise exception 'invalid_store_box_selection';end if;
 perform pg_advisory_xact_lock(781943084);

 select * into existing_request from public.yt_store_box_requests where client_request_id=p_request for update;
 if found then
  select source_order_item_id into source_item from public.yt_store_boxes where id=existing_request.box_id;
  if source_item<>p_order_item or not (existing_request.selections @> p_selections and jsonb_array_length(existing_request.selections)=jsonb_array_length(p_selections)) then raise exception 'request_conflict';end if;
  return jsonb_build_object('request_id',existing_request.id,'quantity',existing_request.quantity,'selections',existing_request.selections,'idempotent',true);
 end if;

 select * into i from public.yt_member_order_items where id=p_order_item;
 if not found then raise exception 'order_item_not_found';end if;
 select * into o from public.yt_member_orders where id=i.order_id and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 if o.status<>'fulfilled' or o.payment_status<>'paid' or o.paid_at is null then raise exception 'store_box_after_payment_only';end if;
 if o.settlement_due_since is not null or o.cancel_after_refund then raise exception 'order_payment_adjustment_pending';end if;
 select * into rule_row from public.yt_store_box_product_rules where product_id=i.product_id and active;
 if not found then raise exception 'store_box_product_not_configured';end if;
 if jsonb_array_length(rule_row.components)>0 then
  select jsonb_agg(jsonb_build_object('key',x->>'key','name',x->>'name','total_units',(x->>'quantity')::integer*i.quantity,'served_units',0) order by n)
   into box_components from jsonb_array_elements(rule_row.components) with ordinality e(x,n);
 else
  box_components:=jsonb_build_array(jsonb_build_object('key','default','name',i.item_name,'total_units',i.quantity*rule_row.total_units,'served_units',0));
 end if;

 insert into public.yt_store_boxes(source_order_id,source_order_item_id,product_id,customer_id,name,mode,unit_label,total_units,request_limit,expiry_days,selection_mode,components,completion_reward_id,game_pass_enabled,table_label,created_by)
 values(o.id,i.id,i.product_id,o.customer_id,i.item_name,rule_row.mode,rule_row.unit_label,i.quantity*rule_row.total_units,rule_row.request_limit,rule_row.expiry_days,rule_row.selection_mode,box_components,null,false,o.table_label,actor)
 on conflict(source_order_item_id) do nothing;
 select * into b from public.yt_store_boxes where source_order_item_id=i.id for update;
 if b.status not in ('unclaimed','active') or b.storage_expires_at is null or b.storage_expires_at<=clock_timestamp() then raise exception 'store_box_not_available';end if;

 result:=private.yt_store_box_cashier_request(b.id,p_selections,p_request,false);
 return result;
end $$;

create or replace function private.yt_store_box_request_action(p_request uuid,p_action text,p_completed_delta integer default 0,p_reason text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();r public.yt_store_box_requests%rowtype;b public.yt_store_boxes%rowtype;next_status text;
 request_selections jsonb;new_components jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_request is null or p_action not in ('accept','prepare','serve','cancel') or length(coalesce(p_reason,''))>200 then raise exception 'invalid_store_box_action';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into r from public.yt_store_box_requests where id=p_request for update;
 if not found then raise exception 'store_box_request_not_found';end if;
 select * into b from public.yt_store_boxes where id=r.box_id for update;
 if p_action='accept' then
  if r.status='accepted' and r.accepted_by=actor then return to_jsonb(r);end if;
  if r.status<>'pending' or r.expires_at<=clock_timestamp() then raise exception 'store_box_request_not_pending';end if;
  update public.yt_store_box_requests set status='accepted',accepted_by=actor,accepted_at=clock_timestamp() where id=r.id returning * into r;
  next_status:='drink_request_accepted';
 elsif p_action='prepare' then
  if r.status<>'accepted' then raise exception 'store_box_request_not_accepted';end if;
  update public.yt_store_box_requests set status='preparing' where id=r.id returning * into r;
  next_status:='drink_request_preparing';
 elsif p_action='serve' then
  if r.status not in ('pending','accepted','preparing') then raise exception 'store_box_request_not_active';end if;
  if not (b.status='active' or (b.status='unclaimed' and (
      (b.cashier_managed and r.customer_id is null)
      or ((private.yt_pos_work_cashier() or private.yt_work_owner()) and r.customer_id is not distinct from b.customer_id)
     )))
   or b.storage_expires_at is null or b.storage_expires_at<=clock_timestamp() then raise exception 'store_box_not_available';end if;
  request_selections:=case when jsonb_array_length(r.selections)>0 then r.selections else jsonb_build_array(jsonb_build_object('key',r.component_key,'name',r.component_name,'quantity',r.quantity)) end;
  if exists(select 1 from jsonb_array_elements(request_selections) s
   where not exists(select 1 from jsonb_array_elements(b.components) c where c->>'key'=s->>'key'
    and (s->>'quantity')::integer<=(c->>'total_units')::integer-(c->>'served_units')::integer))
  then raise exception 'store_box_component_unavailable';end if;
  select jsonb_agg(
   jsonb_set(c,'{served_units}',to_jsonb((c->>'served_units')::integer+coalesce((select sum((s->>'quantity')::integer) from jsonb_array_elements(request_selections) s where s->>'key'=c->>'key'),0)))
   order by n) into new_components from jsonb_array_elements(b.components) with ordinality e(c,n);
  update public.yt_store_box_requests set status='served',served_by=actor,served_at=clock_timestamp(),completed_delta=0 where id=r.id returning * into r;
  update public.yt_store_boxes set served_units=served_units+r.quantity,components=new_components,
   status=case when served_units+r.quantity=total_units then 'exhausted'
      when status='unclaimed' then 'unclaimed' else 'active' end,updated_at=clock_timestamp()
  where id=b.id returning * into b;
  if b.status='exhausted' then
   update public.yt_store_box_claims set status='cancelled',claim_token=null,cancelled_by=actor,
    cancelled_at=clock_timestamp(),cancel_reason='存酒余额已全部出完'
   where box_id=b.id and status='issued';
   if found then
    insert into public.yt_store_box_events(box_id,event_type,actor_id,customer_id,metadata)
    values(b.id,'claim_cancelled',actor,b.customer_id,jsonb_build_object('source','cashier_fully_served','note','存酒余额已全部出完'));
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
    values(actor,'store_box.claim_auto_cancel_exhausted','store_box',b.id,jsonb_build_object('box_number',b.box_number,'request_id',r.id));
   end if;
  end if;
  next_status:='drink_served';
 else
  if r.status not in ('pending','accepted','preparing') then raise exception 'store_box_request_not_active';end if;
  if r.status in('accepted','preparing') and length(btrim(coalesce(p_reason,'')))<2 then raise exception 'cancel_reason_required';end if;
  update public.yt_store_box_requests set status='cancelled',cancelled_by=actor,cancelled_at=clock_timestamp(),cancel_reason=nullif(btrim(p_reason),'') where id=r.id returning * into r;
  next_status:='drink_request_cancelled';
 end if;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,completed_delta,actor_id,note,metadata)
 values(b.id,r.id,next_status,r.quantity,0,actor,nullif(btrim(p_reason),''),jsonb_build_object('selections',r.selections));
 return jsonb_build_object('request',to_jsonb(r),'box',to_jsonb(b));
end $$;
