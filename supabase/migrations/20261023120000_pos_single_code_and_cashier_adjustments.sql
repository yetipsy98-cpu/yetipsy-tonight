-- One redemption code per POS draft, plus Cashier FOC/discount requests requiring Owner approval.

create or replace function private.yt_pos_one_code_per_draft_guard()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  if (tg_table_name='yt_pos_preorder_holds' and new.state in ('pending','chosen'))
     or (tg_table_name='yt_moon_preorder_holds' and new.state='held') then
    perform pg_advisory_xact_lock(hashtextextended('yt-pos-one-code:'||new.operator_id::text||':'||new.draft_id::text,0));
    if exists(select 1 from public.yt_pos_preorder_holds h where h.operator_id=new.operator_id and h.draft_id=new.draft_id and h.state in ('pending','chosen') and h.expires_at>clock_timestamp() and (tg_table_name<>'yt_pos_preorder_holds' or h.id<>new.id))
       or exists(select 1 from public.yt_moon_preorder_holds h where h.operator_id=new.operator_id and h.draft_id=new.draft_id and h.state='held' and h.expires_at>clock_timestamp() and (tg_table_name<>'yt_moon_preorder_holds' or h.id<>new.id)) then
      raise exception 'only_one_code_per_order';
    end if;
  end if;
  return new;
end;
$function$;
drop trigger if exists yt_pos_one_code_per_draft_guard on public.yt_pos_preorder_holds;
create trigger yt_pos_one_code_per_draft_guard before insert or update of state,operator_id,draft_id on public.yt_pos_preorder_holds for each row execute function private.yt_pos_one_code_per_draft_guard();
drop trigger if exists yt_moon_one_code_per_draft_guard on public.yt_moon_preorder_holds;
create trigger yt_moon_one_code_per_draft_guard before insert or update of state,operator_id,draft_id on public.yt_moon_preorder_holds for each row execute function private.yt_pos_one_code_per_draft_guard();

