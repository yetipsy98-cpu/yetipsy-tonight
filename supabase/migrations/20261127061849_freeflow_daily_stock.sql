-- FreeFlow-only daily availability. Expiry is evaluated by the database; no browser/cron reset is required.
create table private.yt_ff_stock(product_id uuid primary key references public.yt_shop_products(id),expires_at timestamptz not null,changed_at timestamptz not null,changed_by uuid not null);
alter table private.yt_ff_stock enable row level security;
revoke all on private.yt_ff_stock from public,anon,authenticated;

create function private.yt_ff_stock_until(p_time timestamptz) returns timestamptz language sql stable set search_path='' as $$
 select max(en) from (
  select ((private.yt_business_day(p_time)+case when m.end_time<=m.start_time then 1 else 0 end)+m.end_time) at time zone 'Asia/Kuala_Lumpur' en
  from public.yt_freeflow_menus m where m.active and (m.valid_from is null or m.valid_from<=private.yt_business_day(p_time)) and (m.valid_to is null or m.valid_to>=private.yt_business_day(p_time))
  union all select s.ends_at from public.yt_freeflow_sessions s join public.yt_member_orders o on o.id=s.order_id
   where s.business_day=private.yt_business_day(p_time) and s.status<>'closed' and o.status not in('cancelled','refunded') and o.payment_status<>'refunded' and not o.cancel_after_refund
 ) t
$$;
revoke all on function private.yt_ff_stock_until(timestamptz) from public,anon,authenticated;

create function private.yt_ff_stock_products(p_products jsonb) returns jsonb language sql stable set search_path='' as $$
 select coalesce(jsonb_agg(j.value||jsonb_build_object('sold_out',exists(select 1 from private.yt_ff_stock s where s.product_id=(j.value->>'id')::uuid and s.expires_at>clock_timestamp())) order by j.ord),'[]')
 from jsonb_array_elements(coalesce(p_products,'[]')) with ordinality j(value,ord)
$$;
revoke all on function private.yt_ff_stock_products(jsonb) from public,anon,authenticated;

-- Preserve the tested ordering and guest authorization implementation, enrich only read responses.
alter function private.yt_freeflow_core(uuid,boolean,text,jsonb) rename to yt_freeflow_core_before_stock;
create function private.yt_freeflow_core(p_actor uuid,p_guest boolean,p_action text,p_data jsonb) returns jsonb language plpgsql set search_path='' as $$
declare result jsonb;
begin
 result:=private.yt_freeflow_core_before_stock(p_actor,p_guest,p_action,p_data);
 if p_action='mine' then
  select coalesce(jsonb_agg(j.value||jsonb_build_object('products',private.yt_ff_stock_products(j.value->'products')) order by j.ord),'[]') into result from jsonb_array_elements(result) with ordinality j(value,ord);
 elsif p_action='work_menu' then result:=result||jsonb_build_object('products',private.yt_ff_stock_products(result->'products'));end if;
 return result;
end $$;
revoke all on function private.yt_freeflow_core(uuid,boolean,text,jsonb) from public,anon,authenticated;

-- The insert guard covers individual, visitor, proxy and staff/Owner ordering.
create function private.yt_ff_stock_guard() returns trigger language plpgsql set search_path='' as $$
begin
 perform pg_advisory_xact_lock_shared(hashtextextended('yt.ff.stock',0));
 if exists(select 1 from private.yt_ff_stock s where s.product_id=new.product_id and s.expires_at>clock_timestamp()) then raise exception 'freeflow_sold_out';end if;
 return new;
end $$;
revoke all on function private.yt_ff_stock_guard() from public,anon,authenticated;
create trigger yt_ff_stock_guard before insert on public.yt_freeflow_requests for each row execute function private.yt_ff_stock_guard();

