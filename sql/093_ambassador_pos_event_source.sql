-- Map Ambassador Pass redemptions to the existing POS event source values.
-- The source constraint permits cashier/staff/customer/system only.
create or replace function private.yt_ambassador_pos_order_create(p_token text,p_male integer,p_female integer,p_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_ambassador_passes%rowtype; a public.yt_ambassadors%rowtype; pp jsonb; code text;
 d date:=private.yt_business_day(now()); mp numeric; fp numeric; amount numeric(12,2);
 oid uuid; ono text; old_sale public.yt_ambassador_pos_sales%rowtype; note_text text; rate numeric(5,2);
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_request is null or p_male is null or p_female is null or p_male<0 or p_female<0 or p_male+p_female<1 or p_male+p_female>500 then
  raise exception 'invalid_guest_count';end if;
 perform pg_advisory_xact_lock(hashtextextended('yt-ambassador-order:'||p_request::text,0));
 select * into old_sale from public.yt_ambassador_pos_sales where request_id=p_request;
 if old_sale.order_id is not null then
  if old_sale.created_by<>auth.uid() or old_sale.male_count<>p_male or old_sale.female_count<>p_female then raise exception 'request_conflict';end if;
  select order_no into ono from public.yt_member_orders where id=old_sale.order_id;
  return jsonb_build_object('order_id',old_sale.order_id,'order_no',ono,'idempotent',true);
 end if;
 code:=(regexp_match(trim(coalesce(p_token,'')),'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'))[1];
 if code is null then raise exception 'ambassador_pass_not_found';end if;
 begin select * into v from public.yt_ambassador_passes where pass_code=code::uuid and status='issued' for update;
 exception when invalid_text_representation then raise exception 'ambassador_pass_not_found';end;
 if v.id is null then raise exception 'ambassador_pass_not_found';end if;
 if v.issued_by=auth.uid() and not (private.yt_pos_work_cashier() or private.yt_has_role('owner')) then raise exception 'cannot_redeem_own_pass';end if;
 if v.ambassador_id is not null then
  select * into a from public.yt_ambassadors where id=v.ambassador_id and active;
  if a.id is null then raise exception 'ambassador_inactive';end if;
  if a.member_user_id=auth.uid() or a.work_user_id=auth.uid() then raise exception 'cannot_redeem_own_pass';end if;
 end if;
 if d<>v.reservation_day or now()<private.yt_business_start(v.reservation_day)
  or now()>=private.yt_business_start(v.reservation_day+1) then raise exception 'ambassador_pass_not_valid_today';end if;
 pp:=private.yt_ambassador_price(v.reservation_day);mp:=(pp->>'male')::numeric;fp:=(pp->>'female')::numeric;
 if coalesce(mp,0)<=0 or coalesce(fp,0)<=0 then raise exception 'ambassador_prices_not_configured';end if;
 rate:=coalesce(a.commission_rate,0);amount:=round(p_male*mp+p_female*fp,2);
 if amount<=0 or amount>100000 then raise exception 'order_too_large';end if;
 ono:='YT'||to_char(clock_timestamp() at time zone 'Asia/Kuala_Lumpur','YYMMDD')||'-'||lpad(nextval('public.yt_pos_order_serial'::regclass)::text,6,'0');
 note_text:='Freeflow Pass · '||case when v.ambassador_id is null then 'POS 直发' else coalesce(nullif(a.display_name,''),'Ambassador') end;
 insert into public.yt_member_orders(source,status,order_no,table_label,notes,payment_status,created_by,created_at,updated_at,
  client_request_id,amount_rm,accepted_at,accepted_by,fulfilled_at,fulfilled_by)
 values('future_pos','fulfilled',ono,'Freeflow',note_text,'unpaid',auth.uid(),clock_timestamp(),clock_timestamp(),
  p_request,amount,clock_timestamp(),auth.uid(),clock_timestamp(),auth.uid()) returning id into oid;
 if p_male>0 then
  insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm,is_drink_at_order)
   values(oid,null,'Freeflow Male',p_male,mp,false);
 end if;
 if p_female>0 then
  insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm,is_drink_at_order)
   values(oid,null,'Freeflow Female',p_female,fp,false);
 end if;
 insert into public.yt_ambassador_pos_sales(order_id,request_id,pass_id,ambassador_id,business_day,male_count,female_count,
  male_price,female_price,commission_rate,created_by)
 values(oid,p_request,v.id,v.ambassador_id,d,p_male,p_female,mp,fp,rate,auth.uid());
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note)
  values(oid,auth.uid(),'created',case when private.yt_pos_work_cashier() or private.yt_has_role('owner') then 'cashier' else 'staff' end,note_text);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(auth.uid(),'pos.ambassador_sale_created','pos_order',oid,
   jsonb_build_object('pass_id',v.id,'male_count',p_male,'female_count',p_female,'amount_rm',amount,'business_day',d,'commission_rate',rate));
 return jsonb_build_object('order_id',oid,'order_no',ono,'amount_rm',amount,'status','fulfilled','commission_rate',rate,'idempotent',false);
end $$;