create table if not exists public.yt_pos_cashier_adjustment_requests (
  id uuid primary key,
  requester_id uuid not null references auth.users(id),
  draft_id uuid not null,
  kind text not null check (kind in ('foc','discount')),
  request_payload jsonb not null,
  gross_rm numeric(12,2) not null check (gross_rm >= 0),
  adjustment_rm numeric(12,2) not null check (adjustment_rm > 0),
  net_rm numeric(12,2) not null check (net_rm >= 0.01),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewer_id uuid references auth.users(id),
  review_note text,
  reviewed_at timestamptz,
  order_id uuid references public.yt_member_orders(id),
  result jsonb,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists yt_pos_cashier_adjustment_requests_owner_queue_idx on public.yt_pos_cashier_adjustment_requests(status,created_at desc);
create index if not exists yt_pos_cashier_adjustment_requests_requester_idx on public.yt_pos_cashier_adjustment_requests(requester_id,created_at desc);
create unique index if not exists yt_pos_cashier_adjustment_requests_one_pending_draft_idx on public.yt_pos_cashier_adjustment_requests(requester_id,draft_id) where status='pending';
alter table public.yt_pos_cashier_adjustment_requests enable row level security;
revoke all on public.yt_pos_cashier_adjustment_requests from public,anon,authenticated;
revoke all on function private.yt_pos_one_code_per_draft_guard() from public,anon,authenticated;

create or replace function private.yt_pos_cashier_adjustment_submit(p_request uuid,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  actor uuid:=auth.uid(); v_draft uuid; v_kind text; v_items jsonb; v_foc jsonb;
  v_gross numeric(12,2); v_adjustment numeric(12,2); v_net numeric(12,2);
  v_discount_type text; v_discount_value numeric; v_reason text; v_existing public.yt_pos_cashier_adjustment_requests%rowtype;
begin
  if not private.yt_pos_work_cashier() or private.yt_work_owner() then raise exception 'cashier_only'; end if;
  if p_request is null or jsonb_typeof(p_payload)<>'object' then raise exception 'invalid_adjustment_request'; end if;
  v_draft:=nullif(p_payload->>'draft_id','')::uuid; v_kind:=p_payload->>'kind'; v_items:=p_payload->'items';
  v_foc:=coalesce(p_payload->'foc_product_ids','[]'::jsonb); v_reason:=btrim(coalesce(p_payload->>'reason',''));
  if v_draft is null or v_kind not in ('foc','discount') or length(v_reason)<2 or length(v_reason)>300 then raise exception 'invalid_adjustment_request'; end if;
  if coalesce(p_payload->>'checkout_mode','') not in ('pay_now','pay_later') then raise exception 'invalid_checkout_mode'; end if;
  if length(coalesce(p_payload->>'table_label',''))>32 or length(coalesce(p_payload->>'order_note',''))>600 then raise exception 'invalid_adjustment_request'; end if;
  select * into v_existing from public.yt_pos_cashier_adjustment_requests where id=p_request;
  if found then
    if v_existing.requester_id<>actor or v_existing.draft_id<>v_draft then raise exception 'request_conflict'; end if;
    return jsonb_build_object('id',v_existing.id,'status',v_existing.status,'idempotent',true);
  end if;
  if exists(select 1 from public.yt_pos_cashier_adjustment_requests r where r.requester_id=actor and r.draft_id=v_draft and r.status='pending') then raise exception 'adjustment_request_pending'; end if;
  if exists(select 1 from public.yt_pos_preorder_holds h where h.operator_id=actor and h.draft_id=v_draft and h.state in ('pending','chosen') and h.expires_at>clock_timestamp())
     or exists(select 1 from public.yt_moon_preorder_holds h where h.operator_id=actor and h.draft_id=v_draft and h.state='held' and h.expires_at>clock_timestamp()) then raise exception 'manual_adjustment_cannot_combine_code'; end if;
  select x.gross_rm into v_gross from private.yt_pos_draft_price(v_items) x;
  if v_kind='foc' then
    if jsonb_typeof(v_foc)<>'array' or jsonb_array_length(v_foc)<1 then raise exception 'foc_item_required'; end if;
    if exists(select 1 from jsonb_array_elements_text(v_foc) s where s.value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then raise exception 'foc_item_required'; end if;
    if (select count(distinct value) from jsonb_array_elements_text(v_foc))<>jsonb_array_length(v_foc) then raise exception 'foc_item_required'; end if;
    select coalesce(sum(p.price_rm*(i.value->>'quantity')::int),0)::numeric(12,2) into v_adjustment
      from jsonb_array_elements(v_items) i(value) join public.yt_shop_products p on p.id=(i.value->>'product_id')::uuid and p.active
      where (i.value->>'product_id') in (select value from jsonb_array_elements_text(v_foc));
    if v_adjustment<=0 or v_adjustment>=v_gross then raise exception 'adjustment_zero_total'; end if;
  else
    v_discount_type:=p_payload->>'discount_type';
    begin v_discount_value:=(p_payload->>'discount_value')::numeric; exception when others then raise exception 'discount_invalid'; end;
    if v_discount_type='rm' then v_adjustment:=round(v_discount_value,2);
    elsif v_discount_type='percent' and v_discount_value>0 and v_discount_value<100 then v_adjustment:=round(v_gross*v_discount_value/100,2);
    else raise exception 'discount_invalid'; end if;
    if v_adjustment<=0 or v_adjustment>=v_gross then raise exception 'adjustment_zero_total'; end if;
  end if;
  v_net:=round(v_gross-v_adjustment,2);
  if v_net<0.01 then raise exception 'adjustment_zero_total'; end if;
  insert into public.yt_pos_cashier_adjustment_requests(id,requester_id,draft_id,kind,request_payload,gross_rm,adjustment_rm,net_rm)
  values(p_request,actor,v_draft,v_kind,p_payload||jsonb_build_object('gross_rm',v_gross,'adjustment_rm',v_adjustment,'net_rm',v_net,'requester_id',actor),v_gross,v_adjustment,v_net);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
  values(actor,'pos.cashier_adjustment_requested','pos_cashier_adjustment',p_request,jsonb_build_object('kind',v_kind,'gross_rm',v_gross,'adjustment_rm',v_adjustment,'net_rm',v_net,'reason',v_reason));
  return jsonb_build_object('id',p_request,'status','pending','gross_rm',v_gross,'adjustment_rm',v_adjustment,'net_rm',v_net);
end;
$function$;

create or replace function public.yt_pos_cashier_adjustment_submit(p_request uuid,p_payload jsonb)
returns jsonb language sql security definer set search_path = '' as $function$ select private.yt_pos_cashier_adjustment_submit(p_request,p_payload); $function$;

create or replace function private.yt_pos_cashier_adjustment_requests_list()
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare result jsonb;
begin
  if not private.yt_work_owner() then raise exception 'owner_only'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'requester_name',coalesce(a.username,'Cashier'),'requester_id',r.requester_id,
    'draft_id',r.draft_id,'kind',r.kind,'request_payload',r.request_payload,'gross_rm',r.gross_rm,'adjustment_rm',r.adjustment_rm,'net_rm',r.net_rm,
    'status',r.status,'reviewer_id',r.reviewer_id,'review_note',r.review_note,'reviewed_at',r.reviewed_at,'order_id',r.order_id,
    'order_no',o.order_no,'result',r.result,'created_at',r.created_at) order by (r.status='pending') desc,r.created_at desc),'[]'::jsonb) into result
  from (select * from public.yt_pos_cashier_adjustment_requests order by (status='pending') desc,created_at desc limit 100) r
  left join public.work_accounts a on a.auth_user_id=r.requester_id left join public.yt_member_orders o on o.id=r.order_id;
  return result;
