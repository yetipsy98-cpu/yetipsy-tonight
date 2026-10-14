
alter table public.work_accounts drop constraint if exists work_accounts_role_check;
alter table public.work_accounts add constraint work_accounts_role_check check(role in ('owner','owner_limited','staff','cashier'));
alter table public.staff_roles drop constraint if exists staff_roles_role_check;
alter table public.staff_roles add constraint staff_roles_role_check check(role in ('owner','owner_limited','staff','cashier'));

create or replace function private.yt_owner_limited() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.work_accounts wa join public.staff_roles sr on sr.user_id=wa.auth_user_id
  where wa.auth_user_id=auth.uid() and wa.role='owner_limited' and wa.active and not wa.must_change_password and sr.role='owner_limited' and sr.active)
$$;
create or replace function private.yt_pos_identity() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare a public.work_accounts%rowtype;
begin
 if not private.yt_pos_work_staff() and not private.yt_owner_limited() then raise exception 'staff_only';end if;
 select * into a from public.work_accounts where auth_user_id=auth.uid();
 return jsonb_build_object('username',a.username,'role',a.role,'can_cashier',private.yt_pos_work_cashier(),
  'can_edit_orders',private.yt_pos_work_edit_orders(),'can_owner',a.role='owner' and private.yt_has_role('owner'),
  'can_owner_limited',private.yt_owner_limited());
end $$;

