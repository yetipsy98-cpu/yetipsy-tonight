-- Allow Staff and Cashier to request expiry recovery by Store Box number.
-- Add auditable Owner controls for remaining component balances and expiry business days.
alter table public.yt_store_box_reopen_requests
 add column if not exists requested_by uuid;
update public.yt_store_box_reopen_requests
 set requested_by=customer_id
 where requested_by is null;
alter table public.yt_store_box_reopen_requests
 alter column customer_id drop not null,
 alter column requested_by set not null;
do $$
begin
 if not exists(
  select 1 from pg_constraint
  where conrelid='public.yt_store_box_reopen_requests'::regclass
   and conname='yt_store_box_reopen_requested_by_fk'
 ) then
  alter table public.yt_store_box_reopen_requests
   add constraint yt_store_box_reopen_requested_by_fk
   foreign key(requested_by) references auth.users(id) on delete cascade;
 end if;
end $$;
create index if not exists yt_store_box_reopen_requested_by_idx
 on public.yt_store_box_reopen_requests(requested_by);

create or replace function private.yt_store_box_reopen_request(p_box uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 actor uuid:=auth.uid();
 b public.yt_store_boxes%rowtype;
 r public.yt_store_box_reopen_requests%rowtype;
 is_work_staff boolean;
 is_customer boolean;
begin
 if actor is null then raise exception 'authentication_required';end if;
 select exists(
  select 1 from public.work_accounts wa
  join public.staff_roles sr on sr.user_id=wa.auth_user_id
  where wa.auth_user_id=actor and wa.active and not wa.must_change_password
   and wa.role in ('staff','cashier') and sr.active and sr.role=wa.role
 ) into is_work_staff;
 is_customer:=private.yt_store_box_customer();
 if not is_work_staff and not is_customer then raise exception 'customer_only';end if;
 if p_box is null then raise exception 'invalid_store_box_reopen_request';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into b from public.yt_store_boxes where id=p_box for update;
 if not found then raise exception 'store_box_not_found';end if;
 if is_customer and not is_work_staff and b.customer_id is distinct from actor then raise exception 'store_box_not_found';end if;
 if (is_customer and not is_work_staff and b.claimed_at is null)
   or b.storage_expires_at is null or b.storage_expires_at>clock_timestamp()
   or b.total_units<=b.served_units or b.status in ('completed','cancelled') then
  raise exception 'store_box_not_reopenable';
 end if;
 select * into r from public.yt_store_box_reopen_requests
  where box_id=b.id and status='pending' for update;
 if found then return jsonb_build_object('id',r.id,'status',r.status,'requested_at',r.requested_at,'already_pending',true);end if;
 insert into public.yt_store_box_reopen_requests(box_id,customer_id,requested_by)
 values(b.id,b.customer_id,actor) returning * into r;
 return jsonb_build_object('id',r.id,'status',r.status,'requested_at',r.requested_at,'already_pending',false);
end $$;

create or replace function private.yt_store_box_reopen_list() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.requested_at),'[]'::jsonb) into rows
 from(
  select r.id request_id,r.requested_at,r.status,r.review_note,
   b.id box_id,b.box_number,b.name,b.unit_label,b.total_units,b.served_units,
   b.total_units-b.served_units remaining_units,b.storage_expires_at,b.expiry_days,b.table_label,
   coalesce(nullif(wa.username,''),nullif(rp.display_name,''),request_phone.phone,'工作账号') requester_name,
   coalesce(nullif(cp.display_name,''),customer_phone.phone,'顾客') customer_name
  from public.yt_store_box_reopen_requests r
  join public.yt_store_boxes b on b.id=r.box_id
  left join public.work_accounts wa on wa.auth_user_id=r.requested_by
  left join public.profiles rp on rp.id=r.requested_by
  left join public.pin_accounts request_phone on request_phone.auth_user_id=r.requested_by
  left join public.profiles cp on cp.id=r.customer_id
  left join public.pin_accounts customer_phone on customer_phone.auth_user_id=r.customer_id
  where r.status='pending'
  order by r.requested_at
  limit 100
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_staff_search(p_number text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare rows jsonb;v_query text;can_view boolean:=private.yt_store_box_can_view_claim_identity();
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 v_query:=upper(regexp_replace(btrim(coalesce(p_number,'')),'[^A-Z0-9]','','g'));
 if length(v_query)<2 or length(v_query)>24 then raise exception 'invalid_store_box_number_search';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.storage_expires_at desc,x.updated_at desc),'[]'::jsonb) into rows
 from(
  select b.id,b.box_number,b.name,b.mode,
   case when b.storage_expires_at<=clock_timestamp() and b.status not in ('completed','cancelled') then 'expired' else b.status end status,
   b.unit_label,b.total_units,b.served_units,b.components,b.selection_mode,
   b.total_units-b.served_units remaining_units,b.request_limit,b.table_label,b.cashier_managed,
   (b.customer_id is not null or (b.cashier_managed and b.status in ('unclaimed','active'))) cashier_serve_allowed,
   case when can_view then coalesce(nullif(pr.display_name,''),p.phone,'顾客') else null end customer_name,
   case when can_view then p.phone else null end customer_phone,
   b.claimed_at,b.storage_expires_at,
   private.yt_business_day(b.storage_expires_at-interval '1 microsecond') storage_expiry_business_day,
   private.yt_business_day(clock_timestamp()) current_business_day,b.updated_at,
   r.id active_request_id,r.status active_request_status,r.quantity active_request_quantity,r.component_name active_request_component_name,
   rr.status reopen_request_status,
   case when can_view then wa.username else null end claimed_qr_issued_by_name
  from public.yt_store_boxes b
  left join public.pin_accounts p on p.auth_user_id=b.customer_id
  left join public.profiles pr on pr.id=b.customer_id
  left join public.yt_store_box_requests r on r.box_id=b.id and r.status in ('pending','accepted','preparing')
  left join lateral(select c.issued_by from public.yt_store_box_claims c where c.box_id=b.id and c.status='claimed' order by c.claimed_at desc,c.created_at desc limit 1) cq on true
  left join public.work_accounts wa on wa.auth_user_id=cq.issued_by
  left join lateral(select q.status from public.yt_store_box_reopen_requests q where q.box_id=b.id and q.status='pending' order by q.requested_at desc limit 1) rr on true
  where upper(replace(b.box_number,'-','')) like '%'||v_query||'%'
  order by b.updated_at desc limit 50
 )x;
 return rows;
