create or replace function private.yt_claim_pass(p_token uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();p public.game_passes%rowtype;h text;
begin
 if actor is null or not exists(select 1 from public.pin_accounts where auth_user_id=actor) or exists(select 1 from public.work_accounts where auth_user_id=actor) then raise exception 'customer_only';end if;
 if p_token is null then raise exception 'pass_invalid_or_claimed';end if;
 perform pg_advisory_xact_lock(781943081);
 h:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 select * into p from public.game_passes where claim_token_hash=h for update;
 if not found then raise exception 'pass_invalid_or_claimed';end if;
 if p.customer_id=actor and p.claimed_at is not null and p.status<>'revoked' then return p.id;end if;
 if p.status<>'issued' or p.customer_id is not null or p.claimed_at is not null or p.expires_at<=clock_timestamp() then raise exception 'pass_invalid_or_claimed';end if;
 -- A constituent code cannot bypass the one-member, atomic whole-order claim.
 if exists(select 1 from public.yt_pos_pass_bundle_items x join public.yt_pos_pass_bundles b on b.id=x.bundle_id where x.pass_id=p.id and b.status='issued' and b.expires_at>clock_timestamp()) then raise exception 'use_whole_order_claim';end if;
 update public.game_passes set customer_id=actor,status='claimed',claimed_at=clock_timestamp(),expires_at=clock_timestamp()+interval '72 hours' where id=p.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(actor,'pass.claim','game_pass',p.id);
 return p.id;
end $$;

create or replace function private.yt_pos_benefit_orders() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;d date:=private.yt_business_day(now());
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') into rows from(
 select o.id,o.order_no,o.table_label,o.amount_rm,o.created_at
 from public.yt_member_orders o where o.source='future_pos' and o.status='fulfilled' and o.payment_status='paid'
 and o.created_at>=private.yt_business_start(d) and o.created_at<private.yt_business_start(d+1)
 and o.settlement_due_since is null and not o.cancel_after_refund
 and exists(select 1 from public.yt_member_order_items i join public.yt_pos_item_units u on u.order_item_id=i.id
  join public.yt_shop_products p on p.id=i.product_id join public.yt_pos_series s on s.id=p.series_id left join public.game_passes gp on gp.id=u.game_pass_id
  where i.order_id=o.id and not u.retired and u.unit_number<=i.quantity and u.assigned_customer_id is null and u.reward_redemption_id is null
  and s.active and s.benefit_mode in ('games','choose') and s.game_plays=1
  and (gp.id is null or (gp.customer_id is null and gp.claimed_at is null and gp.status in ('issued','expired'))))
 order by o.created_at desc,o.id limit 150)x;
 return jsonb_build_object('business_day',d,'orders',rows);
end $$;

create or replace function private.yt_owner_default_campaign(p_campaign uuid) returns uuid language plpgsql security definer set search_path='' as $$
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 perform pg_advisory_xact_lock(781943082);
 if p_campaign is not null and not exists(select 1 from public.campaigns c where id=p_campaign and active
  and (starts_at is null or starts_at<=clock_timestamp()) and (ends_at is null or ends_at>clock_timestamp())
  and exists(select 1 from public.campaign_games cg join public.games g on g.id=cg.game_id where cg.campaign_id=c.id and g.active)) then raise exception 'default_campaign_not_available';end if;
 update public.campaigns set is_default=false where is_default;
 if p_campaign is not null then update public.campaigns set is_default=true where id=p_campaign;end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(auth.uid(),'campaign.set_default','campaign',p_campaign);
 return p_campaign;
end $$;