create table public.yt_pos_owner_revision_requests(
 id uuid primary key default gen_random_uuid(),order_id uuid not null references public.yt_member_orders(id) on delete restrict,
 requester_id uuid references auth.users(id) on delete set null,request_payload jsonb not null,
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 reviewer_id uuid references auth.users(id) on delete set null,review_note text,reviewed_at timestamptz,result jsonb,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create unique index yt_pos_revision_requests_one_pending on public.yt_pos_owner_revision_requests(order_id) where status='pending';
create index yt_pos_revision_requests_recent on public.yt_pos_owner_revision_requests(status,created_at desc);
alter table public.yt_pos_owner_revision_requests enable row level security;
revoke all on public.yt_pos_owner_revision_requests from public,anon,authenticated;

create or replace function private.yt_pos_owner_order_context(p_order uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b jsonb;
begin
 if not (private.yt_work_owner() or private.yt_pos_work_cashier()) then raise exception 'owner_only';end if;
 b:=private.yt_pos_bill_v8(p_order);
 return b||jsonb_build_object('items',coalesce((select jsonb_agg(jsonb_build_object('id',id,'product_id',product_id,'name',item_name,'quantity',quantity,'price_rm',unit_price_rm) order by id) from public.yt_member_order_items where order_id=p_order and quantity>0),'[]'::jsonb),
 'benefits',private.yt_pos_order_benefits(p_order),'received_rm',private.yt_pos_received(p_order),
 'revisions',coalesce((select jsonb_agg(to_jsonb(x) order by x.revision desc) from(select revision,reason,created_at,revoke_benefits,before_state->'amount_rm' before_amount,after_state->'amount_rm' after_amount from public.yt_pos_order_revisions where order_id=p_order order by revision desc limit 20)x),'[]'::jsonb));
end $$;
create or replace function private.yt_pos_owner_revision_preview(p_order uuid,p_items jsonb,p_cancel boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v public.yt_member_orders%rowtype;r jsonb;received numeric;
begin
 if not (private.yt_work_owner() or private.yt_pos_work_cashier()) then raise exception 'owner_only';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos';
 if not found or v.status in ('cancelled','refunded') then raise exception 'order_not_editable';end if;
 r:=private.yt_pos_revision_lines(p_order,p_items,p_cancel);received:=private.yt_pos_received(p_order);
 return r||jsonb_build_object('order_id',p_order,'updated_at',v.updated_at,'before_amount_rm',v.amount_rm,'received_rm',received,
 'balance_rm',case when v.payment_status='paid' then (r->>'net')::numeric-received else (r->>'net')::numeric end,'benefits',private.yt_pos_order_benefits(p_order));
end $$;

create or replace function private.yt_pos_owner_revision_request_submit(p_order uuid,p_items jsonb,p_reason text,p_table text,p_note text,p_expected_updated timestamptz,p_cancel boolean,p_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_member_orders%rowtype;clean_items jsonb;payload jsonb;existing public.yt_pos_owner_revision_requests%rowtype;
begin
 if not private.yt_pos_work_cashier() or private.yt_work_owner() then raise exception 'cashier_only';end if;
 if p_order is null or p_request is null or p_expected_updated is null or p_cancel is null or length(btrim(coalesce(p_reason,''))) not between 3 and 300 or length(coalesce(p_table,''))>32 or length(coalesce(p_note,''))>600 then raise exception 'invalid_order_revision';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos';
 if not found or v.status in ('cancelled','refunded') then raise exception 'order_not_editable';end if;
 if p_cancel then clean_items:='[]'::jsonb;
 else
  if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'invalid_order_revision';end if;
  select coalesce(jsonb_agg(value-'unit_price_rm' order by ordinality),'[]'::jsonb) into clean_items from jsonb_array_elements(p_items) with ordinality as i(value,ordinality);
 end if;
 payload:=jsonb_build_object('order',p_order,'items',clean_items,'reason',btrim(p_reason),'table',nullif(btrim(coalesce(p_table,'')),''),'note',nullif(btrim(coalesce(p_note,'')),''),'expected',p_expected_updated,'cancel',p_cancel);
 select * into existing from public.yt_pos_owner_revision_requests where id=p_request;
 if found then if existing.requester_id<>auth.uid() or existing.order_id<>p_order or existing.request_payload<>payload then raise exception 'request_conflict';end if;return jsonb_build_object('id',existing.id,'status',existing.status,'retried',true);end if;
 perform private.yt_pos_owner_revision_preview(p_order,clean_items,p_cancel);
 begin
  insert into public.yt_pos_owner_revision_requests(id,order_id,requester_id,request_payload) values(p_request,p_order,auth.uid(),payload);
 exception when unique_violation then raise exception 'revision_request_already_pending';end;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.revision_requested','pos_order',p_order,jsonb_build_object('request_id',p_request,'cancel',p_cancel,'reason',btrim(p_reason)));
 return jsonb_build_object('id',p_request,'status','pending');
end $$;

create or replace function private.yt_pos_owner_revision_requests_list()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'order_id',q.order_id,'order_no',o.order_no,'table_label',o.table_label,'request_payload',q.request_payload,'status',q.status,'created_at',q.created_at,'reviewed_at',q.reviewed_at,'review_note',q.review_note,'requester_name',coalesce(w.username,'Cashier'),'reviewer_name',coalesce(r.username,'Owner')) order by (q.status='pending') desc,q.created_at desc),'[]'::jsonb)
 into rows from (select * from public.yt_pos_owner_revision_requests order by created_at desc limit 100) q
 join public.yt_member_orders o on o.id=q.order_id left join public.work_accounts w on w.auth_user_id=q.requester_id left join public.work_accounts r on r.auth_user_id=q.reviewer_id;
 return rows;
end $$;

create or replace function private.yt_pos_owner_revision_request_review(p_request uuid,p_approve boolean,p_note text default '',p_revoke boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare q public.yt_pos_owner_revision_requests%rowtype;payload jsonb;applied jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_request is null or p_approve is null or p_revoke is null or length(coalesce(p_note,''))>600 then raise exception 'invalid_request';end if;
 select * into q from public.yt_pos_owner_revision_requests where id=p_request for update;
 if not found then raise exception 'request_not_found';end if;
 if q.status<>'pending' then
  if (q.status='approved' and p_approve) or (q.status='rejected' and not p_approve) then return coalesce(q.result,jsonb_build_object('id',q.id,'status',q.status,'retried',true));end if;
  raise exception 'request_already_reviewed';
 end if;
 payload:=q.request_payload;
 if not p_approve then
  if length(btrim(coalesce(p_note,'')))<2 then raise exception 'review_note_required';end if;
  update public.yt_pos_owner_revision_requests set status='rejected',reviewer_id=auth.uid(),reviewed_at=now(),review_note=btrim(p_note),updated_at=now() where id=q.id;
  applied:=jsonb_build_object('id',q.id,'status','rejected');
 else
  applied:=private.yt_pos_owner_revision_apply(q.order_id,payload->'items',payload->>'reason',payload->>'table',payload->>'note',(payload->>'expected')::timestamptz,q.id,p_revoke,(payload->>'cancel')::boolean);
  update public.yt_pos_owner_revision_requests set status='approved',reviewer_id=auth.uid(),reviewed_at=now(),review_note=nullif(btrim(coalesce(p_note,'')),''),result=applied,updated_at=now() where id=q.id;
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),case when p_approve then 'pos.revision_approved' else 'pos.revision_rejected' end,'pos_order',q.order_id,jsonb_build_object('request_id',q.id,'note',nullif(btrim(coalesce(p_note,'')),''),'revoke_benefits',case when p_approve then p_revoke else false end));
 return applied||jsonb_build_object('id',q.id,'status',case when p_approve then 'approved' else 'rejected' end);
