-- Revenue follows actual receipts and refunds, rather than the revised bill amount.
CREATE OR REPLACE FUNCTION private.yt_owner_report_v8(p_start date, p_end date, p_member_page integer DEFAULT 1, p_search text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare today date:=private.yt_business_day(now());
 a timestamptz;z timestamptz;t timestamptz;m timestamptz; result jsonb; stats jsonb; days jsonb; pay jsonb; products jsonb; orders jsonb; members jsonb; member_total bigint;
begin
 if not private.yt_has_role('owner') or not private.yt_pos_work_staff() then raise exception 'owner_only';end if;
 if p_start is null or p_end is null or p_start>p_end or p_end-p_start>365 or p_member_page is null or p_member_page<1 or p_member_page>10000 or p_search is null or length(p_search)>80 then raise exception 'invalid_report_range';end if;
 a=private.yt_business_start(p_start);z=private.yt_business_start(p_end+1);
 t=private.yt_business_start(today);m=private.yt_business_start(date_trunc('month',today::timestamp)::date);
 select jsonb_build_object('today_amount',coalesce(sum(amount_rm) filter(where business_day=today),0),
  'today_orders',count(distinct order_id) filter(where business_day=today),
  'month_amount',coalesce(sum(amount_rm) filter(where business_day>=date_trunc('month',today::timestamp)::date and business_day<(date_trunc('month',today::timestamp)+interval '1 month')::date),0),
  'month_orders',count(distinct order_id) filter(where business_day>=date_trunc('month',today::timestamp)::date and business_day<(date_trunc('month',today::timestamp)+interval '1 month')::date))
 into stats from public.yt_pos_payment_entries where business_day>=date_trunc('month',today::timestamp)::date;
 select stats||jsonb_build_object('range_amount',coalesce(sum(e.amount_rm),0),'range_orders',count(distinct e.order_id),
  'average_order',case when count(distinct e.order_id)>0 then round(sum(e.amount_rm)/count(distinct e.order_id),2) else 0 end) into stats
 from public.yt_pos_payment_entries e where business_day between p_start and p_end;
 select stats||jsonb_build_object('range_gross',coalesce(sum(i.gross),0),'range_discount',coalesce(sum(i.gross-o.amount_rm),0),
  'range_items',coalesce(sum(i.quantity),0)) into stats
 from public.yt_member_orders o cross join lateral(select coalesce(sum(quantity*unit_price_rm),0) gross,coalesce(sum(quantity),0) quantity from public.yt_member_order_items where order_id=o.id and quantity>0) i
 where o.source='future_pos' and o.payment_status='paid' and o.status='fulfilled' and o.paid_at>=a and o.paid_at<z;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.day),'[]'::jsonb) into days from(
  select business_day as day,count(distinct order_id) orders,sum(amount_rm) amount_rm
  from public.yt_pos_payment_entries where business_day between p_start and p_end group by 1) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.amount_rm desc),'[]'::jsonb) into pay from(
  select method,count(distinct order_id) orders,sum(amount_rm) amount_rm
  from public.yt_pos_payment_entries where business_day between p_start and p_end group by 1) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.quantity desc,x.item_name),'[]'::jsonb) into products from(
  select i.product_id,i.item_name,sum(i.quantity) quantity,sum(i.quantity*i.unit_price_rm) gross_rm,
   sum(i.quantity*i.unit_price_rm-coalesce(u.discount,0)) net_rm
  from public.yt_member_order_items i join public.yt_member_orders o on o.id=i.order_id
  left join lateral(select sum(reward_discount_rm) discount from public.yt_pos_item_units where order_item_id=i.id and not retired and unit_number<=i.quantity) u on true
  where o.source='future_pos' and o.payment_status='paid' and o.status='fulfilled' and o.paid_at>=a and o.paid_at<z and i.quantity>0
  group by i.product_id,i.item_name order by quantity desc,i.item_name limit 20) x;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.paid_at desc),'[]'::jsonb) into orders from(
  select o.id,o.order_no,o.table_label,max(e.received_at) paid_at,string_agg(distinct e.method,', ' order by e.method) payment_method,sum(e.amount_rm) amount_rm
  from public.yt_pos_payment_entries e join public.yt_member_orders o on o.id=e.order_id
  where e.business_day between p_start and p_end group by o.id order by max(e.received_at) desc,o.id limit 50) x;
 select count(*) into member_total from public.pin_accounts p left join public.profiles f on f.id=p.auth_user_id
 where not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)
 and (p_search='' or position(lower(p_search) in lower(coalesce(f.display_name,'')||' '||p.phone))>0);
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id),'[]'::jsonb) into members from(
  select p.auth_user_id id,p.phone,coalesce(nullif(f.display_name,''),'会员') display_name,p.created_at,
   coalesce(w.balance,0) points,
   (select count(*) from public.user_rewards r where r.customer_id=p.auth_user_id and r.status='available' and r.expires_at>now()) wallet_rewards,
   (select count(*) from public.game_passes g where g.customer_id=p.auth_user_id and g.status='claimed' and g.expires_at>now()) game_passes,
   (select coalesce(sum(i.unit_price_rm-u.reward_discount_rm),0) from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id join public.yt_member_orders o on o.id=i.order_id
     where u.assigned_customer_id=p.auth_user_id and not u.retired and u.unit_number<=i.quantity and o.payment_status='paid' and o.source='future_pos') attributed_amount,
   greatest((select max(claimed_at) from public.game_passes where customer_id=p.auth_user_id),
    (select max(started_at) from public.game_sessions where customer_id=p.auth_user_id),
    (select max(redeemed_at) from public.redemptions where customer_id=p.auth_user_id)) last_activity
  from public.pin_accounts p left join public.profiles f on f.id=p.auth_user_id left join public.yt_point_wallets w on w.customer_id=p.auth_user_id
  where not exists(select 1 from public.work_accounts wa where wa.auth_user_id=p.auth_user_id)
   and (p_search='' or position(lower(p_search) in lower(coalesce(f.display_name,'')||' '||p.phone))>0)
  order by p.created_at desc,p.auth_user_id limit 40 offset (p_member_page-1)*40) x;
 result=jsonb_build_object('financial_source','payment_ledger','generated_at',now(),'timezone','Asia/Kuala_Lumpur','start',p_start,'end',p_end,'stats',stats,'days',days,'payments',pay,'products',products,'orders',orders,
  'members',members,'member_page',p_member_page,'member_page_size',40,'member_filtered_total',member_total,
  'member_stats',jsonb_build_object(
   'total',(select count(*) from public.pin_accounts p where not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)),
   'month_new',(select count(*) from public.pin_accounts p where created_at>=m and created_at<private.yt_business_start(today+1) and not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)),
   'active_30d',(select count(distinct customer_id) from(
     select customer_id from public.game_passes where claimed_at>=now()-interval '30 days'
     union select customer_id from public.game_sessions where started_at>=now()-interval '30 days'
     union select customer_id from public.redemptions where redeemed_at>=now()-interval '30 days') q where customer_id is not null and exists(select 1 from public.pin_accounts pa where pa.auth_user_id=q.customer_id) and not exists(select 1 from public.work_accounts wa where wa.auth_user_id=q.customer_id)),
   'point_balance',(select coalesce(sum(balance),0) from public.yt_point_wallets)),
  'live',jsonb_build_object(
   'pending_orders',(select count(*) from public.yt_member_orders where source='future_pos' and status='pending' and payment_status='unpaid'),
   'preparing_orders',(select count(*) from public.yt_member_orders where source='future_pos' and status='confirmed' and payment_status='unpaid'),
   'unpaid_orders',(select count(*) from public.yt_member_orders where source='future_pos' and status='fulfilled' and payment_status='unpaid'),
   'active_products',(select count(*) from public.yt_shop_products where active),
   'active_series',(select count(*) from public.yt_pos_series where active and benefit_mode in('games','choose') and game_plays=1),
   'active_campaigns',(select count(*) from public.campaigns where active and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>now())),
   'active_rewards',(select count(*) from public.rewards r where r.active and exists(select 1 from public.yt_pos_reward_rules b where b.reward_id=r.id and b.mode<>'disabled')),
   'unbound_rewards',(select count(*) from public.rewards r where r.active and not exists(select 1 from public.yt_pos_reward_rules b where b.reward_id=r.id and b.mode<>'disabled')),
   'active_banners',(select count(*) from public.yt_home_banners where enabled),
   'work_accounts',(select count(*) from public.work_accounts where active),
   'unclaimed_passes',(select count(*) from public.game_passes where status='issued' and expires_at>now()),
   'claimed_passes',(select count(*) from public.game_passes where status='claimed' and expires_at>now()),
   'open_game_sessions',(select count(*) from public.game_sessions where status='started' and started_at>=now()-interval '1 day'),
   'wallet_rewards',(select count(*) from public.user_rewards where status='available' and expires_at>now()),
   'expiring_rewards',(select count(*) from public.user_rewards where status='available' and expires_at>now() and expires_at<=now()+interval '7 days'),
   'active_offers',(select count(*) from public.reward_offers where active and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>now()) and (max_claims is null or claimed_count<max_claims)),
   'held_rewards',(select count(*) from public.yt_pos_reward_holds where state in('reserved','ready') and expires_at>now()),
   'low_stock_pool_entries',(select count(*) from public.reward_pool_entries p join public.campaigns c on c.id=p.campaign_id where c.active and p.weight>0 and p.max_total is not null and p.max_total-p.issued_total<=5)),
  'reward_activity',jsonb_build_object(
   'issued',(select count(*) from public.user_rewards where created_at>=a and created_at<z),
   'redeemed',(select count(*) from public.redemptions where redeemed_at>=a and redeemed_at<z),
   'passes_claimed',(select count(*) from public.game_passes where claimed_at>=a and claimed_at<z),
   'games_completed',(select count(*) from public.game_sessions where status='completed' and completed_at>=a and completed_at<z),
   'points_earned',(select coalesce(sum(points),0) from public.yt_point_entries where direction='earn' and created_at>=a and created_at<z),
   'points_spent',(select coalesce(sum(points),0) from public.yt_point_entries where direction='spend' and created_at>=a and created_at<z)));
 result=result||jsonb_build_object(
  'months',coalesce((select jsonb_agg(to_jsonb(x) order by x.month) from(
   select to_char(business_day,'YYYY-MM') as month,count(distinct order_id) orders,sum(amount_rm) amount_rm
   from public.yt_pos_payment_entries where business_day between p_start and p_end group by 1) x),'[]'::jsonb),
  'cashiers',coalesce((select jsonb_agg(to_jsonb(x) order by x.amount_rm desc) from(
   select coalesce(w.username,'原工作账号') username,count(distinct e.order_id) orders,sum(e.amount_rm) amount_rm
   from public.yt_pos_payment_entries e left join public.work_accounts w on w.auth_user_id=e.actor_id
   where e.business_day between p_start and p_end group by w.username) x),'[]'::jsonb),
  'reward_types',coalesce((select jsonb_agg(to_jsonb(x) order by x.reward_name) from(
   select r.name reward_name,
    (select count(*) from public.user_rewards u where u.reward_id=r.id and u.created_at>=a and u.created_at<z) issued,
    (select count(*) from public.user_rewards u join public.redemptions d on d.user_reward_id=u.id where u.reward_id=r.id and d.redeemed_at>=a and d.redeemed_at<z) redeemed,
    (select count(*) from public.user_rewards u where u.reward_id=r.id and u.status='available' and u.expires_at>now()) outstanding,
    (select count(*) from public.user_rewards u where u.reward_id=r.id and u.status='available' and u.expires_at>now() and u.expires_at<=now()+interval '7 days') expiring
   from public.rewards r order by r.name,r.id limit 100) x),'[]'::jsonb));
 return result||jsonb_build_object('business_day',today);
end;$function$

;