create or replace function private.yt_pos_cancel_code(p_pass uuid default null,p_bundle uuid default null,p_reason text default '',p_expected_expiry timestamptz default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.yt_pos_pass_bundles%rowtype;oid uuid;ids uuid[];n integer;v public.yt_member_orders%rowtype;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if (p_pass is null)=(p_bundle is null) or length(btrim(coalesce(p_reason,''))) not between 2 and 200 then raise exception 'invalid_pass_cancellation';end if;
 perform pg_advisory_xact_lock(781943081);
 if p_bundle is null then
  select x.bundle_id into p_bundle from public.yt_pos_pass_bundle_items x join public.yt_pos_pass_bundles b0 on b0.id=x.bundle_id where x.pass_id=p_pass and b0.status='issued' and b0.expires_at>clock_timestamp() order by b0.created_at desc limit 1;
 end if;
 if p_bundle is not null then
  select * into b from public.yt_pos_pass_bundles where id=p_bundle;
  if not found or b.status='claimed' then raise exception 'pass_already_claimed';end if;
  if b.status='revoked' then return jsonb_build_object('ok',true,'already_cancelled',true,'count',0,'order_id',b.order_id);end if;
  oid:=b.order_id;
  select array_agg(pass_id order by pass_id) into ids from public.yt_pos_pass_bundle_items where bundle_id=b.id;
 else
  select i.order_id into oid from public.yt_pos_item_units u join public.yt_member_order_items i on i.id=u.order_item_id where u.game_pass_id=p_pass;
  ids:=array[p_pass];
 end if;
 if oid is null or ids is null then raise exception 'pos_pass_not_found';end if;
 select * into v from public.yt_member_orders where id=oid for update;
 if private.yt_business_day(v.created_at)<>private.yt_business_day(clock_timestamp()) then raise exception 'benefits_current_day_only';end if;
 perform 1 from public.game_passes where id=any(ids) order by id for update;
 if b.id is null then
  if exists(select 1 from public.game_passes where id=p_pass and status='expired' and customer_id is null and claimed_at is null) then return jsonb_build_object('ok',true,'already_cancelled',true,'count',0,'order_id',oid);end if;
  if p_expected_expiry is null or not exists(select 1 from public.game_passes where id=p_pass and expires_at=p_expected_expiry) then raise exception 'pass_changed_reload';end if;
 end if;
 if exists(select 1 from public.game_passes where id=any(ids) and (customer_id is not null or claimed_at is not null or status not in('issued','expired')))
 or exists(select 1 from public.game_sessions where pass_id=any(ids)) then raise exception 'pass_already_claimed';end if;
 update public.game_passes set status='expired',expires_at=least(expires_at,clock_timestamp()) where id=any(ids);
 get diagnostics n=row_count;
 update public.yt_pos_item_units set benefit_status='available' where game_pass_id=any(ids) and assigned_customer_id is null;
 if b.id is not null then update public.yt_pos_pass_bundles set status='revoked',expires_at=least(expires_at,clock_timestamp()) where id=b.id;end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'pos.unclaimed_code_cancel','pos_order',oid,jsonb_build_object('passes',ids,'bundle',b.id,'reason',p_reason));
 return jsonb_build_object('ok',true,'count',n,'order_id',oid,'bundle_id',b.id);
end $$;

create or replace function private.yt_my_game_passes() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;actor uuid:=auth.uid();
begin
 if actor is null or not exists(select 1 from public.pin_accounts where auth_user_id=actor) or exists(select 1 from public.work_accounts where auth_user_id=actor) then raise exception 'customer_only';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.expires_at),'[]') into rows from(
  select p.id,p.status,p.claimed_at,p.expires_at,p.campaign_id,p.created_at,p.spend_amount_rm,p.spend_ref,p.selection,
   s.id session_id,s.status session_status,s.game_id,g.slug game_slug,g.title game_title,s.result_key,s.score,s.progress
  from public.game_passes p left join public.game_sessions s on s.pass_id=p.id left join public.games g on g.id=s.game_id
  where p.customer_id=actor and p.status='claimed' and p.expires_at>now()
  order by p.expires_at,p.id limit 150)x;
 return rows;
end $$;
create or replace function public.yt_pos_benefit_orders() returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_benefit_orders()$$;
create or replace function public.yt_owner_default_campaign(p_campaign uuid) returns uuid language sql security invoker set search_path='' as $$select private.yt_owner_default_campaign(p_campaign)$$;
create or replace function public.yt_pos_cancel_code(p_pass uuid default null,p_bundle uuid default null,p_reason text default '',p_expected_expiry timestamptz default null) returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_cancel_code(p_pass,p_bundle,p_reason,p_expected_expiry)$$;
create or replace function public.yt_my_game_passes() returns jsonb language sql security invoker set search_path='' as $$select private.yt_my_game_passes()$$;
revoke all on function private.yt_pos_benefit_orders(),private.yt_owner_default_campaign(uuid),private.yt_pos_cancel_code(uuid,uuid,text,timestamptz),private.yt_my_game_passes(),public.yt_pos_benefit_orders(),public.yt_owner_default_campaign(uuid),public.yt_pos_cancel_code(uuid,uuid,text,timestamptz),public.yt_my_game_passes() from public,anon;
grant execute on function private.yt_pos_benefit_orders(),private.yt_owner_default_campaign(uuid),private.yt_pos_cancel_code(uuid,uuid,text,timestamptz),private.yt_my_game_passes(),public.yt_pos_benefit_orders(),public.yt_owner_default_campaign(uuid),public.yt_pos_cancel_code(uuid,uuid,text,timestamptz),public.yt_my_game_passes() to authenticated;