end $$;

create or replace function public.yt_pos_owner_revision_request_submit(p_order uuid,p_items jsonb,p_reason text,p_table text,p_note text,p_expected_updated timestamptz,p_cancel boolean,p_request uuid) returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_owner_revision_request_submit(p_order,p_items,p_reason,p_table,p_note,p_expected_updated,p_cancel,p_request)$$;
create or replace function public.yt_pos_owner_revision_requests_list() returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_owner_revision_requests_list()$$;
create or replace function public.yt_pos_owner_revision_request_review(p_request uuid,p_approve boolean,p_note text default '',p_revoke boolean default false) returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_owner_revision_request_review(p_request,p_approve,p_note,p_revoke)$$;
revoke all on function private.yt_pos_owner_revision_request_submit(uuid,jsonb,text,text,text,timestamptz,boolean,uuid),private.yt_pos_owner_revision_requests_list(),private.yt_pos_owner_revision_request_review(uuid,boolean,text,boolean) from public,anon;
revoke all on function public.yt_pos_owner_revision_request_submit(uuid,jsonb,text,text,text,timestamptz,boolean,uuid),public.yt_pos_owner_revision_requests_list(),public.yt_pos_owner_revision_request_review(uuid,boolean,text,boolean) from public,anon;
grant execute on function private.yt_pos_owner_revision_request_submit(uuid,jsonb,text,text,text,timestamptz,boolean,uuid),private.yt_pos_owner_revision_requests_list(),private.yt_pos_owner_revision_request_review(uuid,boolean,text,boolean) to authenticated;
grant execute on function public.yt_pos_owner_revision_request_submit(uuid,jsonb,text,text,text,timestamptz,boolean,uuid),public.yt_pos_owner_revision_requests_list(),public.yt_pos_owner_revision_request_review(uuid,boolean,text,boolean) to authenticated;

CREATE OR REPLACE FUNCTION private.yt_owner_report_v8(p_start date, p_end date, p_member_page integer DEFAULT 1, p_search text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare today date:=private.yt_business_day(now());
 a timestamptz;z timestamptz;t timestamptz;m timestamptz; result jsonb; stats jsonb; days jsonb; pay jsonb; products jsonb; orders jsonb; members jsonb; member_total bigint;
begin
 if not ((private.yt_has_role('owner') and private.yt_pos_work_staff()) or private.yt_owner_limited()) then raise exception 'owner_only';end if;
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
   (select coalesce(sum(remaining_points),0) from public.yt_point_entries e where e.customer_id=p.auth_user_id and e.direction='earn' and (e.expires_at is null or e.expires_at>clock_timestamp())) points,
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
   'point_balance',(select coalesce(sum(remaining_points),0) from public.yt_point_entries where direction='earn' and (expires_at is null or expires_at>clock_timestamp()))),
  'live',jsonb_build_object(
   'active_point_shop_items',(select count(*) from public.yt_point_shop_items i join public.rewards r on r.id=i.reward_id where i.active and r.active and (i.starts_at is null or i.starts_at<=now()) and (i.ends_at is null or i.ends_at>now()) and (i.stock_limit is null or i.stock_used<i.stock_limit)),
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
   'point_exchanges',(select count(*) from public.yt_point_shop_exchanges where created_at>=a and created_at<z),
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
end;$function$;


CREATE OR REPLACE FUNCTION private.yt_ambassador_pos_issue_portal()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d date:=private.yt_business_day(now()); p jsonb; today jsonb; mine jsonb;
begin
 if auth.uid() is null or not (private.yt_pos_work_cashier() or private.yt_has_role('owner') or private.yt_owner_limited()) then raise exception 'cashier_only';end if;
 select jsonb_build_object('weekday_male',weekday_male,'weekday_female',weekday_female,
  'weekend_male',weekend_male,'weekend_female',weekend_female,
  'specials',coalesce((select jsonb_agg(jsonb_build_object('business_day',s.business_day,'male',s.male_price,'female',s.female_price)
    order by s.business_day) from public.yt_ambassador_special_prices s where s.business_day between d and d+7),'[]'::jsonb))
 into p from public.yt_ambassador_prices where id=true;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'pass_code',x.pass_code,'reservation_day',x.reservation_day,
  'pass_type',x.pass_type,'planned_pax',x.planned_pax,'guest_name',x.guest_name,'guest_phone',x.guest_phone,
  'remark',x.remark,'status',x.status,'created_at',x.created_at,'checked_pax',coalesce(c.checked_pax,0))
  order by x.reservation_day,x.created_at desc),'[]'::jsonb)
 into mine from public.yt_ambassador_passes x
 left join lateral(select sum(ci.male_count+ci.female_count)::integer checked_pax from public.yt_ambassador_checkins ci where ci.pass_id=x.id)c on true
 where x.issued_by=auth.uid() and x.ambassador_id is null;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'pass_code',x.pass_code,'reservation_day',x.reservation_day,
  'pass_type',x.pass_type,'planned_pax',x.planned_pax,'guest_name',x.guest_name,'guest_phone',x.guest_phone,
  'status',x.status,'created_at',x.created_at,'ambassador_name',coalesce(nullif(a.display_name,''),''),
  'issued_by_name',coalesce(nullif(pr.display_name,''),wa.username,'POS'),
  'checked_pax',coalesce(c.checked_pax,0),'checked_male',coalesce(c.checked_male,0),'checked_female',coalesce(c.checked_female,0))
  order by x.created_at),'[]'::jsonb)
 into today from public.yt_ambassador_passes x
 left join public.yt_ambassadors a on a.id=x.ambassador_id
 left join public.work_accounts wa on wa.auth_user_id=x.issued_by
 left join public.profiles pr on pr.id=x.issued_by
 left join lateral(select sum(ci.male_count+ci.female_count)::integer checked_pax,
  sum(ci.male_count)::integer checked_male,sum(ci.female_count)::integer checked_female
  from public.yt_ambassador_checkins ci where ci.pass_id=x.id)c on true
 where x.reservation_day=d and x.status='issued';
 return jsonb_build_object('enabled',true,'mode',case when private.yt_owner_limited() then 'owner_limited' else 'pos_direct' end,'business_day',d,'prices',p,'passes',mine,'today_passes',today);
