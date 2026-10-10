-- Store Box foundation: package/challenge entitlement, claim QR and drink requests.

create table public.yt_store_box_product_rules(
 product_id uuid primary key references public.yt_shop_products(id) on delete cascade,
 mode text not null default 'package' check(mode in ('package','challenge')),
 total_units integer not null check(total_units between 1 and 999),
 request_limit integer not null default 2 check(request_limit between 1 and 99),
 expiry_days integer not null default 30 check(expiry_days between 1 and 3650),
 unit_label text not null default '杯' check(length(btrim(unit_label)) between 1 and 12),
 completion_reward_id uuid references public.rewards(id) on delete set null,
 game_pass_enabled boolean not null default false,
 active boolean not null default true,
 updated_by uuid references public.work_accounts(auth_user_id) on delete set null,
 updated_at timestamptz not null default now()
);

create table public.yt_store_boxes(
 id uuid primary key default gen_random_uuid(),
 source_order_id uuid not null references public.yt_member_orders(id) on delete cascade,
 source_order_item_id uuid not null unique references public.yt_member_order_items(id) on delete cascade,
 product_id uuid references public.yt_shop_products(id) on delete set null,
 customer_id uuid references public.pin_accounts(auth_user_id) on delete cascade,
 name text not null,
 mode text not null check(mode in ('package','challenge')),
 unit_label text not null,
 total_units integer not null check(total_units between 1 and 999999),
 served_units integer not null default 0 check(served_units>=0),
 completed_units integer not null default 0 check(completed_units>=0),
 request_limit integer not null check(request_limit between 1 and 99),
 expiry_days integer not null check(expiry_days between 1 and 3650),
 completion_reward_id uuid references public.rewards(id) on delete set null,
 game_pass_enabled boolean not null default false,
 table_label text,
 status text not null default 'unclaimed' check(status in ('unclaimed','active','paused','exhausted','completed','expired','cancelled')),
 claimed_at timestamptz,
 storage_expires_at timestamptz,
 created_by uuid references public.work_accounts(auth_user_id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(completed_units<=served_units and served_units<=total_units)
);

create table public.yt_store_box_claims(
 id uuid primary key default gen_random_uuid(),
 box_id uuid not null references public.yt_store_boxes(id) on delete cascade,
 token_hash text not null unique,
 request_id uuid not null unique,
 status text not null default 'issued' check(status in ('issued','claimed','cancelled','expired')),
 issued_by uuid references public.work_accounts(auth_user_id) on delete set null,
 claimed_by uuid references public.pin_accounts(auth_user_id) on delete set null,
 cancelled_by uuid references public.work_accounts(auth_user_id) on delete set null,
 cancel_reason text,
 expires_at timestamptz not null,
 created_at timestamptz not null default now(),
 claimed_at timestamptz,
 cancelled_at timestamptz
);

create table public.yt_store_box_requests(
 id uuid primary key default gen_random_uuid(),
 box_id uuid not null references public.yt_store_boxes(id) on delete cascade,
 customer_id uuid references public.pin_accounts(auth_user_id) on delete set null,
 quantity integer not null check(quantity between 1 and 99),
 status text not null default 'pending' check(status in ('pending','accepted','preparing','served','cancelled','expired')),
 client_request_id uuid not null unique,
 table_label text,
 requested_at timestamptz not null default now(),
 expires_at timestamptz not null default (now()+interval '3 minutes'),
 accepted_by uuid references public.work_accounts(auth_user_id) on delete set null,
 accepted_at timestamptz,
 served_by uuid references public.work_accounts(auth_user_id) on delete set null,
 served_at timestamptz,
 cancelled_by uuid,
 cancelled_at timestamptz,
 cancel_reason text,
 completed_delta integer not null default 0 check(completed_delta>=0)
);

create table public.yt_store_box_events(
 id bigint generated always as identity primary key,
 box_id uuid not null references public.yt_store_boxes(id) on delete cascade,
 request_id uuid references public.yt_store_box_requests(id) on delete set null,
 event_type text not null,
 quantity integer not null default 0,
 completed_delta integer not null default 0,
 actor_id uuid references public.work_accounts(auth_user_id) on delete set null,
 customer_id uuid references public.pin_accounts(auth_user_id) on delete set null,
 note text,
 metadata jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);

create unique index yt_store_box_one_issued_claim_idx on public.yt_store_box_claims(box_id) where status='issued';
create unique index yt_store_box_one_active_request_idx on public.yt_store_box_requests(box_id) where status in ('pending','accepted','preparing');
create index yt_store_boxes_customer_idx on public.yt_store_boxes(customer_id,status,storage_expires_at);
create index yt_store_boxes_order_idx on public.yt_store_boxes(source_order_id);
create index yt_store_box_claims_active_idx on public.yt_store_box_claims(status,expires_at);
create index yt_store_box_requests_queue_idx on public.yt_store_box_requests(status,requested_at);
create index yt_store_box_events_box_idx on public.yt_store_box_events(box_id,created_at desc);

alter table public.yt_store_box_product_rules enable row level security;
alter table public.yt_store_boxes enable row level security;
alter table public.yt_store_box_claims enable row level security;
alter table public.yt_store_box_requests enable row level security;
alter table public.yt_store_box_events enable row level security;
revoke all on public.yt_store_box_product_rules,public.yt_store_boxes,public.yt_store_box_claims,public.yt_store_box_requests,public.yt_store_box_events from public,anon,authenticated;
revoke all on sequence public.yt_store_box_events_id_seq from public,anon,authenticated;

create function private.yt_store_box_customer() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null
  and exists(select 1 from public.pin_accounts p where p.auth_user_id=auth.uid())
  and not exists(select 1 from public.work_accounts w where w.auth_user_id=auth.uid())
$$;

create function private.yt_store_box_rule_list() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order,x.title),'[]'::jsonb) into rows from(
  select p.id product_id,p.title,p.category,p.price_rm,p.active product_active,p.sort_order,
   r.mode,r.total_units,r.request_limit,r.expiry_days,r.unit_label,r.completion_reward_id,
   rw.name completion_reward_name,r.game_pass_enabled,r.active,r.updated_at
  from public.yt_shop_products p left join public.yt_store_box_product_rules r on r.product_id=p.id
  left join public.rewards rw on rw.id=r.completion_reward_id
  order by p.sort_order,p.title
 )x;
 return rows;
