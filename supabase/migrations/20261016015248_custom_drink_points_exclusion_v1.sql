-- Custom products count as paid drink units but never earn member-binding points.
update public.yt_shop_products set is_drink=true,updated_at=clock_timestamp() where category='CUSTOM' and is_drink is distinct from true;
create or replace function private.yt_play_grant_member_binding_points(p_order uuid, p_customer uuid)
returns bigint language plpgsql security definer set search_path=''
as $function$
declare o public.yt_member_orders%rowtype; b public.yt_play_consumption_bindings%rowtype;
 cfg public.yt_loyalty_config%rowtype; n bigint; v_exp timestamptz; v_entry uuid;
 v_custom_amount numeric:=0; v_eligible_amount numeric:=0;
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
 select coalesce(sum(i.quantity*i.unit_price_rm),0) into v_custom_amount
 from public.yt_member_order_items i join public.yt_pos_custom_drinks d on d.product_id=i.product_id
 where i.order_id=p_order;
 v_eligible_amount:=greatest(0,o.amount_rm-v_custom_amount);
 n:=floor(v_eligible_amount*cfg.pos_member_binding_percent*cfg.points_per_rm/100)::bigint;
 if n<1 then return 0;end if;
 perform private.yt_points_sync(p_customer);
 v_exp:=case when cfg.points_validity_days>0 then clock_timestamp()+make_interval(days=>cfg.points_validity_days) else null end;
 insert into public.yt_point_entries(customer_id,direction,points,reference,spend_amount_rm,
   max_budget_points,conversion_points_per_rm,remaining_points,expires_at,source)
 values(p_customer,'earn',n,'POS-MEMBER:'||p_order::text,v_eligible_amount,n,cfg.points_per_rm,n,v_exp,'pos_member_binding')
 on conflict(reference) where source='pos_member_binding' and direction='earn' do nothing
 returning id into v_entry;
 if v_entry is null then return 0;end if;
 update public.yt_point_wallets set balance=balance+n,lifetime_earned=lifetime_earned+n,
   updated_at=clock_timestamp() where customer_id=p_customer;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(p_customer,'points.pos_member_binding','pos_order',p_order,
   jsonb_build_object('amount_rm',v_eligible_amount,'excluded_custom_rm',v_custom_amount,
    'percent',cfg.pos_member_binding_percent,'points',n,'entry_id',v_entry));
 return n;
end $function$;
