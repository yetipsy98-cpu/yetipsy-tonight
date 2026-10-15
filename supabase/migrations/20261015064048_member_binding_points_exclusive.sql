-- POS member binding, pass claims and Lucky Box use one exclusive benefit per order.
alter table public.yt_loyalty_config
  add column if not exists pos_member_binding_percent numeric(5,2) not null default 2.00
  check (pos_member_binding_percent between 0 and 10);

create unique index if not exists yt_pos_member_binding_points_once
  on public.yt_point_entries(reference)
  where source='pos_member_binding' and direction='earn';

create or replace function private.yt_play_binding_choice_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare existing_source text;
begin
 select source into existing_source from public.yt_play_consumption_bindings
 where order_id=new.order_id;
 if found and existing_source='customer_order' and new.source<>'customer_order' then
  update public.yt_play_consumption_bindings set source=new.source where order_id=new.order_id;
  return new;
 end if;
 if found and existing_source<>'customer_order' and new.source<>'customer_order'
   and existing_source<>new.source
   and not (existing_source in ('pos_qr','member_qr') and new.source in ('pos_qr','member_qr')) then
  raise exception 'order_benefit_already_selected';
 end if;
 if new.source in ('pos_qr','member_qr') and (
  exists(select 1 from public.yt_play_consumption_bindings b where b.order_id=new.order_id and b.source in ('gamepass','lucky_box'))
  or exists(select 1 from public.yt_lucky_results r where r.order_id=new.order_id)
  or exists(select 1 from public.yt_member_order_items i join public.yt_pos_item_units u on u.order_item_id=i.id
    join public.game_passes p on p.id=u.game_pass_id
    where i.order_id=new.order_id and p.status not in ('cancelled','revoked','void'))
  or exists(select 1 from public.yt_pos_pass_bundles b where b.order_id=new.order_id and b.status<>'cancelled')
 ) then raise exception 'order_benefit_already_selected';end if;
 return new;
end $$;
drop trigger if exists yt_play_binding_choice_guard on public.yt_play_consumption_bindings;
create trigger yt_play_binding_choice_guard before insert on public.yt_play_consumption_bindings
for each row execute function private.yt_play_binding_choice_guard();

create or replace function private.yt_play_pass_issue_choice_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_order uuid;
begin
 if new.game_pass_id is null or new.game_pass_id is not distinct from old.game_pass_id then return new;end if;
 select order_id into v_order from public.yt_member_order_items where id=new.order_item_id;
 if exists(select 1 from public.yt_play_consumption_bindings b where b.order_id=v_order
   and b.source in ('customer_order','pos_qr','member_qr')) then
  raise exception 'order_benefit_already_selected';
 end if;
 return new;
end $$;
drop trigger if exists yt_play_pass_issue_choice_guard on public.yt_pos_item_units;
create trigger yt_play_pass_issue_choice_guard before update of game_pass_id on public.yt_pos_item_units
for each row execute function private.yt_play_pass_issue_choice_guard();

create or replace function private.yt_play_bundle_issue_choice_guard()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.yt_play_consumption_bindings b where b.order_id=new.order_id
   and b.source in ('customer_order','pos_qr','member_qr')) then
  raise exception 'order_benefit_already_selected';
 end if;
 return new;
end $$;
drop trigger if exists yt_play_bundle_issue_choice_guard on public.yt_pos_pass_bundles;
create trigger yt_play_bundle_issue_choice_guard before insert on public.yt_pos_pass_bundles
for each row execute function private.yt_play_bundle_issue_choice_guard();

create or replace function private.yt_play_grant_member_binding_points(p_order uuid,p_customer uuid)
returns bigint language plpgsql security definer set search_path='' as $$
declare o public.yt_member_orders%rowtype; b public.yt_play_consumption_bindings%rowtype;
 cfg public.yt_loyalty_config%rowtype; n bigint; v_exp timestamptz; v_entry uuid;