end;
$function$;
create or replace function public.yt_pos_cashier_adjustment_requests_list()
returns jsonb language sql security definer set search_path = '' as $function$ select private.yt_pos_cashier_adjustment_requests_list(); $function$;

create or replace function private.yt_pos_cashier_adjustment_requests_mine()
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare result jsonb; actor uuid:=auth.uid();
begin
  if not private.yt_pos_work_cashier() or private.yt_work_owner() then raise exception 'cashier_only'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'kind',r.kind,'status',r.status,'gross_rm',r.gross_rm,'adjustment_rm',r.adjustment_rm,
    'net_rm',r.net_rm,'review_note',r.review_note,'reviewed_at',r.reviewed_at,'order_id',r.order_id,'order_no',o.order_no,'created_at',r.created_at) order by r.created_at desc),'[]'::jsonb)
    into result from (select * from public.yt_pos_cashier_adjustment_requests where requester_id=actor order by created_at desc limit 20) r
    left join public.yt_member_orders o on o.id=r.order_id;
  return result;
end;
$function$;
create or replace function public.yt_pos_cashier_adjustment_requests_mine()
returns jsonb language sql security definer set search_path = '' as $function$ select private.yt_pos_cashier_adjustment_requests_mine(); $function$;

create or replace function private.yt_pos_cashier_adjustment_review(p_request uuid,p_approve boolean,p_note text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare r public.yt_pos_cashier_adjustment_requests%rowtype; actor uuid:=auth.uid(); p jsonb; v_order jsonb; v_order_id uuid; v_gross numeric(12,2); v_foc jsonb; v_reason text; v_detail text;
begin
  if not private.yt_work_owner() then raise exception 'owner_only'; end if;
  select * into r from public.yt_pos_cashier_adjustment_requests where id=p_request for update;
  if not found then raise exception 'adjustment_request_not_found'; end if;
  if r.status<>'pending' then return coalesce(r.result,jsonb_build_object('id',r.id,'status',r.status,'order_id',r.order_id)); end if;
  if not p_approve then
    if length(btrim(coalesce(p_note,'')))<2 then raise exception 'rejection_note_required'; end if;
    update public.yt_pos_cashier_adjustment_requests set status='rejected',reviewer_id=actor,reviewed_at=clock_timestamp(),review_note=btrim(p_note),result=jsonb_build_object('id',r.id,'status','rejected') where id=r.id;
    insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'pos.cashier_adjustment_rejected','pos_cashier_adjustment',r.id,jsonb_build_object('requester_id',r.requester_id,'reason',btrim(p_note)));
    return jsonb_build_object('id',r.id,'status','rejected');
  end if;
  p:=r.request_payload; v_reason:=coalesce(p->>'reason','');
  if exists(select 1 from public.yt_pos_preorder_holds h where h.operator_id=r.requester_id and h.draft_id=r.draft_id and h.state in ('pending','chosen') and h.expires_at>clock_timestamp())
     or exists(select 1 from public.yt_moon_preorder_holds h where h.operator_id=r.requester_id and h.draft_id=r.draft_id and h.state='held' and h.expires_at>clock_timestamp()) then raise exception 'manual_adjustment_cannot_combine_code'; end if;
  select x.gross_rm into v_gross from private.yt_pos_draft_price(p->'items') x;
  if round(v_gross,2)<>r.gross_rm then raise exception 'adjustment_price_changed'; end if;
  v_order:=private.yt_pos_create_order_with_rewards_v4(r.id,nullif(p->>'table_label',''),nullif(p->>'order_note',''),p->'items','cashier',r.draft_id,coalesce(p->>'checkout_mode','pay_now'),nullif(p->>'business_day','')::date);
  v_order_id:=nullif(v_order->>'id','')::uuid;
  if v_order_id is null then raise exception 'order_not_found'; end if;
  if r.kind='foc' then
    v_foc:=coalesce(p->'foc_product_ids','[]'::jsonb);
    update public.yt_member_order_items i set unit_price_rm=0,item_name=i.item_name||' · FOC'
      where i.order_id=v_order_id and i.product_id in (select value::uuid from jsonb_array_elements_text(v_foc));
    v_detail:='Owner-approved FOC · '||v_reason;
  else
    v_detail:='Owner-approved Discount RM'||to_char(r.adjustment_rm,'FM999999990.00')||' · '||v_reason;
  end if;
  update public.yt_member_orders o set amount_rm=r.net_rm,created_by=r.requester_id,notes=concat_ws(E'\n',nullif(o.notes,''),v_detail),updated_at=clock_timestamp() where o.id=v_order_id;
  update public.yt_pos_cashier_adjustment_requests set status='approved',reviewer_id=actor,reviewed_at=clock_timestamp(),review_note=nullif(btrim(coalesce(p_note,'')),''),order_id=v_order_id,
    result=jsonb_build_object('id',r.id,'status','approved','order_id',v_order_id,'order_no',v_order->>'order_no','gross_rm',r.gross_rm,'adjustment_rm',r.adjustment_rm,'net_rm',r.net_rm) where id=r.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'pos.cashier_adjustment_approved','pos_order',v_order_id,jsonb_build_object('request_id',r.id,'requester_id',r.requester_id,'kind',r.kind,'gross_rm',r.gross_rm,'adjustment_rm',r.adjustment_rm,'net_rm',r.net_rm,'reason',v_reason));
  return jsonb_build_object('id',r.id,'status','approved','order_id',v_order_id,'order_no',v_order->>'order_no','amount_rm',r.net_rm);
