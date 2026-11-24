-- Keep package purchasing independent of the drink service window.
-- Do not finalise access-only orders until reward/preorder hooks have completed.
CREATE OR REPLACE FUNCTION private.yt_ff_access_fulfilled()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if coalesce(current_setting('yt.ff.checkout_building',true),'')<>'on' and new.source='future_pos' and new.status='confirmed' and exists(select 1 from public.yt_freeflow_sessions where order_id=new.id and anchor_item_id is not null)
 and not exists(select 1 from public.yt_member_order_items where order_id=new.id and quantity>0 and not fulfilled) then
  new.status:='fulfilled';new.fulfilled_at:=coalesce(new.fulfilled_at,clock_timestamp());new.fulfilled_by:=coalesce(new.fulfilled_by,auth.uid());
 end if;return new;
end$function$
;
CREATE OR REPLACE FUNCTION private.yt_pos_create_order_with_rewards_v4(p_request uuid, p_table text, p_note text, p_items jsonb, p_channel text, p_draft uuid, p_checkout_mode text, p_business_day date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 data jsonb; v_order uuid; v_day date:=coalesce(p_business_day,private.yt_business_day(clock_timestamp()));
 v_today date:=private.yt_business_day(clock_timestamp()); v_owner boolean:=private.yt_work_owner();
 v_building text:=coalesce(current_setting('yt.ff.checkout_building',true),'');
 v_status text; v_requested date; v_effective date;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if (select count(*) from public.yt_pos_preorder_holds h where h.operator_id=auth.uid() and h.draft_id=p_draft and h.state in ('pending','chosen') and h.expires_at>clock_timestamp()) + (select count(*) from public.yt_moon_preorder_holds h where h.operator_id=auth.uid() and h.draft_id=p_draft and h.state='held' and h.expires_at>clock_timestamp()) > 1 then raise exception 'only_one_code_per_order';end if;
 if v_day<'2020-01-01' or v_day>v_today then raise exception 'invalid_business_day';end if;
 if v_day<v_today and not (v_owner or private.yt_pos_work_cashier()) then raise exception 'cashier_only';end if;
 -- Finish reward attachment before access-only orders can become fulfilled.
 perform set_config('yt.ff.checkout_building','on',true);
 data:=private.yt_pos_create_order_with_rewards_v3(p_request,p_table,p_note,p_items,p_channel,p_draft,p_checkout_mode);
 perform set_config('yt.ff.checkout_building',v_building,true);
 v_order:=(data->>'id')::uuid;
 if v_order is null then raise exception 'order_not_found';end if;
 if not coalesce((data->>'idempotent')::boolean,false) then
  if v_day<v_today and v_owner then
   update public.yt_member_orders set pos_business_day=v_day,requested_business_day=v_day,
    backdate_approval_status='approved',updated_at=clock_timestamp() where id=v_order;
   insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
    values(auth.uid(),'pos.order_backdated','pos_order',v_order,jsonb_build_object('business_day',v_day,'approved_by_owner',true));
  elsif v_day<v_today then
   update public.yt_member_orders set requested_business_day=v_day,
    backdate_approval_status='pending',updated_at=clock_timestamp() where id=v_order;
   insert into public.yt_pos_order_backdate_requests(order_id,requested_business_day,requester_id)
    values(v_order,v_day,auth.uid()) on conflict(order_id) do nothing;
  end if;
 end if;
 -- All preorder hooks have finished. Let the normal access trigger finalise
 -- confirmed package-only orders; pending review and mixed drink orders stay pending.
 if exists(select 1 from public.yt_freeflow_sessions where order_id=v_order and anchor_item_id is not null) then
  update public.yt_member_orders set status=status where id=v_order;
  select data||jsonb_build_object('status',o.status) into data from public.yt_member_orders o where o.id=v_order;
 end if;
 select backdate_approval_status,requested_business_day,pos_business_day
  into v_status,v_requested,v_effective from public.yt_member_orders where id=v_order;
 return data||jsonb_build_object('backdate_approval_status',v_status,
  'requested_business_day',v_requested,'business_day',v_effective);
end;$function$
;