end $function$;


CREATE OR REPLACE FUNCTION private.yt_ambassador_pos_pass_save(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.yt_ambassador_passes%rowtype; pid uuid; d date; pax integer; ptype text;
begin
 if auth.uid() is null or not (private.yt_pos_work_cashier() or private.yt_has_role('owner') or private.yt_owner_limited()) then raise exception 'cashier_only';end if;
 if private.yt_owner_limited() and nullif(p_payload->>'id','') is not null then raise exception 'pass_not_editable';end if;
 begin pid:=nullif(p_payload->>'id','')::uuid;d:=nullif(p_payload->>'reservation_day','')::date;
  pax:=nullif(p_payload->>'planned_pax','')::integer;exception when others then raise exception 'invalid_pass';end;
 ptype:=coalesce(p_payload->>'pass_type','group');
 if d is null or d<private.yt_business_day(now()) or d>private.yt_business_day(now())+7 then raise exception 'invalid_reservation_day';end if;
 if pax not between 1 and 500 or ptype not in ('group','individual') then raise exception 'invalid_planned_pax';end if;
 if length(coalesce(p_payload->>'guest_name',''))>100 or length(coalesce(p_payload->>'guest_phone',''))>40
  or length(coalesce(p_payload->>'remark',''))>500 then raise exception 'invalid_pass';end if;
 if pid is null then
  insert into public.yt_ambassador_passes(ambassador_id,issued_by,reservation_day,pass_type,planned_pax,guest_name,guest_phone,remark)
  values(null,auth.uid(),d,ptype,pax,coalesce(p_payload->>'guest_name',''),coalesce(p_payload->>'guest_phone',''),coalesce(p_payload->>'remark',''))
  returning * into v;
 else
  select * into v from public.yt_ambassador_passes where id=pid and issued_by=auth.uid() and ambassador_id is null and status='issued' for update;
  if v.id is null then raise exception 'pass_not_editable';end if;
  if exists(select 1 from public.yt_ambassador_checkins where pass_id=v.id) then raise exception 'pass_already_checked_in';end if;
  update public.yt_ambassador_passes set reservation_day=d,pass_type=ptype,planned_pax=pax,guest_name=coalesce(p_payload->>'guest_name',''),
   guest_phone=coalesce(p_payload->>'guest_phone',''),remark=coalesce(p_payload->>'remark',''),updated_at=now()
   where id=v.id returning * into v;
 end if;
 return jsonb_build_object('id',v.id,'pass_code',v.pass_code,'reservation_day',v.reservation_day,'planned_pax',v.planned_pax,'pass_type',v.pass_type);
end $function$;

