create or replace function private.yt_pos_owner_revision_request_submit(p_order uuid,p_items jsonb,p_reason text,p_table text,p_note text,p_expected_updated timestamptz,p_cancel boolean,p_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_member_orders%rowtype;clean_items jsonb;payload jsonb;existing public.yt_pos_owner_revision_requests%rowtype;preview jsonb;
begin
 if not private.yt_pos_work_cashier() or private.yt_work_owner() then raise exception 'cashier_only';end if;
 if p_order is null or p_request is null or p_expected_updated is null or p_cancel is null or length(btrim(coalesce(p_reason,''))) not between 3 and 300 or length(coalesce(p_table,''))>32 or length(coalesce(p_note,''))>600 then raise exception 'invalid_order_revision';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos';
 if not found or v.status in ('cancelled','refunded') then raise exception 'order_not_editable';end if;
 if p_cancel then clean_items:='[]'::jsonb;
 else
  if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'invalid_order_revision';end if;
  select coalesce(jsonb_agg(value-'unit_price_rm' order by ordinality),'[]'::jsonb) into clean_items from jsonb_array_elements(p_items) with ordinality as i(value,ordinality);
 end if;
 preview:=private.yt_pos_owner_revision_preview(p_order,clean_items,p_cancel);
 payload:=jsonb_build_object('order',p_order,'items',clean_items,'reason',btrim(p_reason),'table',nullif(btrim(coalesce(p_table,'')),''),'note',nullif(btrim(coalesce(p_note,'')),''),'expected',p_expected_updated,'cancel',p_cancel,'preview',preview);
 select * into existing from public.yt_pos_owner_revision_requests where id=p_request;
 if found then if existing.requester_id<>auth.uid() or existing.order_id<>p_order or existing.request_payload<>payload then raise exception 'request_conflict';end if;return jsonb_build_object('id',existing.id,'status',existing.status,'retried',true);end if;
 begin
  insert into public.yt_pos_owner_revision_requests(id,order_id,requester_id,request_payload) values(p_request,p_order,auth.uid(),payload);
 exception when unique_violation then raise exception 'revision_request_already_pending';end;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.revision_requested','pos_order',p_order,jsonb_build_object('request_id',p_request,'cancel',p_cancel,'reason',btrim(p_reason)));
 return jsonb_build_object('id',p_request,'status','pending');
end $$;
