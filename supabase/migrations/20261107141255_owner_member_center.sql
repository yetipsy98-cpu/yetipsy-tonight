-- Owner member center. Uses existing wallets, redemptions and append-only audit
-- history so existing scoped resets retain their established dependency order.
create unique index if not exists yt_member_operation_request on public.audit_logs(actor_id,(metadata->>'request')) where action='owner.member_operation';
create index if not exists yt_member_operation_customer on public.audit_logs(entity_id,created_at desc,id desc) where action='owner.member_operation';

create or replace function private.yt_owner_member_search(p_search text default '',p_page integer default 1)
returns jsonb language plpgsql security definer set search_path='' as $$
declare q text:=lower(btrim(coalesce(p_search,''))); total bigint; rows jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_page is null or p_page<1 or p_page>100000 or length(q)>100 then raise exception 'invalid_member_search';end if;
 select count(*) into total from public.pin_accounts p left join public.profiles f on f.id=p.auth_user_id
 where not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)
 and (q='' or position(q in lower(p.phone||' '||coalesce(f.display_name,'')||' '||p.auth_user_id::text))>0);
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from (
 select p.auth_user_id id,p.phone,coalesce(nullif(f.display_name,''),'会员') display_name,p.created_at,
 greatest(0,coalesce(w.balance,0)-coalesce((select sum(e.remaining_points) from public.yt_point_entries e where e.customer_id=p.auth_user_id and e.direction='earn' and e.expires_at<=clock_timestamp()),0)) points,
 (select count(*) from public.user_rewards r where r.customer_id=p.auth_user_id and r.status='available' and r.expires_at>clock_timestamp()) rewards
 from public.pin_accounts p left join public.profiles f on f.id=p.auth_user_id left join public.yt_point_wallets w on w.customer_id=p.auth_user_id
 where not exists(select 1 from public.work_accounts a where a.auth_user_id=p.auth_user_id)
 and (q='' or position(q in lower(p.phone||' '||coalesce(f.display_name,'')||' '||p.auth_user_id::text))>0)
 order by p.created_at desc,p.auth_user_id limit 20 offset (p_page-1)*20)x;
 return jsonb_build_object('actor_id',auth.uid(),'members',rows,'total',total,'page',p_page,'page_size',20);
end $$;