end $$;

create function private.yt_store_box_rule_save(
 p_product uuid,p_mode text,p_total_units integer,p_request_limit integer default 2,
 p_expiry_days integer default 30,p_unit_label text default '杯',p_completion_reward uuid default null,
 p_game_pass_enabled boolean default false,p_active boolean default true
) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.yt_store_box_product_rules%rowtype;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_product is null or p_mode not in ('package','challenge') or p_total_units not between 1 and 999
  or p_request_limit not between 1 and 99 or p_expiry_days not between 1 and 3650
  or length(btrim(coalesce(p_unit_label,''))) not between 1 and 12 then raise exception 'invalid_store_box_rule';end if;
 if not exists(select 1 from public.yt_shop_products where id=p_product) then raise exception 'product_not_found';end if;
 if p_completion_reward is not null and not exists(select 1 from public.rewards where id=p_completion_reward) then raise exception 'reward_not_found';end if;
 insert into public.yt_store_box_product_rules(product_id,mode,total_units,request_limit,expiry_days,unit_label,completion_reward_id,game_pass_enabled,active,updated_by,updated_at)
 values(p_product,p_mode,p_total_units,p_request_limit,p_expiry_days,btrim(p_unit_label),p_completion_reward,coalesce(p_game_pass_enabled,false),coalesce(p_active,true),auth.uid(),clock_timestamp())
 on conflict(product_id) do update set mode=excluded.mode,total_units=excluded.total_units,request_limit=excluded.request_limit,
  expiry_days=excluded.expiry_days,unit_label=excluded.unit_label,completion_reward_id=excluded.completion_reward_id,
  game_pass_enabled=excluded.game_pass_enabled,active=excluded.active,updated_by=excluded.updated_by,updated_at=excluded.updated_at
 returning * into r;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(auth.uid(),'store_box.rule_save','product',p_product,to_jsonb(r));
 return to_jsonb(r);
