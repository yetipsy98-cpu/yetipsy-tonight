-- One atomic bill response: the printed amount includes currently valid holds.
create function private.yt_pos_bill_v8(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare b jsonb; q jsonb; paid boolean; items jsonb; discounts jsonb; amount numeric;
begin
 b=private.yt_pos_receipt(p_order);q=private.yt_pos_cart_summary(p_order);paid=b->>'payment_status'='paid';
 amount=case when paid then (b->>'amount_rm')::numeric else (q->>'payable_rm')::numeric end;
 select coalesce(jsonb_agg(jsonb_build_object('item_name',i.item_name,'quantity',i.quantity,'unit_price_rm',i.unit_price_rm,
  'discount_rm',d.final+d.held,'line_total_rm',i.quantity*i.unit_price_rm-d.final-d.held) order by i.item_name,i.id),'[]'::jsonb)
 into items from public.yt_member_order_items i
 cross join lateral(select
  coalesce((select sum(u.reward_discount_rm) from public.yt_pos_item_units u where u.order_item_id=i.id),0) final,
  case when paid then 0 else coalesce((select sum(h.discount_rm) from public.yt_pos_reward_holds h
    where h.order_item_id=i.id and h.order_id=p_order and h.state='ready' and h.expires_at>clock_timestamp()),0) end held) d
 where i.order_id=p_order;
 select coalesce(jsonb_agg(jsonb_build_object('reward_name',x.reward_name,'item_name',x.item_name,'discount_rm',x.discount_rm)),'[]'::jsonb)
 into discounts from (
  select r.name reward_name,i.item_name,sum(u.reward_discount_rm) discount_rm
  from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id
  join public.redemptions rd on rd.id=u.reward_redemption_id join public.user_rewards ur on ur.id=rd.user_reward_id
  join public.rewards r on r.id=ur.reward_id where i.order_id=p_order group by rd.id,r.name,i.id,i.item_name
  union all
  select r.name,i.item_name,h.discount_rm from public.yt_pos_reward_holds h join public.rewards r on r.id=h.reward_id
   left join public.yt_member_order_items i on i.id=h.order_item_id
   where h.order_id=p_order and not paid and h.state='ready' and h.expires_at>clock_timestamp()
 ) x;
 return b||jsonb_build_object('items',items,'discounts',discounts,'amount_rm',amount,
  'discount_total_rm',greatest(0,(b->>'gross_total_rm')::numeric-amount),
  'discount_pending',not paid and (q->>'reserved_discount_rm')::numeric>0,
  'unresolved_count',(q->>'unresolved_count')::integer,'minimum_met',q->'minimum_met');
end;$$;
create function public.yt_pos_bill_v8(p_order uuid) returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_bill_v8(p_order);$$;
revoke all on function private.yt_pos_bill_v8(uuid),public.yt_pos_bill_v8(uuid) from public,anon;
grant execute on function private.yt_pos_bill_v8(uuid),public.yt_pos_bill_v8(uuid) to authenticated;
