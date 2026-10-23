-- Let a full Owner execute cart FOC/Discount immediately, while Cashiers keep
-- the existing request-and-approval workflow. The request row is retained as
-- an immutable audit trail and is atomically marked approved with its order.
create or replace function private.yt_pos_owner_adjustment_execute(p_request uuid,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  actor uuid:=auth.uid(); v_draft uuid; v_kind text; v_items jsonb; v_foc jsonb;
  v_gross numeric(12,2); v_adjustment numeric(12,2); v_net numeric(12,2);
  v_discount_type text; v_discount_value numeric; v_reason text;
  v_existing public.yt_pos_cashier_adjustment_requests%rowtype; v_result jsonb;
begin
  if not private.yt_work_owner() then raise exception 'owner_only'; end if;
  if p_request is null or jsonb_typeof(p_payload)<>'object' then raise exception 'invalid_adjustment_request'; end if;
  perform pg_advisory_xact_lock(hashtextextended('yt-pos-owner-adjust:'||p_request::text,0));
  select * into v_existing from public.yt_pos_cashier_adjustment_requests where id=p_request;
  if found then
    if v_existing.requester_id<>actor then raise exception 'request_conflict'; end if;
    return coalesce(v_existing.result,jsonb_build_object('id',v_existing.id,'status',v_existing.status,'order_id',v_existing.order_id));
  end if;

  v_draft:=nullif(p_payload->>'draft_id','')::uuid;
  v_kind:=p_payload->>'kind'; v_items:=p_payload->'items';
  v_foc:=coalesce(p_payload->'foc_product_ids','[]'::jsonb);
  v_reason:=btrim(coalesce(p_payload->>'reason',''));
  if v_draft is null or v_kind not in ('foc','discount') or length(v_reason)<2 or length(v_reason)>300 then raise exception 'invalid_adjustment_request'; end if;
  if coalesce(p_payload->>'checkout_mode','') not in ('pay_now','pay_later') then raise exception 'invalid_checkout_mode'; end if;
  if length(coalesce(p_payload->>'table_label',''))>32 or length(coalesce(p_payload->>'order_note',''))>600 then raise exception 'invalid_adjustment_request'; end if;
  if jsonb_typeof(v_items)<>'array' or jsonb_array_length(v_items)<1 then raise exception 'invalid_order'; end if;
  if exists(select 1 from public.yt_pos_preorder_holds h where h.operator_id=actor and h.draft_id=v_draft and h.state in ('pending','chosen') and h.expires_at>clock_timestamp())
     or exists(select 1 from public.yt_moon_preorder_holds h where h.operator_id=actor and h.draft_id=v_draft and h.state='held' and h.expires_at>clock_timestamp()) then raise exception 'manual_adjustment_cannot_combine_code'; end if;

  select x.gross_rm into v_gross from private.yt_pos_draft_price(v_items) x;
  if v_kind='foc' then
    if jsonb_typeof(v_foc)<>'array' or jsonb_array_length(v_foc)<1 then raise exception 'foc_item_required'; end if;
    if exists(select 1 from jsonb_array_elements_text(v_foc) s where s.value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then raise exception 'foc_item_required'; end if;
    if (select count(distinct s.value) from jsonb_array_elements_text(v_foc) s)<>jsonb_array_length(v_foc) then raise exception 'foc_item_required'; end if;
    select coalesce(sum(p.price_rm*(i.value->>'quantity')::int),0)::numeric(12,2) into v_adjustment
      from jsonb_array_elements(v_items) i(value)
      join public.yt_shop_products p on p.id=(i.value->>'product_id')::uuid and p.active
      where (i.value->>'product_id') in (select s.value from jsonb_array_elements_text(v_foc) s);
    if v_adjustment<=0 or v_adjustment>=v_gross then raise exception 'adjustment_zero_total'; end if;
  else
    v_discount_type:=p_payload->>'discount_type';
    begin v_discount_value:=(p_payload->>'discount_value')::numeric; exception when others then raise exception 'discount_invalid'; end;
    if v_discount_type='rm' and v_discount_value>0 then v_adjustment:=round(v_discount_value,2);
    elsif v_discount_type='percent' and v_discount_value>0 and v_discount_value<100 then v_adjustment:=round(v_gross*v_discount_value/100,2);
    else raise exception 'discount_invalid'; end if;
    if v_adjustment<=0 or v_adjustment>=v_gross then raise exception 'adjustment_zero_total'; end if;
  end if;
  v_net:=round(v_gross-v_adjustment,2);
  if v_net<0.01 then raise exception 'adjustment_zero_total'; end if;

  insert into public.yt_pos_cashier_adjustment_requests(id,requester_id,draft_id,kind,request_payload,gross_rm,adjustment_rm,net_rm,status)
  values(p_request,actor,v_draft,v_kind,p_payload||jsonb_build_object('gross_rm',v_gross,'adjustment_rm',v_adjustment,'net_rm',v_net,'requester_id',actor),v_gross,v_adjustment,v_net,'pending');
  v_result:=private.yt_pos_cashier_adjustment_review(p_request,true,'Owner direct action');
  return v_result||jsonb_build_object('direct',true,'gross_rm',v_gross,'adjustment_rm',v_adjustment,'net_rm',v_net);
end;
$function$;

create or replace function public.yt_pos_owner_adjustment_execute(p_request uuid,p_payload jsonb)
returns jsonb language sql security definer set search_path = ''
as $function$ select private.yt_pos_owner_adjustment_execute(p_request,p_payload); $function$;

revoke all on function private.yt_pos_owner_adjustment_execute(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.yt_pos_owner_adjustment_execute(uuid,jsonb) from public,anon;
grant execute on function public.yt_pos_owner_adjustment_execute(uuid,jsonb) to authenticated;