end;
$function$;
create or replace function public.yt_pos_cashier_adjustment_review(p_request uuid,p_approve boolean,p_note text default null)
returns jsonb language sql security definer set search_path = '' as $function$ select private.yt_pos_cashier_adjustment_review(p_request,p_approve,p_note); $function$;

revoke all on function private.yt_pos_cashier_adjustment_submit(uuid,jsonb) from public,anon,authenticated;
revoke all on function private.yt_pos_cashier_adjustment_requests_list() from public,anon,authenticated;
revoke all on function private.yt_pos_cashier_adjustment_requests_mine() from public,anon,authenticated;
revoke all on function private.yt_pos_cashier_adjustment_review(uuid,boolean,text) from public,anon,authenticated;
revoke all on function public.yt_pos_cashier_adjustment_submit(uuid,jsonb) from public,anon;
revoke all on function public.yt_pos_cashier_adjustment_requests_list() from public,anon;
revoke all on function public.yt_pos_cashier_adjustment_requests_mine() from public,anon;
revoke all on function public.yt_pos_cashier_adjustment_review(uuid,boolean,text) from public,anon;
grant execute on function public.yt_pos_cashier_adjustment_submit(uuid,jsonb) to authenticated;
grant execute on function public.yt_pos_cashier_adjustment_requests_list() to authenticated;
grant execute on function public.yt_pos_cashier_adjustment_requests_mine() to authenticated;
grant execute on function public.yt_pos_cashier_adjustment_review(uuid,boolean,text) to authenticated;

