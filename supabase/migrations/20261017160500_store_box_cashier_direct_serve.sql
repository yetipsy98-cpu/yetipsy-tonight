-- Let Cashier/Owner serve paid Store Box items directly to KDS without customer QR claim.
-- The direct action invalidates an issued claim in the same transaction.
create or replace function private.yt_store_box_issue_quote(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare o public.yt_member_orders%rowtype;rows jsonb;can_view boolean:=private.yt_store_box_can_view_claim_identity();
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select * into o from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.item_name),'[]'::jsonb) into rows from(
  select i.id order_item_id,i.product_id,i.item_name,i.quantity,r.mode,
   i.quantity*r.total_units total_units,coalesce(b.total_units-b.served_units,i.quantity*r.total_units) remaining_units,
   r.request_limit,r.expiry_days,r.unit_label,r.selection_mode,r.components,
   case when b.id is not null then b.components
    when jsonb_array_length(r.components)>0 then
     (select coalesce(jsonb_agg(jsonb_build_object(
       'key',c->>'key','name',c->>'name',
       'total_units',(c->>'quantity')::integer*i.quantity,'served_units',0
      ) order by n),'[]'::jsonb)
      from jsonb_array_elements(r.components) with ordinality e(c,n))
    else jsonb_build_array(jsonb_build_object('key','default','name',i.item_name,'total_units',i.quantity*r.total_units,'served_units',0))
   end cashier_components,
   r.game_pass_enabled,b.id box_id,b.status box_status,b.served_units,b.cashier_managed,
   active_request.id active_request_id,
   case when can_view then coalesce(pr.display_name,p.phone) else null end customer_name,
   case when can_view then p.phone else null end customer_phone,
   c.id active_claim_id,c.claim_token,c.expires_at claim_expires_at,
   case when can_view then w.username else null end issued_by_name
  from public.yt_member_order_items i
  join public.yt_store_box_product_rules r on r.product_id=i.product_id and r.active
  left join public.yt_store_boxes b on b.source_order_item_id=i.id
  left join public.yt_store_box_claims c on c.box_id=b.id and c.status='issued' and c.expires_at>clock_timestamp()
  left join lateral(select q.id from public.yt_store_box_requests q where q.box_id=b.id and q.status in ('pending','accepted','preparing') order by q.requested_at desc limit 1) active_request on true
  left join public.work_accounts w on w.auth_user_id=c.issued_by
  left join public.pin_accounts p on p.auth_user_id=b.customer_id
  left join public.profiles pr on pr.id=b.customer_id
  where i.order_id=p_order and i.quantity>0
 )x;
 return jsonb_build_object('order_id',o.id,'order_no',o.order_no,'table_label',o.table_label,
  'ready',o.status='fulfilled' and o.payment_status='paid' and o.paid_at is not null and o.settlement_due_since is null and not o.cancel_after_refund,
  'items',rows);
end $$;

create or replace function private.yt_store_box_claims_active() returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb;can_view boolean:=private.yt_store_box_can_view_claim_identity();
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_box_claims set status='expired',claim_token=null where status='issued' and expires_at<=clock_timestamp();
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into rows from(
  select c.id claim_id,c.box_id,c.claim_token,c.expires_at,c.created_at,
   case when can_view then w.username else null end issued_by_name,
   b.source_order_item_id order_item_id,b.components,b.name,b.mode,b.total_units,b.unit_label,b.table_label,
   o.id order_id,o.order_no
  from public.yt_store_box_claims c join public.yt_store_boxes b on b.id=c.box_id
  join public.yt_member_orders o on o.id=b.source_order_id
  left join public.work_accounts w on w.auth_user_id=c.issued_by
  where c.status='issued' and c.expires_at>clock_timestamp()
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_cashier_request(p_box uuid,p_selections jsonb,p_request uuid,p_initial boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
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
 if not found or b.status not in('unclaimed','active') or b.storage_expires_at<=clock_timestamp() then raise exception 'store_box_not_available';end if;
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
end $$;

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

 update public.yt_store_box_claims set status='cancelled',claim_token=null,cancelled_by=actor,cancelled_at=clock_timestamp(),cancel_reason='Cashier 直接安排出酒'
 where box_id=b.id and status='issued';
 if found then
  insert into public.yt_store_box_events(box_id,event_type,actor_id,customer_id,metadata)
  values(b.id,'claim_cancelled',actor,b.customer_id,jsonb_build_object('source','cashier_direct_serve','note','Cashier 直接安排出酒'));
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(actor,'store_box.cashier_direct_claim_cancel','store_box',b.id,jsonb_build_object('box_number',b.box_number,'order_item_id',i.id));
 end if;

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

create or replace function public.yt_store_box_cashier_direct_issue(p_order_item uuid,p_selections jsonb,p_request uuid) returns jsonb
language sql security invoker set search_path='' as $$
 select private.yt_store_box_cashier_direct_issue(p_order_item,p_selections,p_request)
$$;

revoke all on function private.yt_store_box_cashier_direct_issue(uuid,jsonb,uuid) from public,anon;
revoke all on function public.yt_store_box_cashier_direct_issue(uuid,jsonb,uuid) from public,anon;
grant execute on function private.yt_store_box_cashier_direct_issue(uuid,jsonb,uuid) to authenticated;
grant execute on function public.yt_store_box_cashier_direct_issue(uuid,jsonb,uuid) to authenticated;
