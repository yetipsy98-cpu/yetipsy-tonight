-- Read-only, Cashier/Owner-only order benefit summaries for the POS receipts view.
create or replace function private.yt_pos_order_benefit_summaries(p_orders uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare result jsonb;
begin
 if auth.uid() is null or (not private.yt_pos_work_cashier() and not private.yt_work_owner()) then
  raise exception 'cashier_only';
 end if;
 if p_orders is null or cardinality(p_orders)=0 then return '{}'::jsonb; end if;

 select coalesce(jsonb_object_agg(s.order_id::text,s.summary),'{}'::jsonb)
 into result
 from (
  select o.id order_id,
   jsonb_build_object(
    'processed',
      coalesce(b.source in ('pos_qr','member_qr','gamepass','lucky_box'),false)
      or coalesce(points.points,0)>0
      or coalesce(lucky.claimed_points,0)>0,
    'mode',case b.source
      when 'gamepass' then 'GamePass'
      when 'lucky_box' then 'Lucky Box'
      when 'pos_qr' then '会员积分'
      when 'member_qr' then '会员积分'
      else '权益' end,
    'member_name',coalesce(nullif(profile.display_name,''),nullif(account.phone,''),'会员'),
    'points_earned',coalesce(points.points,0),
    'points_balance',coalesce(wallet.balance,0),
    'lucky_points',coalesce(lucky.points,0),
    'lucky_claimed_points',coalesce(lucky.claimed_points,0),
    'gamepass_claimed_count',coalesce(passes.claimed_count,0)
   ) summary
  from public.yt_member_orders o
  left join lateral (
   select b.customer_id,b.source
   from public.yt_play_consumption_bindings b
   where b.order_id=o.id
   order by b.bound_at desc limit 1
  ) b on true
  left join lateral (
   select r.customer_id
   from public.yt_lucky_results r
   where r.order_id=o.id and r.customer_id is not null
   order by r.claimed_at desc limit 1
  ) lucky_member on true
  left join lateral (
   select count(*)::integer claimed_count
   from public.yt_member_order_items i
   join public.yt_pos_item_units u on u.order_item_id=i.id
   join public.game_passes gp on gp.id=u.game_pass_id
   where i.order_id=o.id and gp.customer_id is not null
  ) passes on true
  left join lateral (
   select coalesce(sum(r.points),0)::bigint points,
     coalesce(sum(r.points) filter(where r.customer_id is not null),0)::bigint claimed_points
   from public.yt_lucky_results r where r.order_id=o.id
  ) lucky on true
  left join lateral (
   select coalesce(sum(e.points),0)::bigint points
   from public.yt_point_entries e
   where e.customer_id=coalesce(b.customer_id,o.customer_id,lucky_member.customer_id)
     and e.reference='POS-MEMBER:'||o.id::text
     and e.source='pos_member_binding' and e.direction='earn'
  ) points on true
  left join public.yt_point_wallets wallet
    on wallet.customer_id=coalesce(b.customer_id,o.customer_id,lucky_member.customer_id)
  left join public.profiles profile
    on profile.id=coalesce(b.customer_id,o.customer_id,lucky_member.customer_id)
  left join public.pin_accounts account
    on account.auth_user_id=coalesce(b.customer_id,o.customer_id,lucky_member.customer_id)
  where o.id=any(p_orders) and o.source='future_pos' and o.payment_status='paid'
 ) s;
 return coalesce(result,'{}'::jsonb);
end $$;

revoke all on function private.yt_pos_order_benefit_summaries(uuid[]) from public,anon;
grant execute on function private.yt_pos_order_benefit_summaries(uuid[]) to authenticated;

create or replace function public.yt_pos_order_benefit_summaries(p_orders uuid[])
returns jsonb language sql security invoker set search_path=''
as $$ select private.yt_pos_order_benefit_summaries(p_orders) $$;
revoke all on function public.yt_pos_order_benefit_summaries(uuid[]) from public,anon;
grant execute on function public.yt_pos_order_benefit_summaries(uuid[]) to authenticated;