begin
 select * into o from public.yt_member_orders where id=p_order and source='future_pos';
 if not found or o.payment_status<>'paid' or o.paid_at is null or o.status in ('cancelled','rejected')
   or o.payment_status='refunded' or o.cancel_after_refund or o.settlement_due_since is not null then return 0;end if;
 select * into b from public.yt_play_consumption_bindings where order_id=p_order and customer_id=p_customer;
 if not found or b.source not in ('pos_qr','member_qr') then return 0;end if;
 if exists(select 1 from public.yt_play_consumption_bindings where order_id=p_order and source in ('gamepass','lucky_box'))
  or exists(select 1 from public.yt_lucky_results where order_id=p_order)
  or exists(select 1 from public.yt_member_order_items i join public.yt_pos_item_units u on u.order_item_id=i.id
    join public.game_passes p on p.id=u.game_pass_id where i.order_id=p_order and p.status not in ('cancelled','revoked','void'))
  or exists(select 1 from public.yt_pos_pass_bundles where order_id=p_order and status<>'cancelled') then return 0;end if;
 select * into cfg from public.yt_loyalty_config where id=true;
 n:=floor(greatest(0,o.amount_rm)*cfg.pos_member_binding_percent*cfg.points_per_rm/100)::bigint;
 if n<1 then return 0;end if;
 perform private.yt_points_sync(p_customer);
 v_exp:=case when cfg.points_validity_days>0 then clock_timestamp()+make_interval(days=>cfg.points_validity_days) else null end;
 insert into public.yt_point_entries(customer_id,direction,points,reference,spend_amount_rm,
   max_budget_points,conversion_points_per_rm,remaining_points,expires_at,source)
 values(p_customer,'earn',n,'POS-MEMBER:'||p_order::text,o.amount_rm,n,cfg.points_per_rm,n,v_exp,'pos_member_binding')
 on conflict(reference) where source='pos_member_binding' and direction='earn' do nothing
 returning id into v_entry;
 if v_entry is null then return 0;end if;
 update public.yt_point_wallets set balance=balance+n,lifetime_earned=lifetime_earned+n,
   updated_at=clock_timestamp() where customer_id=p_customer;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(p_customer,'points.pos_member_binding','pos_order',p_order,
   jsonb_build_object('amount_rm',o.amount_rm,'percent',cfg.pos_member_binding_percent,'points',n,'entry_id',v_entry));
 return n;
end $$;

create or replace function private.yt_play_member_binding_after_insert()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.source in ('pos_qr','member_qr') then
  perform private.yt_play_grant_member_binding_points(new.order_id,new.customer_id);
 end if;
 return new;
end $$;
drop trigger if exists yt_play_member_binding_after_insert on public.yt_play_consumption_bindings;
create trigger yt_play_member_binding_after_insert after insert on public.yt_play_consumption_bindings
for each row execute function private.yt_play_member_binding_after_insert();

create or replace function private.yt_play_member_binding_after_update()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.source in ('pos_qr','member_qr') and old.source is distinct from new.source then
  perform private.yt_play_grant_member_binding_points(new.order_id,new.customer_id);
 end if;
 return new;
end $$;
drop trigger if exists yt_play_member_binding_after_update on public.yt_play_consumption_bindings;
create trigger yt_play_member_binding_after_update after update of source on public.yt_play_consumption_bindings
for each row execute function private.yt_play_member_binding_after_update();

create or replace function private.yt_play_member_points_after_payment()
returns trigger language plpgsql security definer set search_path='' as $$
declare b record;
begin
 if new.source='future_pos' and new.payment_status='paid' and old.payment_status is distinct from 'paid' then
  for b in select customer_id from public.yt_play_consumption_bindings
   where order_id=new.id and source in ('pos_qr','member_qr') loop
   perform private.yt_play_grant_member_binding_points(new.id,b.customer_id);
  end loop;
 end if;
 return new;
end $$;
drop trigger if exists yt_play_z_member_points_paid on public.yt_member_orders;
create trigger yt_play_z_member_points_paid after update of payment_status on public.yt_member_orders
for each row execute function private.yt_play_member_points_after_payment();

