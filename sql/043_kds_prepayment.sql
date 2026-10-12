-- Separate bar production from settlement: prepaid orders remain in KDS until served,
-- while served unpaid orders become open tabs.

alter table public.yt_member_orders
  add column if not exists checkout_mode text not null default 'pay_later';

alter table public.yt_member_orders drop constraint if exists yt_member_orders_checkout_mode_check;
alter table public.yt_member_orders add constraint yt_member_orders_checkout_mode_check
  check(checkout_mode in ('pay_now','pay_later'));

create or replace function private.yt_pos_create_order_with_rewards_v2(
 p_request uuid,p_table text,p_note text,p_items jsonb,p_channel text,p_draft uuid,p_checkout_mode text
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare data jsonb;existing_mode text;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_checkout_mode not in ('pay_now','pay_later') then raise exception 'invalid_checkout_mode';end if;
 data:=private.yt_pos_create_order_with_rewards(p_request,p_table,p_note,p_items,p_channel,p_draft);
 select checkout_mode into existing_mode from public.yt_member_orders where id=(data->>'id')::uuid for update;
 if (data->>'idempotent')::boolean and existing_mode<>p_checkout_mode then raise exception 'request_conflict';end if;
 update public.yt_member_orders set checkout_mode=p_checkout_mode where id=(data->>'id')::uuid;
 return data||jsonb_build_object('checkout_mode',p_checkout_mode);
end $$;

create or replace function public.yt_pos_create_order_with_rewards_v2(
 p_request uuid,p_table text,p_note text,p_items jsonb,p_channel text,p_draft uuid,p_checkout_mode text
) returns jsonb language sql set search_path='' as $$
 select private.yt_pos_create_order_with_rewards_v2(p_request,p_table,p_note,p_items,p_channel,p_draft,p_checkout_mode);
$$;

revoke all on function private.yt_pos_create_order_with_rewards_v2(uuid,text,text,jsonb,text,uuid,text) from public,anon,authenticated;
revoke all on function public.yt_pos_create_order_with_rewards_v2(uuid,text,text,jsonb,text,uuid,text) from public,anon;
grant execute on function public.yt_pos_create_order_with_rewards_v2(uuid,text,text,jsonb,text,uuid,text) to authenticated;

create or replace function private.yt_pos_cart_summary(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v public.yt_member_orders%rowtype;v_holds jsonb;v_discount numeric(12,2);v_broken int;v_store_box_only boolean;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found';end if;
 v_store_box_only:=private.yt_store_box_order_only(p_order);
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',h.id,'reward_name',r.name,'state',h.state,'discount_type',h.discount_type,
  'discount_rm',h.discount_rm,'expires_at',h.expires_at,
  'item_name',i.item_name,'unit_number',h.unit_number,
  'can_checkout',h.state='ready' and h.expires_at>clock_timestamp()
 ) order by h.created_at),'[]'::jsonb),
 coalesce(sum(case when h.state='ready' and h.expires_at>clock_timestamp() then h.discount_rm else 0 end),0),
 count(*) filter (where h.state='reserved' or h.expires_at<=clock_timestamp())
 into v_holds,v_discount,v_broken
 from public.yt_pos_reward_holds h
 join public.rewards r on r.id=h.reward_id
 left join public.yt_member_order_items i on i.id=h.order_item_id
 where h.order_id=v.id and h.state in ('reserved','ready');
 return private.yt_pos_order_minimum(p_order)||jsonb_build_object('order_id',v.id,'order_no',v.order_no,'status',v.status,
  'payment_status',v.payment_status,'checkout_mode',v.checkout_mode,'gross_rm',v.amount_rm,
  'reserved_discount_rm',v_discount,'payable_rm',greatest(0,v.amount_rm-v_discount),
  'unresolved_count',v_broken,'holds',v_holds,'store_box_only',v_store_box_only,
  'can_pay',v.payment_status='unpaid' and v.status in ('confirmed','fulfilled') and v_broken=0
   and v_discount<=v.amount_rm and (private.yt_pos_order_minimum(p_order)->>'minimum_met')::boolean);
end $$;

