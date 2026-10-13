-- One shared pre-order redemption channel for Wallet and Moon guest codes.
-- Moon codes are held while the cart is open, attached atomically when the order is submitted,
-- and formally redeemed only by the existing checkout trigger.
create table if not exists public.yt_moon_preorder_holds (
 id uuid primary key default gen_random_uuid(),
 draft_id uuid not null,
 operator_id uuid not null references auth.users(id),
 code_id uuid not null references public.yt_moon_guest_codes(id),
 drink_name text,
 state text not null default 'held' check(state in ('held','attached','released')),
 expires_at timestamptz not null default (clock_timestamp()+interval '20 minutes'),
 attached_order_id uuid references public.yt_member_orders(id),
 created_at timestamptz not null default clock_timestamp(),
 constraint moon_preorder_drink_length check(drink_name is null or length(drink_name) between 2 and 110)
);
create unique index if not exists yt_moon_preorder_one_hold on public.yt_moon_preorder_holds(code_id) where state='held';
create index if not exists yt_moon_preorder_draft_idx on public.yt_moon_preorder_holds(operator_id,draft_id,state);
alter table public.yt_moon_preorder_holds enable row level security;
revoke all on table public.yt_moon_preorder_holds from public,anon,authenticated;

create or replace function private.yt_moon_preorder_scan(p_draft uuid,p_code text,p_cart jsonb,p_drink text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=auth.uid();v_code text;v public.yt_moon_guest_codes%rowtype;
 hold_id uuid;v_paid int;v_gross numeric;v_name text;v_now timestamptz:=clock_timestamp();attempts int;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_draft is null or p_cart is null then raise exception 'invalid_draft';end if;
 select gross_rm,paid_drinks into v_gross,v_paid from private.yt_pos_draft_price(p_cart);
 if v_paid<1 or v_gross<=0 then raise exception 'minimum_one_paid_drink';end if;
 insert into private.yt_redeem_code_attempts as a(operator_id,window_started_at,attempts)
 values(v_actor,v_now,1) on conflict(operator_id) do update set
 attempts=case when a.window_started_at<=v_now-interval '1 minute' then 1 else least(a.attempts+1,26) end,
 window_started_at=case when a.window_started_at<=v_now-interval '1 minute' then v_now else a.window_started_at end
 returning a.attempts into attempts;
 if attempts>25 then return jsonb_build_object('error_code','short_code_rate_limited');end if;
 begin v_code:=private.yt_moon_norm(p_code);
 exception when others then return jsonb_build_object('error_code','moon_invalid_code');end;
 perform pg_advisory_xact_lock(hashtextextended('moon:'||v_code,0));
 select * into v from public.yt_moon_guest_codes where code=v_code for update;
 if not found then return jsonb_build_object('error_code','moon_code_not_found');end if;
 if v.status='redeemed' then return jsonb_build_object('error_code','moon_already_redeemed');end if;
 if v.status<>'available' then return jsonb_build_object('error_code','moon_reserved_elsewhere');end if;
 if v.valid_until<(v_now at time zone 'Asia/Kuala_Lumpur')::date then return jsonb_build_object('error_code','moon_expired');end if;
 if v.issued_on>(v_now at time zone 'Asia/Kuala_Lumpur')::date then return jsonb_build_object('error_code','moon_not_started');end if;
 if v.kind in ('R5','R4') and length(btrim(coalesce(p_drink,'')))<2 then
  return jsonb_build_object('requires_drink',true,'code',v_code,'kind',v.kind,
   'label',case when v.kind='R5' then '断片指南' else '微醺特调' end);
 end if;
 v_name:=case when v.kind='R3' then '彩虹 Shot' when v.kind in ('R5','R4') then btrim(p_drink) else null end;
 if v_name is not null and length(v_name)>110 then raise exception 'moon_drink_required';end if;
 update public.yt_moon_preorder_holds set state='released'
 where code_id=v.id and state='held' and expires_at<=v_now;
 select id into hold_id from public.yt_moon_preorder_holds
 where code_id=v.id and state='held' and operator_id=v_actor and draft_id=p_draft for update;
 if hold_id is not null then
  return jsonb_build_object('id',hold_id,'code',v_code,'kind',v.kind,'drink',v_name,'idempotent',true);
 end if;
 if exists(select 1 from public.yt_moon_preorder_holds where code_id=v.id and state='held')
 then return jsonb_build_object('error_code','moon_reserved_elsewhere');end if;
 insert into public.yt_moon_preorder_holds(draft_id,operator_id,code_id,drink_name)
 values(p_draft,v_actor,v.id,v_name) returning id into hold_id;
 return jsonb_build_object('id',hold_id,'code',v_code,'kind',v.kind,'drink',v_name,'idempotent',false);
end $$;

create or replace function private.yt_moon_preorder_summary(p_draft uuid,p_cart jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare original jsonb;rows jsonb:='[]'::jsonb;discount numeric:=0;bad int:=0;h record;
 balance numeric;gross numeric;paid int;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 original:=private.yt_pos_preorder_summary(p_draft,p_cart);
 gross:=coalesce((original->>'purchased_gross_rm')::numeric,0);
 paid:=coalesce((original->>'paid_drinks')::integer,0);
 for h in
  select ph.*,c.code,c.kind,c.issued_on,c.valid_until,c.status code_status from public.yt_moon_preorder_holds ph
  join public.yt_moon_guest_codes c on c.id=ph.code_id
  where ph.operator_id=auth.uid() and ph.draft_id=p_draft and ph.state='held'
  order by ph.created_at,ph.id
 loop
  if h.expires_at<=clock_timestamp() or h.code_status<>'available' or
     h.issued_on>(clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date or
     h.valid_until<(clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date then bad:=bad+1;
  elsif h.kind='R0' then discount:=discount+5;
  end if;
  rows:=rows||jsonb_build_array(jsonb_build_object('id',h.id,'source','moon','code',h.code,
   'state',case when h.expires_at>clock_timestamp() and h.code_status='available' then 'chosen' else 'expired' end,
   'kind',h.kind,'reward_name',case h.kind when 'R0' then 'Moon RM5 Voucher' when 'R3' then 'Moon 彩虹 Shot' when 'R5' then 'Moon 断片指南' else 'Moon 微醺特调' end,
   'chosen_product_name',h.drink_name,'discount_rm',case when h.kind='R0' then 5 else 0 end,
   'discount_type',case when h.kind='R0' then 'fixed' else 'free' end,
   'valid',h.expires_at>clock_timestamp() and h.code_status='available','expires_at',h.expires_at));
 end loop;
 balance:=greatest(0,(original->>'payable_rm')::numeric-discount);
 return original||jsonb_build_object(
  'moon_holds',rows,'holds',coalesce(original->'holds','[]'::jsonb)||rows,
  'reserved_discount_rm',(original->>'reserved_discount_rm')::numeric+discount,
  'payable_rm',balance,'unresolved_count',coalesce((original->>'unresolved_count')::int,0)+bad,
  'can_submit',coalesce((original->>'can_submit')::boolean,false) and bad=0 and
   (jsonb_array_length(rows)=0 or (paid>=1 and gross>=discount+0.01 and balance>0))
 );
end $$;
create or replace function private.yt_moon_preorder_release(p_hold uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare h public.yt_moon_preorder_holds%rowtype;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select * into h from public.yt_moon_preorder_holds where id=p_hold and operator_id=auth.uid() for update;
 if not found or h.state not in('held','released') then raise exception 'moon_preorder_hold_not_found';end if;
 update public.yt_moon_preorder_holds set state='released' where id=p_hold and state='held';
 return jsonb_build_object('id',p_hold,'released',true);
end $$;
create or replace function private.yt_moon_preorder_attach(p_draft uuid,p_order uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.yt_member_orders%rowtype;h record; v public.yt_moon_guest_codes%rowtype;
 item uuid;count_attached int:=0;discount numeric:=0;total_discount numeric;paid_drinks int;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 perform pg_advisory_xact_lock(hashtextextended('yt-pos-draft:'||auth.uid()::text||':'||p_draft::text,0));
 select * into o from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found or o.created_by<>auth.uid() or o.payment_status<>'unpaid' or o.status not in ('pending','confirmed')
 then raise exception 'order_not_available_for_preorder';end if;
 if exists(select 1 from public.yt_moon_preorder_holds where draft_id=p_draft and operator_id=auth.uid()
  and state='attached' and attached_order_id<>p_order) then raise exception 'request_conflict';end if;
 select count(*) into count_attached from public.yt_moon_preorder_holds
 where draft_id=p_draft and operator_id=auth.uid() and state='attached' and attached_order_id=p_order;
 for h in select ph.id,ph.code_id,ph.drink_name from public.yt_moon_preorder_holds ph
 where ph.draft_id=p_draft and ph.operator_id=auth.uid() and ph.state='held' order by ph.id for update loop
  select * into v from public.yt_moon_guest_codes where id=h.code_id for update;
  if not found or v.status<>'available' then raise exception 'moon_reserved_elsewhere';end if;
  if v.issued_on>(clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date then raise exception 'moon_not_started';end if;
  if v.valid_until<(clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date then raise exception 'moon_expired';end if;
  if not exists(select 1 from public.yt_moon_preorder_holds where id=h.id and expires_at>clock_timestamp()) then raise exception 'moon_expired';end if;
  if v.kind in ('R5','R4','R3') then
   insert into public.yt_member_order_items(order_id,item_name,quantity,unit_price_rm,is_drink_at_order)
   values(p_order,coalesce(h.drink_name,'彩虹 Shot')||' · Moon 赠品',1,0,false) returning id into item;
   insert into public.yt_pos_item_units(order_item_id,unit_number) values(item,1);
  else
   discount:=discount+5;item:=null;
  end if;
  update public.yt_moon_guest_codes set status='reserved',reserved_order_id=p_order,reserved_item_id=item where id=v.id;
  update public.yt_moon_preorder_holds set state='attached',attached_order_id=p_order where id=h.id;
  count_attached:=count_attached+1;
 end loop;
 if count_attached>0 then
  select coalesce(sum(discount_rm),0) into total_discount
   from public.yt_pos_reward_holds where order_id=p_order and state='ready';
  if discount>0 and o.amount_rm<=discount+total_discount then raise exception 'moon_minimum_payable';end if;
  select (private.yt_pos_order_minimum(p_order)->>'paid_drinks')::int into paid_drinks;
  if paid_drinks<1 then raise exception 'minimum_one_paid_drink';end if;
  if o.status='confirmed' then
   insert into public.yt_pos_order_chits(order_id) values(p_order)
   on conflict(order_id) do update set status='queued',issued_at=clock_timestamp(),printed_at=null,printed_by=null;
  end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(auth.uid(),'moon.preorder_attached','pos_order',p_order,jsonb_build_object('codes',count_attached,'r0_discount_rm',discount));
 end if;
 return jsonb_build_object('attached',count_attached,'discount_rm',discount,'idempotent',discount=0 and count_attached=0);
end $$;
create or replace function private.yt_pos_create_order_with_rewards_v3(
 p_request uuid,p_table text,p_note text,p_items jsonb,p_channel text,p_draft uuid,p_checkout_mode text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare data jsonb;moon jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if not exists(select 1 from private.yt_pos_draft_submissions where operator_id=auth.uid() and request_id=p_request)
  and not (private.yt_moon_preorder_summary(p_draft,p_items)->>'can_submit')::boolean
 then raise exception 'minimum_purchase_not_met';end if;
 data:=private.yt_pos_create_order_with_rewards_v2(p_request,p_table,p_note,p_items,p_channel,p_draft,p_checkout_mode);
 moon:=private.yt_moon_preorder_attach(p_draft,(data->>'id')::uuid);
 return data||jsonb_build_object('moon_preorder',moon);
end $$;
create or replace function public.yt_moon_preorder_scan(p_draft uuid,p_code text,p_cart jsonb,p_drink text default null)
returns jsonb language sql security invoker set search_path='' as $$select private.yt_moon_preorder_scan(p_draft,p_code,p_cart,p_drink)$$;
create or replace function public.yt_moon_preorder_summary(p_draft uuid,p_cart jsonb)
returns jsonb language sql security invoker set search_path='' as $$select private.yt_moon_preorder_summary(p_draft,p_cart)$$;
create or replace function public.yt_moon_preorder_release(p_hold uuid)
returns jsonb language sql security invoker set search_path='' as $$select private.yt_moon_preorder_release(p_hold)$$;
create or replace function public.yt_pos_create_order_with_rewards_v3(
 p_request uuid,p_table text,p_note text,p_items jsonb,p_channel text,p_draft uuid,p_checkout_mode text)
returns jsonb language sql security invoker set search_path='' as $$
select private.yt_pos_create_order_with_rewards_v3(p_request,p_table,p_note,p_items,p_channel,p_draft,p_checkout_mode)$$;
revoke all on function private.yt_moon_preorder_scan(uuid,text,jsonb,text),private.yt_moon_preorder_summary(uuid,jsonb),
 private.yt_moon_preorder_release(uuid),private.yt_moon_preorder_attach(uuid,uuid),
 private.yt_pos_create_order_with_rewards_v3(uuid,text,text,jsonb,text,uuid,text),
 public.yt_moon_preorder_scan(uuid,text,jsonb,text),public.yt_moon_preorder_summary(uuid,jsonb),
 public.yt_moon_preorder_release(uuid),public.yt_pos_create_order_with_rewards_v3(uuid,text,text,jsonb,text,uuid,text)
 from public,anon,authenticated;
grant execute on function private.yt_moon_preorder_scan(uuid,text,jsonb,text),private.yt_moon_preorder_summary(uuid,jsonb),
 private.yt_moon_preorder_release(uuid),private.yt_moon_preorder_attach(uuid,uuid),
 private.yt_pos_create_order_with_rewards_v3(uuid,text,text,jsonb,text,uuid,text),
 public.yt_moon_preorder_scan(uuid,text,jsonb,text),public.yt_moon_preorder_summary(uuid,jsonb),
 public.yt_moon_preorder_release(uuid),public.yt_pos_create_order_with_rewards_v3(uuid,text,text,jsonb,text,uuid,text)
 to authenticated;