create or replace function private.yt_owner_member_detail(p_customer uuid,p_tab text default 'rewards',p_page integer default 1)
returns jsonb language plpgsql security definer set search_path='' as $$
declare member jsonb; summary jsonb; rows jsonb; total bigint; v_balance bigint; options jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_customer is null or p_page is null or p_page<1 or p_page>100000 or p_tab is null or p_tab not in ('rewards','points','games','orders','storebox','history') then raise exception 'invalid_member_detail';end if;
 select jsonb_build_object('id',p.auth_user_id,'phone',p.phone,'display_name',coalesce(nullif(f.display_name,''),'会员'),'created_at',p.created_at) into member
 from public.pin_accounts p left join public.profiles f on f.id=p.auth_user_id where p.auth_user_id=p_customer and not exists(select 1 from public.work_accounts a where a.auth_user_id=p_customer);
 if member is null then raise exception 'member_not_found';end if;
 perform pg_advisory_xact_lock(781943081);
 v_balance:=private.yt_points_sync(p_customer);
 select jsonb_build_object('points',v_balance,'earned',w.lifetime_earned,'spent',w.lifetime_spent,
 'expiring_points',(select coalesce(sum(e.remaining_points),0) from public.yt_point_entries e where e.customer_id=p_customer and e.direction='earn' and e.expires_at>clock_timestamp() and e.expires_at<=clock_timestamp()+interval '7 days'),
 'rewards',(select count(*) from public.user_rewards r where r.customer_id=p_customer and r.status='available' and r.expires_at>clock_timestamp()),
 'passes',(select count(*) from public.game_passes p where p.customer_id=p_customer and p.status='claimed' and p.expires_at>clock_timestamp()),
 'stored_units',(select coalesce(sum(greatest(0,b.total_units-b.served_units)),0) from public.yt_store_boxes b where b.customer_id=p_customer and b.status='active' and (b.storage_expires_at is null or b.storage_expires_at>clock_timestamp())),
 'orders',(select count(*) from public.yt_play_consumption_bindings b where b.customer_id=p_customer),
 'spent_rm',(select coalesce(sum(e.amount_rm),0) from public.yt_pos_payment_entries e join public.yt_play_consumption_bindings b on b.order_id=e.order_id where b.customer_id=p_customer)) into summary from public.yt_point_wallets w where w.customer_id=p_customer;
 if p_tab='rewards' then
  select count(*) into total from public.user_rewards where customer_id=p_customer;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from (
   select w.id,w.reward_id,r.name,r.description,r.redeem_rules,w.status,w.created_at,w.redeem_after,w.expires_at,w.redeemed_at,
   r.active and w.status='available' and w.redeem_after<=clock_timestamp() and w.expires_at>clock_timestamp() and (r.redeem_start_at is null or r.redeem_start_at<=clock_timestamp()) and (r.redeem_end_at is null or r.redeem_end_at>clock_timestamp()) and private.yt_redeem_hours(r.id) redeemable,
   case when w.session_id is not null then coalesce(g.title,'游戏奖励') when exists(select 1 from public.yt_point_shop_exchanges ex where ex.user_reward_id=w.id) then '积分商城' when w.issued_by is not null then '人工发放' else '活动奖励' end source,
   gs.pass_id,gs.id session_id,linked.order_id source_order_id,
   (select coalesce(jsonb_agg(jsonb_build_object('order_id',h.order_id,'state',h.state)),'[]') from public.yt_pos_reward_holds h where h.user_reward_id=w.id and h.state in('reserved','ready')) order_locks,
   exists(select 1 from public.yt_pos_preorder_holds h where h.user_reward_id=w.id and h.state='reserved' and h.expires_at>clock_timestamp()) draft_locked,
   (select h.order_id from public.yt_pos_reward_holds h where h.user_reward_id=w.id and h.state='settled' order by h.settled_at desc limit 1) redeemed_order_id
   from public.user_rewards w join public.rewards r on r.id=w.reward_id left join public.game_sessions gs on gs.id=w.session_id left join public.games g on g.id=gs.game_id
   left join lateral(select i.order_id from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id where u.game_pass_id=gs.pass_id limit 1) linked on true
   where w.customer_id=p_customer order by w.created_at desc,w.id desc limit 30 offset (p_page-1)*30)x;
 elsif p_tab='points' then
  select count(*) into total from public.yt_point_entries where customer_id=p_customer;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from (
   select e.id,e.direction,e.points,e.remaining_points,e.source,e.reference,e.game_pass_id,e.created_at,e.expires_at,
    (select a.metadata->>'reason' from public.audit_logs a where a.action='owner.member_operation' and a.entity_id=p_customer and a.metadata#>>'{response,point_id}'=e.id::text order by a.id desc limit 1) reason
   from public.yt_point_entries e where e.customer_id=p_customer order by e.created_at desc,e.id desc limit 30 offset (p_page-1)*30)x;
 elsif p_tab='games' then
  select count(*) into total from public.game_passes where customer_id=p_customer;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from (
   select p.id,p.status,p.created_at,p.expires_at,p.claimed_at,p.used_at,p.lucky_mode,c.name campaign,g.title game,gs.status game_status,gs.result_key,gs.points_awarded,gs.settlement_choice,r.name reward,ur.status reward_status
   from public.game_passes p join public.campaigns c on c.id=p.campaign_id left join public.game_sessions gs on gs.pass_id=p.id left join public.games g on g.id=gs.game_id left join public.user_rewards ur on ur.session_id=gs.id left join public.rewards r on r.id=ur.reward_id
   where p.customer_id=p_customer order by p.created_at desc,p.id desc limit 30 offset (p_page-1)*30)x;
 elsif p_tab='orders' then
  select count(*) into total from public.yt_play_consumption_bindings where customer_id=p_customer;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from (
   select o.id,o.order_no,o.pos_business_day business_day,o.created_at,o.status,o.payment_status,o.payment_method,o.amount_rm,b.source,
   (select coalesce(sum(e.amount_rm),0) from public.yt_pos_payment_entries e where e.order_id=o.id) received_rm
   from public.yt_play_consumption_bindings b join public.yt_member_orders o on o.id=b.order_id where b.customer_id=p_customer order by o.created_at desc,o.id desc limit 30 offset (p_page-1)*30)x;
 elsif p_tab='storebox' then
  select count(*) into total from public.yt_store_boxes where customer_id=p_customer;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from (
   select id,box_number,name,status,total_units,served_units,completed_units,unit_label,storage_expires_at,created_at,source_order_id
   from public.yt_store_boxes where customer_id=p_customer order by created_at desc,id desc limit 30 offset (p_page-1)*30)x;
 else
  select count(*) into total from public.audit_logs where action='owner.member_operation' and entity_id=p_customer;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]') into rows from (
   select a.id,a.created_at,coalesce(w.username,'Owner') actor,a.metadata->>'operation' operation,a.metadata->>'reason' reason,a.metadata->'before' before,a.metadata->'after' after,a.metadata->'response' response
   from public.audit_logs a left join public.work_accounts w on w.auth_user_id=a.actor_id where a.action='owner.member_operation' and a.entity_id=p_customer order by a.created_at desc,a.id desc limit 30 offset (p_page-1)*30)x;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'validity_days',validity_days,'next_day_only',next_day_only) order by name,id),'[]') into options from public.rewards where active and (redeem_end_at is null or redeem_end_at>clock_timestamp());
 return jsonb_build_object('actor_id',auth.uid(),'member',member,'summary',summary,'rows',rows,'total',total,'tab',p_tab,'page',p_page,'page_size',30,'reward_options',options);