end $$;

create function private.yt_store_box_issue_quote(p_order uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare o public.yt_member_orders%rowtype;rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 select * into o from public.yt_member_orders where id=p_order and source='future_pos';
 if not found then raise exception 'order_not_found';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.item_name),'[]'::jsonb) into rows from(
  select i.id order_item_id,i.product_id,i.item_name,i.quantity,r.mode,
   i.quantity*r.total_units total_units,r.request_limit,r.expiry_days,r.unit_label,
   r.game_pass_enabled,b.id box_id,b.status box_status,b.customer_id,b.served_units,b.completed_units,
   c.id active_claim_id,c.expires_at claim_expires_at
  from public.yt_member_order_items i join public.yt_store_box_product_rules r on r.product_id=i.product_id and r.active
  left join public.yt_store_boxes b on b.source_order_item_id=i.id
  left join public.yt_store_box_claims c on c.box_id=b.id and c.status='issued' and c.expires_at>clock_timestamp()
  where i.order_id=p_order and i.quantity>0
 )x;
 return jsonb_build_object('order_id',o.id,'order_no',o.order_no,'table_label',o.table_label,
  'ready',o.status='fulfilled' and o.payment_status='paid' and o.paid_at is not null and o.settlement_due_since is null and not o.cancel_after_refund,
  'items',rows);
end $$;

create function private.yt_store_box_issue(p_order_item uuid,p_token uuid,p_request uuid,p_minutes integer default 2) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();i public.yt_member_order_items%rowtype;o public.yt_member_orders%rowtype;
 r public.yt_store_box_product_rules%rowtype;b public.yt_store_boxes%rowtype;c public.yt_store_box_claims%rowtype;h text;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_order_item is null or p_token is null or p_request is null or p_minutes not between 1 and 15 then raise exception 'invalid_store_box_issue';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into i from public.yt_member_order_items where id=p_order_item;
 if not found then raise exception 'order_item_not_found';end if;
 select * into o from public.yt_member_orders where id=i.order_id and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 if o.status<>'fulfilled' or o.payment_status<>'paid' or o.paid_at is null then raise exception 'store_box_after_payment_only';end if;
 if o.settlement_due_since is not null or o.cancel_after_refund then raise exception 'order_payment_adjustment_pending';end if;
 select * into r from public.yt_store_box_product_rules where product_id=i.product_id and active;
 if not found then raise exception 'store_box_product_not_configured';end if;
 update public.yt_store_box_claims set status='expired' where box_id in(select id from public.yt_store_boxes where source_order_item_id=i.id) and status='issued' and expires_at<=clock_timestamp();
 select * into c from public.yt_store_box_claims where request_id=p_request;
 h:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 if found then
  if c.token_hash<>h then raise exception 'request_conflict';end if;
  return jsonb_build_object('box_id',c.box_id,'claim_id',c.id,'expires_at',c.expires_at);
 end if;
 insert into public.yt_store_boxes(source_order_id,source_order_item_id,product_id,customer_id,name,mode,unit_label,total_units,request_limit,expiry_days,completion_reward_id,game_pass_enabled,table_label,created_by)
 values(o.id,i.id,i.product_id,o.customer_id,i.item_name,r.mode,r.unit_label,i.quantity*r.total_units,r.request_limit,r.expiry_days,r.completion_reward_id,r.game_pass_enabled,o.table_label,actor)
 on conflict(source_order_item_id) do nothing;
 select * into b from public.yt_store_boxes where source_order_item_id=i.id for update;
 if b.status not in ('unclaimed','active','paused','exhausted') then raise exception 'store_box_not_issuable';end if;
 if b.customer_id is not null and b.claimed_at is not null then raise exception 'store_box_already_claimed';end if;
 if exists(select 1 from public.yt_store_box_claims where box_id=b.id and status='issued') then raise exception 'store_box_claim_already_active';end if;
 insert into public.yt_store_box_claims(box_id,token_hash,request_id,issued_by,expires_at)
 values(b.id,h,p_request,actor,clock_timestamp()+make_interval(mins=>p_minutes)) returning * into c;
 insert into public.yt_store_box_events(box_id,event_type,actor_id,metadata)
 values(b.id,'claim_issued',actor,jsonb_build_object('claim_id',c.id,'order_id',o.id,'order_item_id',i.id));
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(actor,'store_box.claim_issue','store_box',b.id,jsonb_build_object('claim_id',c.id,'order_id',o.id));
 return jsonb_build_object('box_id',b.id,'claim_id',c.id,'expires_at',c.expires_at,'name',b.name,'total_units',b.total_units,'unit_label',b.unit_label);
