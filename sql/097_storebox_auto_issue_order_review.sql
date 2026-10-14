-- Automatically show every paid and fulfilled Store Box item for QR generation.
-- Owner controls whether staff-submitted POS orders wait for Cashier approval.

create table if not exists public.yt_pos_order_review_settings (
 singleton boolean primary key default true check(singleton),
 require_review boolean not null default true,
 updated_by uuid,
 updated_at timestamptz not null default clock_timestamp()
);
insert into public.yt_pos_order_review_settings(singleton,require_review)
values(true,true) on conflict(singleton) do nothing;
alter table public.yt_pos_order_review_settings enable row level security;
revoke all on table public.yt_pos_order_review_settings from public,anon,authenticated;

create or replace function private.yt_pos_order_review_setting_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare v boolean;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select require_review into v from public.yt_pos_order_review_settings where singleton;
 return jsonb_build_object('require_review',coalesce(v,true));
end $$;

create or replace function public.yt_pos_order_review_setting_get() returns jsonb
language sql security invoker set search_path='' as $$
 select private.yt_pos_order_review_setting_get()
$$;

create or replace function private.yt_pos_order_review_setting_save(p_require_review boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=auth.uid();
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_require_review is null then raise exception 'invalid_review_setting';end if;
 insert into public.yt_pos_order_review_settings(singleton,require_review,updated_by,updated_at)
 values(true,p_require_review,v_actor,clock_timestamp())
 on conflict(singleton) do update set require_review=excluded.require_review,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 insert into public.audit_logs(actor_id,action,entity_type,metadata)
 values(v_actor,'pos.staff_review_setting_updated','pos_setting',jsonb_build_object('require_review',p_require_review));
 return jsonb_build_object('require_review',p_require_review);
end $$;

create or replace function public.yt_pos_order_review_setting_save(p_require_review boolean) returns jsonb
language sql security invoker set search_path='' as $$
 select private.yt_pos_order_review_setting_save(p_require_review)
$$;

revoke all on function private.yt_pos_order_review_setting_get(),public.yt_pos_order_review_setting_get(),
 private.yt_pos_order_review_setting_save(boolean),public.yt_pos_order_review_setting_save(boolean) from public,anon;
grant execute on function private.yt_pos_order_review_setting_get(),public.yt_pos_order_review_setting_get(),
 private.yt_pos_order_review_setting_save(boolean),public.yt_pos_order_review_setting_save(boolean) to authenticated;

-- Keep the current single-list API shape, adding each order's eligible items.
create or replace function private.yt_store_box_issue_orders() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;d date:=private.yt_business_day(clock_timestamp());
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',x.id,'order_no',x.order_no,'table_label',x.table_label,'amount_rm',x.amount_rm,
  'created_at',x.created_at,'eligible_items',x.eligible_items,'ready',true,
  'items',coalesce(private.yt_store_box_issue_quote(x.id)->'items','[]'::jsonb)
 ) order by x.created_at desc),'[]'::jsonb) into rows
 from (
  select o.id,o.order_no,o.table_label,o.amount_rm,o.created_at,count(*) eligible_items
  from public.yt_member_orders o
  join public.yt_member_order_items i on i.order_id=o.id
  join public.yt_store_box_product_rules r on r.product_id=i.product_id and r.active
  where o.source='future_pos' and o.status='fulfilled' and o.payment_status='paid'
   and o.paid_at is not null and o.settlement_due_since is null and not o.cancel_after_refund
   and o.created_at>=private.yt_business_start(d) and o.created_at<private.yt_business_start(d+1)
  group by o.id,o.order_no,o.table_label,o.amount_rm,o.created_at
 ) x;
 return jsonb_build_object('business_day',d,'orders',rows);
end $$;

-- Preserve the established Moon/reward submission flow. When approval is off,
-- confirm only newly created Staff orders and enqueue ordinary items for KDS.
create or replace function private.yt_pos_create_order_with_rewards_v2(
 p_request uuid,p_table text,p_note text,p_items jsonb,p_channel text,p_draft uuid,p_checkout_mode text
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare data jsonb;existing_mode text;existing_status text;moon_check jsonb;moon_attached jsonb;
 v_require_review boolean;v_actor uuid:=auth.uid();v_order uuid;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_checkout_mode not in ('pay_now','pay_later') then raise exception 'invalid_checkout_mode';end if;
 moon_check:=private.yt_moon_preorder_summary(p_draft,p_items);
 if not coalesce((moon_check->>'can_submit')::boolean,false) then raise exception 'moon_preorder_not_ready';end if;
 data:=private.yt_pos_create_order_with_rewards(p_request,p_table,p_note,p_items,p_channel,p_draft);
 v_order:=(data->>'id')::uuid;
 if not coalesce((data->>'idempotent')::boolean,false) then
  moon_attached:=private.yt_moon_preorder_attach(p_draft,v_order);
  data:=data||jsonb_build_object('moon_cart',moon_attached);
 end if;
 select checkout_mode,status into existing_mode,existing_status
 from public.yt_member_orders where id=v_order for update;
 if (data->>'idempotent')::boolean and existing_mode<>p_checkout_mode then raise exception 'request_conflict';end if;
 if not coalesce((data->>'idempotent')::boolean,false) and p_channel='staff' and existing_status='pending' then
  select coalesce((select require_review from public.yt_pos_order_review_settings where singleton),true)
   into v_require_review;
  if not v_require_review then
   update public.yt_member_orders set status='confirmed',accepted_by=v_actor,accepted_at=clock_timestamp(),updated_at=clock_timestamp()
    where id=v_order;
   if not private.yt_store_box_order_only(v_order) then
    insert into public.yt_pos_order_chits(order_id) values(v_order)
    on conflict(order_id) do update set status='queued',issued_at=clock_timestamp(),printed_at=null,printed_by=null;
   end if;
   insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note)
   values(v_order,v_actor,'accepted','system','Owner disabled Staff order review');
   insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
   values(v_actor,'pos.order_auto_accepted','pos_order',v_order,jsonb_build_object('approval_required',false));
   existing_status:='confirmed';
  end if;
 end if;
 update public.yt_member_orders set checkout_mode=p_checkout_mode where id=v_order;
 return data||jsonb_build_object('status',existing_status,'checkout_mode',p_checkout_mode);
end $$;

revoke all on function private.yt_pos_create_order_with_rewards_v2(uuid,text,text,jsonb,text,uuid,text) from public,anon;
grant execute on function private.yt_pos_create_order_with_rewards_v2(uuid,text,text,jsonb,text,uuid,text) to authenticated;