end $$;

create or replace function private.yt_owner_member_operate(p_customer uuid,p_action text,p_target uuid,p_data jsonb,p_reason text,p_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); old public.audit_logs%rowtype; award public.user_rewards%rowtype; reward public.rewards%rowtype;
 payload jsonb; result jsonb; before_state jsonb; after_state jsonb; v_balance bigint; need bigint; amount bigint; lot record; take bigint; entry uuid; receipt uuid;
 v_after timestamptz; v_exp timestamptz; days integer; v_now timestamptz:=clock_timestamp();
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_customer is null or p_request is null or p_action is null or p_action not in ('reward_issue','reward_redeem','reward_extend','reward_revoke','points_credit','points_debit') or p_data is null or jsonb_typeof(p_data)<>'object' or length(btrim(coalesce(p_reason,'')))<2 or length(p_reason)>500 then raise exception 'invalid_member_operation';end if;
 payload:=jsonb_build_object('customer',p_customer,'operation',p_action,'target',p_target,'data',p_data,'reason',btrim(p_reason));
 perform pg_advisory_xact_lock(781943081);
 select * into old from public.audit_logs where action='owner.member_operation' and actor_id=actor and metadata->>'request'=p_request::text;
 if found then
  if old.metadata->'payload' is distinct from payload then raise exception 'request_conflict';end if;
  return old.metadata->'response'||jsonb_build_object('idempotent',true);
 end if;
 if not exists(select 1 from public.pin_accounts where auth_user_id=p_customer) or exists(select 1 from public.work_accounts where auth_user_id=p_customer) then raise exception 'member_not_found';end if;
 if p_action like 'points_%' then
  amount:=(p_data->>'points')::bigint;
  if amount is null or amount<1 or amount>1000000 then raise exception 'invalid_points_amount';end if;
  v_balance:=private.yt_points_sync(p_customer);
  if (p_data->>'expected_balance')::bigint is distinct from v_balance then raise exception 'member_balance_changed';end if;
  before_state:=jsonb_build_object('balance',v_balance);
  if p_action='points_credit' then
   select points_validity_days into days from public.yt_loyalty_config where id=true;
   v_exp:=case when days>0 then v_now+make_interval(days=>days) else null end;
   insert into public.yt_point_entries(customer_id,direction,points,remaining_points,expires_at,reference,source)
   values(p_customer,'earn',amount,amount,v_exp,'OWNER:'||p_request::text,'owner_credit') returning id into entry;
   update public.yt_point_wallets w set balance=w.balance+amount,lifetime_earned=w.lifetime_earned+amount,updated_at=v_now where customer_id=p_customer;
   v_balance:=v_balance+amount;
  else
   if v_balance<amount then raise exception 'points_insufficient';end if;
   need:=amount;
   for lot in select * from public.yt_point_entries where customer_id=p_customer and direction='earn' and remaining_points>0 and (expires_at is null or expires_at>v_now) order by expires_at asc nulls last,created_at,id for update loop
    take:=least(need,lot.remaining_points);update public.yt_point_entries set remaining_points=remaining_points-take where id=lot.id;need:=need-take;exit when need=0;
   end loop;
   if need<>0 then raise exception 'points_ledger_mismatch';end if;
   insert into public.yt_point_entries(customer_id,direction,points,reference,source) values(p_customer,'spend',amount,'OWNER:'||p_request::text,'owner_debit') returning id into entry;
   update public.yt_point_wallets w set balance=w.balance-amount,lifetime_spent=w.lifetime_spent+amount,updated_at=v_now where customer_id=p_customer;
   v_balance:=v_balance-amount;
  end if;
  after_state:=jsonb_build_object('balance',v_balance);
  result:=jsonb_build_object('point_id',entry,'balance',v_balance,'points',amount);
 elsif p_action='reward_issue' then
  select * into reward from public.rewards where id=p_target and active for share;
  if not found then raise exception 'reward_unavailable';end if;
  v_after:=case when reward.next_day_only then private.yt_business_start(private.yt_business_day(v_now)+1) else v_now end;
  v_after:=greatest(v_after,coalesce(reward.redeem_start_at,v_after));
  v_exp:=least(v_after+make_interval(days=>reward.validity_days),coalesce(reward.redeem_end_at,'infinity'::timestamptz));
  if v_exp<=v_after then raise exception 'reward_no_valid_window';end if;
  insert into public.user_rewards(customer_id,reward_id,issued_by,redeem_after,expires_at,request_id)
  values(p_customer,reward.id,actor,v_after,v_exp,p_request) returning * into award;
  after_state:=jsonb_build_object('id',award.id,'name',reward.name,'status',award.status,'redeem_after',award.redeem_after,'expires_at',award.expires_at);
  result:=jsonb_build_object('award_id',award.id,'reward_name',reward.name);
 else
  select * into award from public.user_rewards where id=p_target and customer_id=p_customer for update;
  if not found then raise exception 'member_reward_not_found';end if;
  if award.status not in ('available','expired') or exists(select 1 from public.redemptions where user_reward_id=award.id) then raise exception 'member_reward_already_used';end if;
  if exists(select 1 from public.yt_pos_reward_holds where user_reward_id=award.id and state in ('reserved','ready')) or exists(select 1 from public.yt_pos_preorder_holds where user_reward_id=award.id and state='reserved' and expires_at>v_now) then raise exception 'member_reward_locked';end if;
  if p_data->>'expected_status' is distinct from award.status or (p_data->>'expected_expires_at')::timestamptz is distinct from award.expires_at then raise exception 'member_reward_changed';end if;
  select * into reward from public.rewards where id=award.reward_id for share;
  before_state:=jsonb_build_object('id',award.id,'name',reward.name,'status',award.status,'expires_at',award.expires_at);
  if p_action='reward_redeem' then
   if p_data->>'delivered' is distinct from 'true' then raise exception 'member_delivery_confirmation_required';end if;
   if not reward.active or award.status<>'available' or award.redeem_after>v_now or award.expires_at<=v_now or reward.redeem_start_at>v_now or reward.redeem_end_at<=v_now or not private.yt_redeem_hours(reward.id) then raise exception 'reward_unavailable';end if;
   insert into public.redemptions(user_reward_id,customer_id,staff_id,request_id,redeemed_at) values(award.id,p_customer,actor,p_request,v_now) returning id into receipt;
   update public.user_rewards set status='redeemed',redeemed_at=v_now where id=award.id;
   update public.redeem_tokens set consumed_at=v_now where user_reward_id=award.id and consumed_at is null;
  elsif p_action='reward_revoke' then
   update public.user_rewards set status='revoked' where id=award.id;
   update public.redeem_tokens set consumed_at=v_now where user_reward_id=award.id and consumed_at is null;
  else
   v_exp:=(p_data->>'expires_at')::timestamptz;
   if v_exp is null or v_exp<=greatest(v_now,award.expires_at,award.redeem_after) or v_exp>v_now+interval '10 years' then raise exception 'invalid_reward_extension';end if;
   if reward.redeem_end_at is not null and v_exp>reward.redeem_end_at then raise exception 'reward_extension_past_campaign_end';end if;
   update public.user_rewards set status='available',expires_at=v_exp where id=award.id;
  end if;
  select jsonb_build_object('id',id,'name',reward.name,'status',status,'expires_at',expires_at,'redeemed_at',redeemed_at) into after_state from public.user_rewards where id=award.id;
  result:=jsonb_build_object('award_id',award.id,'reward_name',reward.name,'receipt_id',receipt);
 end if;
 result:=result||jsonb_build_object('ok',true,'idempotent',false,'operation',p_action);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(actor,'owner.member_operation','member',p_customer,jsonb_build_object('request',p_request,'payload',payload,'operation',p_action,'reason',btrim(p_reason),'before',before_state,'after',after_state,'response',result));
 return result;