create or replace function private.yt_pos_action(p_order uuid,p_action text,p_reason text default null,p_method text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v public.yt_member_orders%rowtype;v_cashier boolean:=private.yt_pos_work_cashier();
 v_actor uuid:=auth.uid();v_reason text:=nullif(btrim(coalesce(p_reason,'')),'');v_store_box_only boolean;
 v_claims jsonb:='[]'::jsonb;v_issue jsonb;v_item record;v_result_status text;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_order is null or p_action not in ('accept','reject','fulfilled','paid','cancel') then raise exception 'invalid_action';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 v_store_box_only:=private.yt_store_box_order_only(p_order);
 if v.created_at<=clock_timestamp()-interval '72 hours' and private.yt_work_owner() and length(btrim(coalesce(p_reason,'')))<2 then raise exception 'reason_required';end if;
 if p_action='accept' then
  if not v_cashier then raise exception 'cashier_only';end if;
  if v.status<>'pending' or v.payment_status<>'unpaid' then raise exception 'order_not_pending';end if;
  update public.yt_member_orders set status='confirmed',accepted_by=v_actor,accepted_at=clock_timestamp(),updated_at=clock_timestamp() where id=p_order;
  if not v_store_box_only then
   insert into public.yt_pos_order_chits(order_id) values(p_order)
   on conflict(order_id) do update set status='queued',issued_at=clock_timestamp(),printed_at=null,printed_by=null;
  end if;
 elsif p_action='reject' then
  if not v_cashier then raise exception 'cashier_only';end if;
  if v.status<>'pending' or v.payment_status<>'unpaid' then raise exception 'order_not_pending';end if;
  if length(coalesce(v_reason,''))<2 or length(v_reason)>300 then raise exception 'reason_required';end if;
  update public.yt_member_orders set status='cancelled',rejected_by=v_actor,rejected_at=clock_timestamp(),reject_reason=v_reason,updated_at=clock_timestamp() where id=p_order;
 elsif p_action='fulfilled' then
  if v.status<>'confirmed' or v.payment_status not in ('unpaid','paid') then raise exception 'order_not_accepted';end if;
  update public.yt_member_orders set status='fulfilled',fulfilled_by=v_actor,fulfilled_at=clock_timestamp(),updated_at=clock_timestamp() where id=p_order;
  if v.payment_status='paid' then
   for v_item in
    select i.id from public.yt_member_order_items i
    join public.yt_store_box_product_rules r on r.product_id=i.product_id and r.active
    where i.order_id=p_order and i.quantity>0 order by i.id
   loop
    v_issue:=private.yt_store_box_issue(v_item.id,gen_random_uuid(),gen_random_uuid(),2);
    v_claims:=v_claims||jsonb_build_array(v_issue);
   end loop;
  end if;
 elsif p_action='paid' then
  if not v_cashier then raise exception 'cashier_only';end if;
  if v.payment_status<>'unpaid' or v.status not in ('confirmed','fulfilled') then raise exception 'order_not_served';end if;
  if p_method is null or btrim(p_method)='' then p_method:='foodcourt';end if;
  if p_method not in ('foodcourt','cash','duitnow','card','bank_transfer','other') then raise exception 'invalid_payment_method';end if;
  v_result_status:=case when v.status='fulfilled' or v_store_box_only then 'fulfilled' else 'confirmed' end;
  update public.yt_member_orders set status=v_result_status,
   fulfilled_by=case when v_result_status='fulfilled' and v.status='confirmed' then v_actor else fulfilled_by end,
   fulfilled_at=case when v_result_status='fulfilled' and v.status='confirmed' then clock_timestamp() else fulfilled_at end,
   payment_status='paid',paid_by=v_actor,paid_at=clock_timestamp(),payment_method=p_method,updated_at=clock_timestamp()
  where id=p_order;
  if v_result_status='fulfilled' then
   for v_item in
    select i.id from public.yt_member_order_items i
    join public.yt_store_box_product_rules r on r.product_id=i.product_id and r.active
    where i.order_id=p_order and i.quantity>0 order by i.id
   loop
    v_issue:=private.yt_store_box_issue(v_item.id,gen_random_uuid(),gen_random_uuid(),2);
    v_claims:=v_claims||jsonb_build_array(v_issue);
   end loop;
  end if;
 elsif p_action='cancel' then
  if not v_cashier then raise exception 'cashier_only';end if;
  if v.status not in ('pending','confirmed') or v.payment_status<>'unpaid' then raise exception 'order_cannot_cancel';end if;
  if length(coalesce(v_reason,''))<2 or length(v_reason)>300 then raise exception 'reason_required';end if;
  update public.yt_member_orders set status='cancelled',rejected_by=v_actor,rejected_at=clock_timestamp(),reject_reason=v_reason,updated_at=clock_timestamp() where id=p_order;
  update public.yt_pos_order_chits set status='cancelled' where order_id=p_order;
 end if;
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note)
 values(p_order,v_actor,case when p_action='fulfilled' then 'fulfilled' when p_action='paid' then 'paid' when p_action in ('reject','cancel') then case when p_action='reject' then 'rejected' else 'cancelled' end else 'accepted' end,
  case when v_cashier then 'cashier' else 'staff' end,case when p_action='paid' then p_method else v_reason end);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(v_actor,'pos.'||p_action,'pos_order',p_order,jsonb_build_object('payment_method',p_method,'note',v_reason,'store_box_claims',jsonb_array_length(v_claims)));
 select * into v from public.yt_member_orders where id=p_order;
 return jsonb_build_object('ok',true,'order_id',p_order,'action',p_action,'status',v.status,
  'payment_status',v.payment_status,'store_box_claims',v_claims);