end $$;

create or replace function private.yt_store_box_owner_manage(
 p_box uuid,p_component_deltas jsonb default '[]'::jsonb,p_expires_on date default null
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 actor uuid:=auth.uid();
 b public.yt_store_boxes%rowtype;
 entry jsonb;
 candidate jsonb;
 seen_keys jsonb:='[]'::jsonb;
 next_components jsonb;
 new_components jsonb;
 v_key text;
 v_delta integer;
 v_current integer;
 v_served integer;
 v_total integer;
 v_remaining integer;
 v_before_remaining integer;
 v_today date;
 v_old_expiry date;
 v_new_expiry timestamptz;
 v_is_expired boolean;
 v_new_status text;
 v_event_id bigint;
 v_note text;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_box is null then raise exception 'invalid_store_box_adjustment';end if;
 if p_component_deltas is null or jsonb_typeof(p_component_deltas)<>'array' then
  raise exception 'invalid_store_box_adjustment';
 end if;
 if jsonb_array_length(p_component_deltas)>20 then raise exception 'invalid_store_box_adjustment';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into b from public.yt_store_boxes where id=p_box for update;
 if not found then raise exception 'store_box_not_found';end if;
 if b.status in ('completed','cancelled') then raise exception 'store_box_not_manageable';end if;
 if exists(select 1 from public.yt_store_box_requests where box_id=b.id and status in ('pending','accepted','preparing')) then
  raise exception 'store_box_request_in_progress';
 end if;
 v_today:=private.yt_business_day(clock_timestamp());
 v_is_expired:=b.storage_expires_at is null or b.storage_expires_at<=clock_timestamp() or b.status='expired';
 v_before_remaining:=b.total_units-b.served_units;
 v_old_expiry:=case when b.storage_expires_at is null then null else private.yt_business_day(b.storage_expires_at-interval '1 microsecond') end;
 if p_expires_on is null and jsonb_array_length(p_component_deltas)=0 then raise exception 'store_box_no_changes';end if;
 if p_expires_on is not null and p_expires_on<v_today then raise exception 'invalid_store_box_expiry_day';end if;
 if jsonb_array_length(p_component_deltas)>0 then
  if v_is_expired or b.status not in ('active','paused') then raise exception 'store_box_balance_edit_active_only';end if;
  if b.components is null or jsonb_typeof(b.components)<>'array' then raise exception 'invalid_store_box_components';end if;
  new_components:=b.components;
  if jsonb_array_length(new_components)=0 then
   new_components:=jsonb_build_array(jsonb_build_object('key','default','name',b.name,'total_units',b.total_units,'served_units',b.served_units));
  end if;
  for entry in select value from jsonb_array_elements(p_component_deltas) loop
   v_key:=nullif(btrim(entry->>'key'),'');
   if v_key is null or coalesce(entry->>'delta','') !~ '^-?[0-9]{1,6}$' then raise exception 'invalid_store_box_adjustment';end if;
   if exists(select 1 from jsonb_array_elements(seen_keys) x where x->>'key'=v_key) then raise exception 'duplicate_store_box_component_adjustment';end if;
   seen_keys:=seen_keys||jsonb_build_array(jsonb_build_object('key',v_key));
   v_delta:=(entry->>'delta')::integer;
   if v_delta=0 then continue;end if;
   select value into candidate from jsonb_array_elements(new_components) where value->>'key'=v_key;
   if candidate is null then raise exception 'store_box_component_not_found';end if;
   v_current:=coalesce((candidate->>'total_units')::integer,0);
   v_served:=coalesce((candidate->>'served_units')::integer,0);
   if v_current+v_delta<v_served then raise exception 'store_box_adjustment_below_served';end if;
   if v_current+v_delta>999999 then raise exception 'store_box_adjustment_too_large';end if;
   select jsonb_agg(
    case when x->>'key'=v_key then jsonb_set(x,'{total_units}',to_jsonb(v_current+v_delta),true) else x end
    order by ord
   ) into next_components from jsonb_array_elements(new_components) with ordinality e(x,ord);
   new_components:=coalesce(next_components,'[]'::jsonb);
  end loop;
  select coalesce(sum((value->>'total_units')::integer),0)
   into v_total from jsonb_array_elements(new_components);
 else
  new_components:=b.components;
  v_total:=b.total_units;
 end if;
 if v_total<1 or v_total>999999 or b.served_units>v_total then raise exception 'store_box_adjustment_below_served';end if;
 v_remaining:=v_total-b.served_units;
 if p_expires_on is not null then
  if v_remaining<=0 then raise exception 'store_box_not_reopenable';end if;
  v_new_expiry:=private.yt_business_start(p_expires_on+1);
  if v_new_expiry<=clock_timestamp() then raise exception 'invalid_store_box_expiry_day';end if;
 else
  v_new_expiry:=b.storage_expires_at;
 end if;
 if v_remaining=0 then v_new_status:='exhausted';
 elsif v_is_expired and p_expires_on is not null then v_new_status:='active';
 elsif b.status='paused' then v_new_status:='paused';
 else v_new_status:='active';
 end if;
 update public.yt_store_boxes
  set total_units=v_total,components=new_components,storage_expires_at=v_new_expiry,status=v_new_status,updated_at=clock_timestamp()
  where id=b.id returning * into b;
 if p_expires_on is not null then
  update public.yt_store_box_reopen_requests
   set status='approved',reviewed_at=clock_timestamp(),reviewed_by=actor,expires_at=v_new_expiry,
       review_note='Owner 已直接修改到期日'
   where box_id=b.id and status='pending';
 end if;
 v_note:='剩余余额 '||v_before_remaining::text||' → '||v_remaining::text||b.unit_label;
 if p_expires_on is not null and p_expires_on is distinct from v_old_expiry then
  v_note:=v_note||' · 到期营业日 '||coalesce(v_old_expiry::text,'未设置')||' → '||p_expires_on::text;
 end if;
 insert into public.yt_store_box_events(box_id,event_type,quantity,actor_id,customer_id,note,metadata)
 values(b.id,'box_adjusted',abs(v_remaining-v_before_remaining),actor,b.customer_id,v_note,
  jsonb_build_object('remaining_before',v_before_remaining,'remaining_after',v_remaining,
   'expires_on_before',v_old_expiry,'expires_on_after',case when p_expires_on is null then v_old_expiry else p_expires_on end,
   'component_deltas',p_component_deltas))
 returning id into v_event_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(actor,'store_box.owner_manage','store_box',b.id,
  jsonb_build_object('event_id',v_event_id,'box_number',b.box_number,'remaining_before',v_before_remaining,
   'remaining_after',v_remaining,'expires_on_before',v_old_expiry,
   'expires_on_after',case when p_expires_on is null then v_old_expiry else p_expires_on end,
   'component_deltas',p_component_deltas));
 return jsonb_build_object('box',to_jsonb(b),'remaining_units',v_remaining,'storage_expiry_business_day',
  private.yt_business_day(b.storage_expires_at-interval '1 microsecond'));
end $$;

create or replace function public.yt_store_box_owner_manage(
 p_box uuid,p_component_deltas jsonb default '[]'::jsonb,p_expires_on date default null
) returns jsonb
language sql security invoker set search_path='' as $$
 select private.yt_store_box_owner_manage(p_box,p_component_deltas,p_expires_on)
$$;

revoke all on function private.yt_store_box_owner_manage(uuid,jsonb,date) from public,anon;
revoke all on function public.yt_store_box_owner_manage(uuid,jsonb,date) from public,anon;
grant execute on function private.yt_store_box_owner_manage(uuid,jsonb,date) to authenticated;
grant execute on function public.yt_store_box_owner_manage(uuid,jsonb,date) to authenticated;
