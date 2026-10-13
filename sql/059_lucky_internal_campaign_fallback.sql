-- Lucky Box does not depend on any Owner-maintained activities; preserve required GamePass FK.
create or replace function private.yt_lucky_issue_unit_pass(p_order uuid,p_item uuid,p_unit integer,p_token uuid,p_request uuid,p_minutes integer default 2)
returns table(pass_id uuid,expires_at timestamptz,spend_amount_rm numeric,points_cap integer)
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();o public.yt_member_orders%rowtype;
 i public.yt_member_order_items%rowtype;u public.yt_pos_item_units%rowtype;
 p public.game_passes%rowtype;v_campaign uuid;v_hash text;v_exp timestamptz;v_new uuid;v_mode text;
begin
 perform pg_advisory_xact_lock(781943081);
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_order is null or p_item is null or p_unit is null or p_unit<1 or p_token is null or p_request is null
 or p_minutes not between 1 and 60 then raise exception 'invalid_benefit_request';end if;
 select * into o from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 if private.yt_business_day(o.created_at)<>private.yt_business_day(clock_timestamp()) then raise exception 'benefits_current_day_only';end if;
 if o.status<>'fulfilled' or o.payment_status<>'paid' or o.paid_at is null then raise exception 'benefits_after_payment_only';end if;
 if o.cancel_after_refund or o.settlement_due_since is not null then raise exception 'order_payment_adjustment_pending';end if;
 select coalesce(om.mode,s.mode) into v_mode from public.yt_lucky_settings s
 left join public.yt_lucky_order_modes om on om.order_id=p_order where s.id=true;
 if v_mode<>'lucky' then raise exception 'gamepass_mode_disabled';end if;
 select * into i from public.yt_member_order_items where id=p_item and order_id=p_order;
 if not found or not i.is_drink_at_order or i.unit_price_rm<=0 then raise exception 'lucky_box_not_eligible';end if;
 select * into u from public.yt_pos_item_units where order_item_id=p_item and unit_number=p_unit for update;
 if not found or u.retired or p_unit>i.quantity or u.assigned_customer_id is not null or u.reward_redemption_id is not null
 then raise exception 'unit_not_in_order';end if;
 select id into v_campaign from public.campaigns order by is_default desc,created_at,id limit 1;
 if v_campaign is null then
  insert into public.campaigns(name,active,is_default) values('Yetipsy GamePass 内部引用（勿作为活动推广）',false,false) returning id into v_campaign;
 end if;
 v_hash:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 v_exp:=clock_timestamp()+interval '2 minutes';
 if u.game_pass_id is not null then
  select * into p from public.game_passes where id=u.game_pass_id for update;
  if not found then raise exception 'benefit_reference_missing';end if;
  if p.lucky_mode<>'lucky' then raise exception 'gamepass_order_mode_mismatch';end if;
  if p.request_id=p_request and p.claim_token_hash is distinct from v_hash then raise exception 'request_conflict';end if;
  if p.status='issued' and p.claim_token_hash=v_hash and p.expires_at>clock_timestamp() then
   return query select p.id,p.expires_at,p.spend_amount_rm,0;return;
  end if;
  if p.customer_id is not null or p.claimed_at is not null
   or exists(select 1 from public.yt_lucky_results lr where lr.pass_id=p.id
     or exists(select 1 from public.yt_pos_pass_bundle_items bi where bi.pass_id=p.id and lr.bundle_id=bi.bundle_id))
   or p.status not in('issued','expired') or p.expires_at>clock_timestamp()
  then raise exception 'unit_already_issued';end if;
  update public.game_passes set status='issued',campaign_id=v_campaign,claim_token_hash=v_hash,
   expires_at=v_exp,spend_day=private.yt_business_day(clock_timestamp()),spend_amount_rm=i.unit_price_rm,
   points_enabled_issued=false,points_cap_issued=0,points_percent_issued=0,points_rate_issued=100,
   request_id=p_request,issued_by=actor where id=p.id;
  v_new:=p.id;
 else
  insert into public.game_passes(campaign_id,issued_by,claim_token_hash,request_id,expires_at,
   spend_amount_rm,spend_ref,spend_day,points_enabled_issued,points_cap_issued,points_percent_issued,points_rate_issued)
  values(v_campaign,actor,v_hash,p_request,v_exp,i.unit_price_rm,
   'POS-'||replace(p_item::text,'-','')||'-'||p_unit::text,private.yt_business_day(clock_timestamp()),false,0,0,100)
  returning id into v_new;
  update public.yt_pos_item_units set game_pass_id=v_new,benefit_status='issued'
   where order_item_id=p_item and unit_number=p_unit;
 end if;
 insert into public.yt_pos_order_events(order_id,actor_id,event_type,source,note)
  values(p_order,actor,'benefit_issued','staff','LUCKY-BOX');
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(actor,'lucky.pos_pass_issued','pos_order',p_order,jsonb_build_object('pass_id',v_new,'item_id',p_item,'unit',p_unit));
 return query select v_new,v_exp,i.unit_price_rm,0;