end $$;

create or replace function private.yt_pos_orders(p_scope text default 'active',p_limit integer default 60) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_result jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_scope not in ('active','pending','paid','all','mine') or p_limit is null or p_limit<1 or p_limit>150 then raise exception 'invalid_filter';end if;
 if p_scope='pending' and not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc),'[]'::jsonb) into v_result from(
  select x.id,x.order_no,x.table_label,x.notes,x.status,x.payment_status,x.checkout_mode,x.amount_rm,x.revision,x.settlement_due_since,
   private.yt_pos_received(x.id) received_rm,case when x.payment_status in ('paid','refunded') then x.amount_rm-private.yt_pos_received(x.id) else x.amount_rm end balance_rm,
   x.created_at,x.updated_at,x.created_by,wa.username created_by_name,x.accepted_at,x.fulfilled_at,x.paid_at,x.payment_method,
   coalesce((select e.source from public.yt_pos_order_events e where e.order_id=x.id and e.event_type='created' order by e.created_at limit 1),'staff') created_channel,
   exists(select 1 from public.yt_pos_order_chits chit where chit.order_id=x.id and chit.status='queued') has_chit,
   private.yt_store_box_order_only(x.id) store_box_only,
   coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'price_rm',i.unit_price_rm) order by i.item_name)
    from public.yt_member_order_items i where i.order_id=x.id and i.quantity>0),'[]'::jsonb) items
  from public.yt_member_orders x left join public.work_accounts wa on wa.auth_user_id=x.created_by
  where x.source='future_pos' and ((p_scope='active' and ((x.status in ('pending','confirmed') and x.payment_status in ('unpaid','paid')) or (x.status='fulfilled' and x.payment_status='unpaid')))
   or (p_scope='pending' and x.status='pending') or (p_scope='paid' and x.payment_status in ('paid','refunded')) or p_scope='all' or (p_scope='mine' and x.created_by=auth.uid()))
  order by x.created_at desc limit p_limit
 )o;return v_result;
end $$;

create or replace function private.yt_pos_orders_day(p_scope text default 'active',p_day date default null,p_limit integer default 60) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_result jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_scope not in ('active','pending','paid','all','mine') or p_limit is null or p_limit<1 or p_limit>150 then raise exception 'invalid_filter';end if;
 if p_scope='pending' and not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc),'[]'::jsonb) into v_result from(
  select x.id,x.order_no,x.table_label,x.notes,x.status,x.payment_status,x.checkout_mode,x.amount_rm,x.revision,x.settlement_due_since,
   private.yt_pos_received(x.id) received_rm,case when x.payment_status in ('paid','refunded') then x.amount_rm-private.yt_pos_received(x.id) else x.amount_rm end balance_rm,
   x.created_at,x.updated_at,x.created_by,wa.username created_by_name,x.accepted_at,x.fulfilled_at,x.paid_at,x.payment_method,
   coalesce((select e.source from public.yt_pos_order_events e where e.order_id=x.id and e.event_type='created' order by e.created_at limit 1),'staff') created_channel,
   exists(select 1 from public.yt_pos_order_chits chit where chit.order_id=x.id and chit.status='queued') has_chit,
   private.yt_store_box_order_only(x.id) store_box_only,
   coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'price_rm',i.unit_price_rm) order by i.item_name)
    from public.yt_member_order_items i where i.order_id=x.id and i.quantity>0),'[]'::jsonb) items
  from public.yt_member_orders x left join public.work_accounts wa on wa.auth_user_id=x.created_by
  where x.source='future_pos' and ((p_scope='active' and ((x.status in ('pending','confirmed') and x.payment_status in ('unpaid','paid')) or (x.status='fulfilled' and x.payment_status='unpaid')))
   or (p_scope='pending' and x.status='pending')
   or (p_scope='paid' and x.payment_status in ('paid','refunded') and x.paid_at>=private.yt_business_start(coalesce(p_day,private.yt_business_day(now()))) and x.paid_at<private.yt_business_start(coalesce(p_day,private.yt_business_day(now()))+1))
   or p_scope='all' or (p_scope='mine' and x.created_by=auth.uid()))
  order by case when p_scope='paid' then x.paid_at else x.created_at end desc limit p_limit
 )o;return v_result;
end $$;
