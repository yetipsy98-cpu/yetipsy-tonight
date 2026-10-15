-- Owner order review and business-day storage expiry
create or replace function private.yt_pos_orders(p_scope text default 'active',p_limit integer default 60)
returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare v_result jsonb;
begin
 if not private.yt_pos_work_staff() and not private.yt_work_owner() then raise exception 'staff_only';end if;
 if p_scope not in ('active','pending','paid','all','mine') or p_limit is null or p_limit<1 or p_limit>150 then raise exception 'invalid_filter';end if;
 if p_scope='pending' and not private.yt_pos_work_cashier() and not private.yt_work_owner() then raise exception 'cashier_only';end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc),'[]'::jsonb) into v_result from(
  select x.id,x.order_no,x.table_label,x.notes,x.status,x.payment_status,x.checkout_mode,x.amount_rm,x.revision,x.settlement_due_since,
   private.yt_pos_received(x.id) received_rm,case when x.payment_status in ('paid','refunded') then x.amount_rm-private.yt_pos_received(x.id) else x.amount_rm end balance_rm,
   x.created_at,x.updated_at,x.created_by,wa.username created_by_name,x.accepted_at,x.fulfilled_at,x.paid_at,x.payment_method,
   coalesce((select e.source from public.yt_pos_order_events e where e.order_id=x.id and e.event_type='created' order by e.created_at limit 1),'staff') created_channel,
   exists(select 1 from public.yt_pos_order_chits chit where chit.order_id=x.id and chit.status='queued') has_chit,
   private.yt_store_box_order_only(x.id) store_box_only,
   coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'price_rm',i.unit_price_rm,'fulfilled',i.fulfilled,'store_box_item',exists(select 1 from public.yt_store_box_product_rules sr where sr.product_id=i.product_id and sr.active)) order by i.item_name)
    from public.yt_member_order_items i where i.order_id=x.id and i.quantity>0),'[]'::jsonb) items
  from public.yt_member_orders x left join public.work_accounts wa on wa.auth_user_id=x.created_by
  where x.source='future_pos' and ((p_scope='active' and ((x.status in ('pending','confirmed') and x.payment_status in ('unpaid','paid')) or (x.status='fulfilled' and x.payment_status='unpaid')))
   or (p_scope='pending' and x.status='pending') or (p_scope='paid' and x.payment_status in ('paid','refunded')) or p_scope='all' or (p_scope='mine' and x.created_by=auth.uid()))
  order by x.created_at desc limit p_limit
 )o;return v_result;
end $function$;

create or replace function private.yt_pos_orders_day(p_scope text default 'active',p_day date default null,p_limit integer default 60)
returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare v_result jsonb;
begin
 if not private.yt_pos_work_staff() and not private.yt_work_owner() then raise exception 'staff_only';end if;
 if p_scope not in ('active','pending','paid','all','mine') or p_limit is null or p_limit<1 or p_limit>150 then raise exception 'invalid_filter';end if;
 if p_scope='pending' and not private.yt_pos_work_cashier() and not private.yt_work_owner() then raise exception 'cashier_only';end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc),'[]'::jsonb) into v_result from(
  select x.id,x.order_no,x.table_label,x.notes,x.status,x.payment_status,x.checkout_mode,x.amount_rm,x.revision,x.settlement_due_since,
   private.yt_pos_received(x.id) received_rm,case when x.payment_status in ('paid','refunded') then x.amount_rm-private.yt_pos_received(x.id) else x.amount_rm end balance_rm,
   x.created_at,x.updated_at,x.created_by,wa.username created_by_name,x.accepted_at,x.fulfilled_at,x.paid_at,x.payment_method,
   coalesce((select e.source from public.yt_pos_order_events e where e.order_id=x.id and e.event_type='created' order by e.created_at limit 1),'staff') created_channel,
   exists(select 1 from public.yt_pos_order_chits chit where chit.order_id=x.id and chit.status='queued') has_chit,
   private.yt_store_box_order_only(x.id) store_box_only,
   coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'price_rm',i.unit_price_rm,'fulfilled',i.fulfilled,'store_box_item',exists(select 1 from public.yt_store_box_product_rules sr where sr.product_id=i.product_id and sr.active)) order by i.item_name)
    from public.yt_member_order_items i where i.order_id=x.id and i.quantity>0),'[]'::jsonb) items
  from public.yt_member_orders x left join public.work_accounts wa on wa.auth_user_id=x.created_by
  where x.source='future_pos' and ((p_scope='active' and ((x.status in ('pending','confirmed') and x.payment_status in ('unpaid','paid')) or (x.status='fulfilled' and x.payment_status='unpaid')))
   or (p_scope='pending' and x.status='pending')
   or (p_scope='paid' and x.payment_status in ('paid','refunded') and x.paid_at>=private.yt_business_start(coalesce(p_day,private.yt_business_day(now()))) and x.paid_at<private.yt_business_start(coalesce(p_day,private.yt_business_day(now()))+1))
   or p_scope='all' or (p_scope='mine' and x.created_by=auth.uid()))
  order by case when p_scope='paid' then x.paid_at else x.created_at end desc limit p_limit
 )o;return v_result;
end $function$;

create or replace function private.yt_store_box_claim(p_token uuid)
returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare actor uuid:=auth.uid();c public.yt_store_box_claims%rowtype;b public.yt_store_boxes%rowtype;h text;issued_day date;
begin
 if not private.yt_store_box_customer() then raise exception 'customer_only';end if;
 if p_token is null then raise exception 'store_box_claim_invalid';end if;
 perform pg_advisory_xact_lock(781943084);
 h:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 select * into c from public.yt_store_box_claims where token_hash=h for update;
 if not found then raise exception 'store_box_claim_invalid';end if;
 select * into b from public.yt_store_boxes where id=c.box_id for update;
 if c.status='claimed' and c.claimed_by=actor and b.customer_id=actor then return to_jsonb(b);end if;
 if c.status<>'issued' or c.expires_at<=clock_timestamp() then raise exception 'store_box_claim_invalid';end if;
 if b.customer_id is not null and b.customer_id<>actor then raise exception 'store_box_claim_invalid';end if;
 if b.status not in ('unclaimed','active') then raise exception 'store_box_not_claimable';end if;
 issued_day:=private.yt_business_day(c.created_at);
 update public.yt_store_boxes set customer_id=actor,status='active',claimed_at=coalesce(claimed_at,clock_timestamp()),
  storage_expires_at=coalesce(storage_expires_at,private.yt_business_start(issued_day+expiry_days)),updated_at=clock_timestamp()
 where id=b.id returning * into b;
 update public.yt_store_box_claims set status='claimed',claimed_by=actor,claimed_at=clock_timestamp() where id=c.id;
 insert into public.yt_store_box_events(box_id,event_type,customer_id) values(b.id,'claimed',actor);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(actor,'store_box.claim','store_box',b.id);
 return to_jsonb(b);
end $function$;