create or replace function private.yt_play_unbind_member(p_order uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.yt_member_orders%rowtype; n integer;
begin
 if not (private.yt_pos_work_cashier() or private.yt_work_owner()) then raise exception 'cashier_only';end if;
 select * into o from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 if o.payment_status<>'unpaid' or o.status in ('cancelled','rejected') then raise exception 'binding_cancel_unpaid_orders_only';end if;
 delete from public.yt_play_consumption_bindings where order_id=p_order and source in ('member_qr','pos_qr');
 get diagnostics n=row_count;
 if n=0 then raise exception 'member_binding_not_cancellable';end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(auth.uid(),'pos.member_binding_cancelled','pos_order',p_order,jsonb_build_object('source',o.source));
 return jsonb_build_object('ok',true,'order_id',p_order);
end $$;

create or replace function public.yt_play_unbind_member(p_order uuid)
returns jsonb language sql set search_path='' as $$ select private.yt_play_unbind_member(p_order) $$;
revoke all on function public.yt_play_unbind_member(uuid) from public,anon,authenticated;
grant execute on function private.yt_play_unbind_member(uuid) to authenticated;
grant execute on function public.yt_play_unbind_member(uuid) to authenticated;

create or replace function private.yt_owner_member_points_get()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 return (select jsonb_build_object('percent',pos_member_binding_percent,'points_per_rm',points_per_rm,
   'validity_days',points_validity_days) from public.yt_loyalty_config where id=true);
end $$;
create or replace function private.yt_owner_member_points_save(p_percent numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_percent is null or p_percent<0 or p_percent>10 then raise exception 'invalid_member_points_percent';end if;
 update public.yt_loyalty_config set pos_member_binding_percent=round(p_percent,2),
   updated_by=auth.uid(),updated_at=clock_timestamp() where id=true;
 insert into public.audit_logs(actor_id,action,entity_type,metadata)
 values(auth.uid(),'points.owner_member_binding_rate','points_settings',
   jsonb_build_object('percent',round(p_percent,2)));
 return jsonb_build_object('percent',round(p_percent,2));
end $$;
create or replace function public.yt_owner_member_points_get()
returns jsonb language sql set search_path='' as $$ select private.yt_owner_member_points_get() $$;
create or replace function public.yt_owner_member_points_save(p_percent numeric)
returns jsonb language sql set search_path='' as $$ select private.yt_owner_member_points_save(p_percent) $$;
revoke all on function public.yt_owner_member_points_get(),public.yt_owner_member_points_save(numeric)
 from public,anon,authenticated;
grant execute on function private.yt_owner_member_points_get(),private.yt_owner_member_points_save(numeric) to authenticated;
grant execute on function public.yt_owner_member_points_get(),public.yt_owner_member_points_save(numeric) to authenticated;

create or replace function private.yt_pos_orders(p_scope text default 'active',p_limit integer default 60)
returns jsonb language plpgsql stable security definer set search_path='' as $$
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
   case when b.order_id is not null then jsonb_build_object('source',b.source,
    'member_binding',b.source in ('pos_qr','member_qr'),
    'can_unbind',b.source in ('pos_qr','member_qr') and x.payment_status='unpaid' and x.status not in ('cancelled','rejected'))
    when x.customer_id is not null then jsonb_build_object('source','customer_order','member_binding',false,'can_unbind',false)
    else null end member_binding,
   coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'price_rm',i.unit_price_rm,'fulfilled',i.fulfilled,'store_box_item',exists(select 1 from public.yt_store_box_product_rules sr where sr.product_id=i.product_id and sr.active)) order by i.item_name)
    from public.yt_member_order_items i where i.order_id=x.id and i.quantity>0),'[]'::jsonb) items
  from public.yt_member_orders x left join public.work_accounts wa on wa.auth_user_id=x.created_by
  left join public.yt_play_consumption_bindings b on b.order_id=x.id
  where x.source='future_pos' and ((p_scope='active' and ((x.status in ('pending','confirmed') and x.payment_status in ('unpaid','paid')) or (x.status='fulfilled' and x.payment_status='unpaid')))
   or (p_scope='pending' and x.status='pending') or (p_scope='paid' and x.payment_status in ('paid','refunded')) or p_scope='all' or (p_scope='mine' and x.created_by=auth.uid()))
  order by x.created_at desc limit p_limit
 )o;
 return v_result;
end $$;
create or replace function public.yt_pos_orders(p_scope text default 'active',p_limit integer default 60)
returns jsonb language sql set search_path='' as $$ select private.yt_pos_orders(p_scope,p_limit) $$;