create function private.yt_freeflow_supply(p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();pid uuid;until_at timestamptz;name text;sold boolean;reason text;result jsonb;changed integer;ids uuid[];
begin
 if actor is null or not coalesce(private.yt_pos_work_staff(),false) or not coalesce(private.yt_work_owner() or private.yt_pos_work_cashier(),false) then raise exception 'cashier_only';end if;
 if p_action='set' then
  pid:=(p_data->>'product_id')::uuid;sold:=(p_data->>'sold_out')::boolean;
  if sold is null then raise exception 'invalid_freeflow_stock';end if;
  select p.title into name from public.yt_shop_products p where p.id=pid and p.is_drink and exists(select 1 from public.yt_freeflow_menu_items i where i.product_id=p.id);
  if not found then raise exception 'product_unavailable';end if;
  perform pg_advisory_xact_lock(hashtextextended('yt.ff.stock',0));
  until_at:=case when sold then private.yt_ff_stock_until(clock_timestamp()) else clock_timestamp() end;
  if sold and (until_at is null or until_at<=clock_timestamp()) then raise exception 'freeflow_supply_ended';end if;
  insert into private.yt_ff_stock values(pid,until_at,clock_timestamp(),actor) on conflict(product_id) do update set expires_at=excluded.expires_at,changed_at=excluded.changed_at,changed_by=excluded.changed_by;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'freeflow.stock','freeflow_product',pid,jsonb_build_object('name',name,'sold_out',sold,'expires_at',until_at));
 elsif p_action='cancel_pending' then
  pid:=(p_data->>'product_id')::uuid;reason:=btrim(coalesce(p_data->>'reason',''));
  if length(reason) not between 2 and 300 or jsonb_typeof(p_data->'request_ids') is distinct from 'array' or jsonb_array_length(p_data->'request_ids')>500 then raise exception 'reason_required';end if;
  select array_agg(value::uuid) into ids from jsonb_array_elements_text(p_data->'request_ids');
  with cancelled as (update public.yt_freeflow_requests set status='cancelled',completed_by=actor,cancel_reason=reason where product_id=pid and id=any(ids) and status='pending' returning id)
  select count(*) into changed from cancelled;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'freeflow.stock_cancel','freeflow_product',pid,jsonb_build_object('request_ids',to_jsonb(ids),'cancelled',changed,'reason',reason));
  return jsonb_build_object('cancelled',changed);
 elsif p_action<>'list' then raise exception 'invalid_freeflow_stock';end if;
 select jsonb_build_object('reset_at',private.yt_ff_stock_until(clock_timestamp()),'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.title,'sold_out',coalesce(st.expires_at>clock_timestamp(),false),'expires_at',st.expires_at,
  'pending',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'table_label',s.table_label,'order_no',o.order_no) order by r.requested_at) from public.yt_freeflow_requests r join public.yt_freeflow_sessions s on s.id=r.session_id join public.yt_member_orders o on o.id=s.order_id where r.product_id=p.id and r.status='pending'),'[]')) order by p.sort_order,p.title)
  from public.yt_shop_products p left join private.yt_ff_stock st on st.product_id=p.id where p.active and p.is_drink and exists(select 1 from public.yt_freeflow_menu_items i join public.yt_freeflow_menus m on m.id=i.menu_id where i.product_id=p.id and m.active)),'[]'),
 'history',case when private.yt_work_owner() then coalesce((select jsonb_agg(to_jsonb(x)) from(select l.created_at,coalesce(w.username,'员工') actor,l.metadata from public.audit_logs l left join public.work_accounts w on w.auth_user_id=l.actor_id where l.action='freeflow.stock' order by l.created_at desc limit 40)x),'[]') else '[]'::jsonb end) into result;
 return result;
end $$;
create function public.yt_freeflow_supply(p_action text,p_data jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$select private.yt_freeflow_supply(p_action,p_data)$$;
revoke all on function private.yt_freeflow_supply(text,jsonb) from public,anon,authenticated;
revoke all on function public.yt_freeflow_supply(text,jsonb) from public,anon,authenticated;
grant execute on function private.yt_freeflow_supply(text,jsonb) to authenticated;
grant execute on function public.yt_freeflow_supply(text,jsonb) to authenticated;