end $$;

create or replace function public.yt_owner_member_search(p_search text default '',p_page integer default 1) returns jsonb language sql security invoker set search_path='' as $$select private.yt_owner_member_search(p_search,p_page)$$;
create or replace function public.yt_owner_member_detail(p_customer uuid,p_tab text default 'rewards',p_page integer default 1) returns jsonb language sql security invoker set search_path='' as $$select private.yt_owner_member_detail(p_customer,p_tab,p_page)$$;
create or replace function public.yt_owner_member_operate(p_customer uuid,p_action text,p_target uuid,p_data jsonb,p_reason text,p_request uuid) returns jsonb language sql security invoker set search_path='' as $$select private.yt_owner_member_operate(p_customer,p_action,p_target,p_data,p_reason,p_request)$$;
revoke all on function public.yt_owner_member_search(text,integer),private.yt_owner_member_search(text,integer),public.yt_owner_member_detail(uuid,text,integer),private.yt_owner_member_detail(uuid,text,integer),public.yt_owner_member_operate(uuid,text,uuid,jsonb,text,uuid),private.yt_owner_member_operate(uuid,text,uuid,jsonb,text,uuid) from public,anon;
grant execute on function public.yt_owner_member_search(text,integer),private.yt_owner_member_search(text,integer),public.yt_owner_member_detail(uuid,text,integer),private.yt_owner_member_detail(uuid,text,integer),public.yt_owner_member_operate(uuid,text,uuid,jsonb,text,uuid),private.yt_owner_member_operate(uuid,text,uuid,jsonb,text,uuid) to authenticated;