end $$;

create function private.yt_store_box_claims_active() returns jsonb language plpgsql security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_box_claims set status='expired' where status='issued' and expires_at<=clock_timestamp();
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into rows from(
  select c.id claim_id,c.box_id,c.expires_at,c.created_at,c.issued_by,w.username issued_by_name,
   b.name,b.mode,b.total_units,b.unit_label,b.table_label,o.id order_id,o.order_no
  from public.yt_store_box_claims c join public.yt_store_boxes b on b.id=c.box_id
  join public.yt_member_orders o on o.id=b.source_order_id
  left join public.work_accounts w on w.auth_user_id=c.issued_by
  where c.status='issued' and c.expires_at>clock_timestamp()
 )x;
 return rows;
end $$;

create function private.yt_store_box_claim_cancel(p_claim uuid,p_reason text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.yt_store_box_claims%rowtype;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_claim is null or length(btrim(coalesce(p_reason,''))) not between 2 and 200 then raise exception 'invalid_claim_cancellation';end if;
 select * into c from public.yt_store_box_claims where id=p_claim for update;
 if not found then raise exception 'store_box_claim_not_found';end if;
 if c.status='cancelled' then return jsonb_build_object('ok',true,'already_cancelled',true);end if;
 if c.status<>'issued' then raise exception 'store_box_claim_not_cancellable';end if;
 update public.yt_store_box_claims set status='cancelled',cancelled_by=auth.uid(),cancelled_at=clock_timestamp(),cancel_reason=btrim(p_reason) where id=c.id;
 insert into public.yt_store_box_events(box_id,event_type,actor_id,note) values(c.box_id,'claim_cancelled',auth.uid(),btrim(p_reason));
 return jsonb_build_object('ok',true,'box_id',c.box_id);
end $$;

create function private.yt_store_box_claim_preview(p_token uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.yt_store_box_claims%rowtype;b public.yt_store_boxes%rowtype;h text;
begin
 if not private.yt_store_box_customer() then raise exception 'customer_only';end if;
 if p_token is null then raise exception 'store_box_claim_invalid';end if;
 h:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 select * into c from public.yt_store_box_claims where token_hash=h;
 if not found or c.status<>'issued' or c.expires_at<=clock_timestamp() then raise exception 'store_box_claim_invalid';end if;
 select * into b from public.yt_store_boxes where id=c.box_id;
 if b.customer_id is not null and b.customer_id<>auth.uid() then raise exception 'store_box_claim_invalid';end if;
 return jsonb_build_object('claim_id',c.id,'name',b.name,'mode',b.mode,'total_units',b.total_units,'unit_label',b.unit_label,'expires_at',c.expires_at);
end $$;

create function private.yt_store_box_claim(p_token uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();c public.yt_store_box_claims%rowtype;b public.yt_store_boxes%rowtype;h text;
begin
 if not private.yt_store_box_customer() then raise exception 'customer_only';end if;
 if p_token is null then raise exception 'store_box_claim_invalid';end if;
 perform pg_advisory_xact_lock(781943084);
 h:=encode(sha256(convert_to(p_token::text,'UTF8')),'hex');
 select * into c from public.yt_store_box_claims where token_hash=h for update;
 if not found then raise exception 'store_box_claim_invalid';end if;
 select * into b from public.yt_store_boxes where id=c.box_id for update;
 if c.status='claimed' and c.claimed_by=actor and b.customer_id=actor then return to_jsonb(b);end if;
 if c.status<>'issued' or c.expires_at<=clock_timestamp() then raise exception 'store_box_claim_invalid';end if;
 if b.customer_id is not null and b.customer_id<>actor then raise exception 'store_box_claim_invalid';end if;
 if b.status not in ('unclaimed','active') then raise exception 'store_box_not_claimable';end if;
 update public.yt_store_boxes set customer_id=actor,status='active',claimed_at=coalesce(claimed_at,clock_timestamp()),
  storage_expires_at=coalesce(storage_expires_at,clock_timestamp()+make_interval(days=>expiry_days)),updated_at=clock_timestamp()
 where id=b.id returning * into b;
 update public.yt_store_box_claims set status='claimed',claimed_by=actor,claimed_at=clock_timestamp() where id=c.id;
 insert into public.yt_store_box_events(box_id,event_type,customer_id) values(b.id,'claimed',actor);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(actor,'store_box.claim','store_box',b.id);
 return to_jsonb(b);
end $$;

create function private.yt_my_store_boxes() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;actor uuid:=auth.uid();
begin
 if not private.yt_store_box_customer() then raise exception 'customer_only';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.storage_expires_at,x.created_at desc),'[]'::jsonb) into rows from(
  select b.id,b.name,b.mode,b.unit_label,b.total_units,b.served_units,b.completed_units,
   b.total_units-b.served_units remaining_units,b.request_limit,b.table_label,
   case when b.storage_expires_at<=clock_timestamp() and b.status not in ('completed','cancelled') then 'expired' else b.status end status,
   b.claimed_at,b.storage_expires_at,b.created_at,
   r.id active_request_id,r.quantity active_request_quantity,r.status active_request_status,r.requested_at
  from public.yt_store_boxes b left join public.yt_store_box_requests r on r.box_id=b.id and r.status in ('pending','accepted','preparing')
  where b.customer_id=actor
 )x;
 return rows;
end $$;

create function private.yt_store_box_request(p_box uuid,p_quantity integer,p_request uuid,p_table_label text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();b public.yt_store_boxes%rowtype;r public.yt_store_box_requests%rowtype;
begin
 if not private.yt_store_box_customer() then raise exception 'customer_only';end if;
 if p_box is null or p_request is null or p_quantity is null or p_quantity<1 or length(coalesce(p_table_label,''))>40 then raise exception 'invalid_store_box_request';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into r from public.yt_store_box_requests where client_request_id=p_request;
 if found then
  if r.box_id<>p_box or r.quantity<>p_quantity or r.customer_id<>actor then raise exception 'request_conflict';end if;
  return to_jsonb(r);
 end if;
 select * into b from public.yt_store_boxes where id=p_box and customer_id=actor for update;
 if not found then raise exception 'store_box_not_found';end if;
 update public.yt_store_box_requests set status='expired' where box_id=b.id and status='pending' and expires_at<=clock_timestamp();
 if b.storage_expires_at<=clock_timestamp() then update public.yt_store_boxes set status='expired',updated_at=clock_timestamp() where id=b.id;raise exception 'store_box_expired';end if;
 if b.status not in ('active','exhausted') or b.served_units>=b.total_units then raise exception 'store_box_not_available';end if;
 if p_quantity>b.request_limit or p_quantity>b.total_units-b.served_units then raise exception 'store_box_quantity_unavailable';end if;
 if exists(select 1 from public.yt_store_box_requests where box_id=b.id and status in ('pending','accepted','preparing')) then raise exception 'store_box_request_already_active';end if;
 insert into public.yt_store_box_requests(box_id,customer_id,quantity,client_request_id,table_label)
 values(b.id,actor,p_quantity,p_request,nullif(btrim(p_table_label),'')) returning * into r;
 update public.yt_store_boxes set table_label=coalesce(nullif(btrim(p_table_label),''),table_label),updated_at=clock_timestamp() where id=b.id;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,customer_id) values(b.id,r.id,'drink_requested',p_quantity,actor);
 return to_jsonb(r);
end $$;

create function private.yt_store_box_request_cancel(p_request uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();r public.yt_store_box_requests%rowtype;
begin
 if not private.yt_store_box_customer() then raise exception 'customer_only';end if;
 select * into r from public.yt_store_box_requests where id=p_request and customer_id=actor for update;
 if not found then raise exception 'store_box_request_not_found';end if;
 if r.status='cancelled' then return jsonb_build_object('ok',true,'already_cancelled',true);end if;
 if r.status<>'pending' then raise exception 'store_box_request_not_cancellable';end if;
 update public.yt_store_box_requests set status='cancelled',cancelled_by=actor,cancelled_at=clock_timestamp(),cancel_reason='customer_cancelled' where id=r.id;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,customer_id) values(r.box_id,r.id,'drink_request_cancelled',r.quantity,actor);
 return jsonb_build_object('ok',true,'box_id',r.box_id);
end $$;

create function private.yt_store_box_queue() returns jsonb language plpgsql security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 update public.yt_store_box_requests set status='expired' where status='pending' and expires_at<=clock_timestamp();
 select coalesce(jsonb_agg(to_jsonb(x) order by x.requested_at),'[]'::jsonb) into rows from(
  select r.id request_id,r.status,r.quantity,r.table_label,r.requested_at,r.expires_at,r.accepted_by,wa.username accepted_by_name,
   b.id box_id,b.name,b.mode,b.unit_label,b.total_units,b.served_units,b.completed_units,b.total_units-b.served_units remaining_units,
   b.customer_id,p.phone customer_phone,coalesce(pr.display_name,p.phone) customer_name,o.order_no
  from public.yt_store_box_requests r join public.yt_store_boxes b on b.id=r.box_id
  join public.yt_member_orders o on o.id=b.source_order_id
  left join public.pin_accounts p on p.auth_user_id=b.customer_id
  left join public.profiles pr on pr.id=b.customer_id
  left join public.work_accounts wa on wa.auth_user_id=r.accepted_by
  where r.status in ('pending','accepted','preparing')
 )x;
 return rows;
end $$;

create function private.yt_store_box_request_action(p_request uuid,p_action text,p_completed_delta integer default 0,p_reason text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();r public.yt_store_box_requests%rowtype;b public.yt_store_boxes%rowtype;next_status text;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_request is null or p_action not in ('accept','prepare','serve','cancel') or coalesce(p_completed_delta,0)<0 or length(coalesce(p_reason,''))>200 then raise exception 'invalid_store_box_action';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into r from public.yt_store_box_requests where id=p_request for update;
 if not found then raise exception 'store_box_request_not_found';end if;
 select * into b from public.yt_store_boxes where id=r.box_id for update;
 if p_action='accept' then
  if r.status='accepted' and r.accepted_by=actor then return to_jsonb(r);end if;
  if r.status<>'pending' or r.expires_at<=clock_timestamp() then raise exception 'store_box_request_not_pending';end if;
  update public.yt_store_box_requests set status='accepted',accepted_by=actor,accepted_at=clock_timestamp() where id=r.id returning * into r;
  next_status:='drink_request_accepted';
 elsif p_action='prepare' then
  if r.status<>'accepted' then raise exception 'store_box_request_not_accepted';end if;
  update public.yt_store_box_requests set status='preparing' where id=r.id returning * into r;
  next_status:='drink_request_preparing';
 elsif p_action='serve' then
  if r.status not in ('pending','accepted','preparing') then raise exception 'store_box_request_not_active';end if;
  if b.status not in ('active','exhausted') or b.storage_expires_at<=clock_timestamp() then raise exception 'store_box_not_available';end if;
  if r.quantity>b.total_units-b.served_units then raise exception 'store_box_quantity_unavailable';end if;
  if p_completed_delta>b.served_units+r.quantity-b.completed_units then raise exception 'store_box_completed_units_invalid';end if;
  update public.yt_store_box_requests set status='served',served_by=actor,served_at=clock_timestamp(),completed_delta=p_completed_delta where id=r.id returning * into r;
  update public.yt_store_boxes set served_units=served_units+r.quantity,completed_units=completed_units+p_completed_delta,
   status=case when completed_units+p_completed_delta=total_units then 'completed' when served_units+r.quantity=total_units then 'exhausted' else 'active' end,
   updated_at=clock_timestamp() where id=b.id returning * into b;
  next_status:='drink_served';
 else
  if r.status not in ('pending','accepted','preparing') then raise exception 'store_box_request_not_active';end if;
  if r.status in ('accepted','preparing') and length(btrim(coalesce(p_reason,'')))<2 then raise exception 'cancel_reason_required';end if;
  update public.yt_store_box_requests set status='cancelled',cancelled_by=actor,cancelled_at=clock_timestamp(),cancel_reason=nullif(btrim(p_reason),'') where id=r.id returning * into r;
  next_status:='drink_request_cancelled';
 end if;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,completed_delta,actor_id,note)
 values(b.id,r.id,next_status,r.quantity,case when p_action='serve' then p_completed_delta else 0 end,actor,nullif(btrim(p_reason),''));
 return jsonb_build_object('request',to_jsonb(r),'box',to_jsonb(b));
end $$;

create function private.yt_store_box_progress(p_box uuid,p_action text,p_completed_delta integer default 0) returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.yt_store_boxes%rowtype;event_name text;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_box is null or p_action not in ('complete','pause','resume') or coalesce(p_completed_delta,0)<0 then raise exception 'invalid_store_box_progress';end if;
 select * into b from public.yt_store_boxes where id=p_box for update;
 if not found then raise exception 'store_box_not_found';end if;
 if p_action='complete' then
  if p_completed_delta<1 or b.completed_units+p_completed_delta>b.served_units then raise exception 'store_box_completed_units_invalid';end if;
  update public.yt_store_boxes set completed_units=completed_units+p_completed_delta,
   status=case when completed_units+p_completed_delta=total_units then 'completed' when served_units=total_units then 'exhausted' else 'active' end,updated_at=clock_timestamp()
  where id=b.id returning * into b;event_name:='drink_completed';
 elsif p_action='pause' then
  if b.status not in ('active','exhausted') then raise exception 'store_box_not_active';end if;
  update public.yt_store_boxes set status='paused',updated_at=clock_timestamp() where id=b.id returning * into b;event_name:='box_paused';
 else
  if b.status<>'paused' then raise exception 'store_box_not_paused';end if;
  update public.yt_store_boxes set status=case when served_units=total_units then 'exhausted' else 'active' end,updated_at=clock_timestamp() where id=b.id returning * into b;event_name:='box_resumed';
 end if;
 insert into public.yt_store_box_events(box_id,event_type,completed_delta,actor_id) values(b.id,event_name,case when p_action='complete' then p_completed_delta else 0 end,auth.uid());
 return to_jsonb(b);
end $$;

create function public.yt_store_box_rule_list() returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_rule_list()$$;
create function public.yt_store_box_rule_save(uuid,text,integer,integer,integer,text,uuid,boolean,boolean) returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_rule_save($1,$2,$3,$4,$5,$6,$7,$8,$9)$$;
create function public.yt_store_box_issue_quote(uuid) returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_issue_quote($1)$$;
create function public.yt_store_box_issue(uuid,uuid,uuid,integer) returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_issue($1,$2,$3,$4)$$;
create function public.yt_store_box_claims_active() returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_claims_active()$$;
create function public.yt_store_box_claim_cancel(uuid,text) returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_claim_cancel($1,$2)$$;
create function public.yt_store_box_claim_preview(uuid) returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_claim_preview($1)$$;
create function public.yt_store_box_claim(uuid) returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_claim($1)$$;
create function public.yt_my_store_boxes() returns jsonb language sql security invoker set search_path='' as $$select private.yt_my_store_boxes()$$;
create function public.yt_store_box_request(uuid,integer,uuid,text) returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_request($1,$2,$3,$4)$$;
create function public.yt_store_box_request_cancel(uuid) returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_request_cancel($1)$$;
create function public.yt_store_box_queue() returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_queue()$$;
create function public.yt_store_box_request_action(uuid,text,integer,text) returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_request_action($1,$2,$3,$4)$$;
create function public.yt_store_box_progress(uuid,text,integer) returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_progress($1,$2,$3)$$;

revoke all on function private.yt_store_box_customer(),private.yt_store_box_rule_list(),private.yt_store_box_rule_save(uuid,text,integer,integer,integer,text,uuid,boolean,boolean),private.yt_store_box_issue_quote(uuid),private.yt_store_box_issue(uuid,uuid,uuid,integer),private.yt_store_box_claims_active(),private.yt_store_box_claim_cancel(uuid,text),private.yt_store_box_claim_preview(uuid),private.yt_store_box_claim(uuid),private.yt_my_store_boxes(),private.yt_store_box_request(uuid,integer,uuid,text),private.yt_store_box_request_cancel(uuid),private.yt_store_box_queue(),private.yt_store_box_request_action(uuid,text,integer,text),private.yt_store_box_progress(uuid,text,integer) from public,anon;
revoke all on function public.yt_store_box_rule_list(),public.yt_store_box_rule_save(uuid,text,integer,integer,integer,text,uuid,boolean,boolean),public.yt_store_box_issue_quote(uuid),public.yt_store_box_issue(uuid,uuid,uuid,integer),public.yt_store_box_claims_active(),public.yt_store_box_claim_cancel(uuid,text),public.yt_store_box_claim_preview(uuid),public.yt_store_box_claim(uuid),public.yt_my_store_boxes(),public.yt_store_box_request(uuid,integer,uuid,text),public.yt_store_box_request_cancel(uuid),public.yt_store_box_queue(),public.yt_store_box_request_action(uuid,text,integer,text),public.yt_store_box_progress(uuid,text,integer) from public,anon;
grant execute on function private.yt_store_box_customer(),private.yt_store_box_rule_list(),private.yt_store_box_rule_save(uuid,text,integer,integer,integer,text,uuid,boolean,boolean),private.yt_store_box_issue_quote(uuid),private.yt_store_box_issue(uuid,uuid,uuid,integer),private.yt_store_box_claims_active(),private.yt_store_box_claim_cancel(uuid,text),private.yt_store_box_claim_preview(uuid),private.yt_store_box_claim(uuid),private.yt_my_store_boxes(),private.yt_store_box_request(uuid,integer,uuid,text),private.yt_store_box_request_cancel(uuid),private.yt_store_box_queue(),private.yt_store_box_request_action(uuid,text,integer,text),private.yt_store_box_progress(uuid,text,integer) to authenticated;
grant execute on function public.yt_store_box_rule_list(),public.yt_store_box_rule_save(uuid,text,integer,integer,integer,text,uuid,boolean,boolean),public.yt_store_box_issue_quote(uuid),public.yt_store_box_issue(uuid,uuid,uuid,integer),public.yt_store_box_claims_active(),public.yt_store_box_claim_cancel(uuid,text),public.yt_store_box_claim_preview(uuid),public.yt_store_box_claim(uuid),public.yt_my_store_boxes(),public.yt_store_box_request(uuid,integer,uuid,text),public.yt_store_box_request_cancel(uuid),public.yt_store_box_queue(),public.yt_store_box_request_action(uuid,text,integer,text),public.yt_store_box_progress(uuid,text,integer) to authenticated;