end $$;
create or replace function private.yt_lucky_bundle_issue(p_order uuid,p_token uuid,p_request uuid,p_minutes integer default 2)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();o public.yt_member_orders%rowtype; b public.yt_pos_pass_bundles%rowtype;
 v_campaign uuid;v_row record;v_pass uuid;v_exp timestamptz;v_count int:=0;v_quote jsonb;
begin
 perform pg_advisory_xact_lock(781943081);
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_order is null or p_token is null or p_request is null or p_minutes not between 1 and 60
 then raise exception 'invalid_bundle_request';end if;
 select * into o from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found or o.payment_status<>'paid' or o.status<>'fulfilled' or o.paid_at is null then raise exception 'benefits_after_payment_only';end if;
 if o.settlement_due_since is not null or o.cancel_after_refund then raise exception 'order_payment_adjustment_pending';end if;
 select * into b from public.yt_pos_pass_bundles where issued_by=actor and request_id=p_request for update;
 if found then
  if b.order_id<>p_order or b.token_hash<>encode(sha256(convert_to(p_token::text,'UTF8')),'hex')
   or b.lucky_mode<>'lucky' then raise exception 'bundle_request_conflict';end if;
  return jsonb_build_object('id',b.id,'expires_at',b.expires_at,'status',b.status,
   'pass_count',(select count(*) from public.yt_pos_pass_bundle_items where bundle_id=b.id),'idempotent',true);
 end if;
 v_quote:=private.yt_lucky_bundle_quote(p_order);
 if not coalesce((v_quote->>'can_issue')::boolean,false) then
  if coalesce((v_quote->>'eligible_spend_rm')::numeric,0)<coalesce((v_quote->>'minimum_spend_rm')::numeric,15)
   then raise exception 'lucky_minimum_spend';end if;
  raise exception 'no_eligible_bundle_units';
 end if;
 select id into v_campaign from public.campaigns order by is_default desc,created_at,id limit 1;
 if v_campaign is null then
  insert into public.campaigns(name,active,is_default) values('Yetipsy GamePass 内部引用（勿作为活动推广）',false,false) returning id into v_campaign;
 end if;
 update public.yt_pos_pass_bundles set status='expired' where order_id=p_order and status='issued' and expires_at<=clock_timestamp();
 v_exp:=clock_timestamp()+interval '2 minutes';
 insert into public.yt_pos_pass_bundles(order_id,campaign_id,token_hash,issued_by,request_id,expires_at)
 values(p_order,v_campaign,encode(sha256(convert_to(p_token::text,'UTF8')),'hex'),actor,p_request,v_exp)
 returning * into b;
 for v_row in
  select i.id item_id,u.unit_number
  from public.yt_member_order_items i join public.yt_pos_item_units u on u.order_item_id=i.id
  left join public.game_passes gp on gp.id=u.game_pass_id
  where i.order_id=p_order and i.is_drink_at_order and i.unit_price_rm>0
    and not u.retired and u.unit_number<=i.quantity and u.reward_redemption_id is null and u.assigned_customer_id is null
    and (gp.id is null or (gp.lucky_mode='lucky' and gp.status in('issued','expired')
     and gp.customer_id is null and gp.claimed_at is null and gp.expires_at<=clock_timestamp()))
  order by i.id,u.unit_number
 loop
  select pass_id into v_pass from private.yt_lucky_issue_unit_pass(
   p_order,v_row.item_id,v_row.unit_number,gen_random_uuid(),gen_random_uuid(),p_minutes);
  insert into public.yt_pos_pass_bundle_items(bundle_id,pass_id,order_item_id,unit_number)
   values(b.id,v_pass,v_row.item_id,v_row.unit_number);
  v_count:=v_count+1;
 end loop;
 if v_count<1 then raise exception 'no_eligible_bundle_units';end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(actor,'lucky.bundle_issued','pos_order',p_order,jsonb_build_object('bundle_id',b.id,'passes',v_count));
 return jsonb_build_object('id',b.id,'expires_at',v_exp,'pass_count',v_count,
 'status','issued','idempotent',false);
end $$;
