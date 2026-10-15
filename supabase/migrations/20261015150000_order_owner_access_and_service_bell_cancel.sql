-- Keep Owner order approval access independent from the Cashier-only request history,
-- and let customers cancel their own unacknowledged service request.
alter table public.yt_play_bell_requests
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references auth.users(id) on delete set null;

create or replace function private.yt_pos_owner_revision_requests_mine()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if private.yt_work_owner() then return '[]'::jsonb; end if;
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',q.id,'order_id',q.order_id,'order_no',o.order_no,'table_label',o.table_label,
  'status',q.status,'created_at',q.created_at,'reviewed_at',q.reviewed_at,
  'review_note',q.review_note,'reviewer_name',coalesce(r.username,'Owner')
 ) order by q.created_at desc),'[]'::jsonb)
 into rows from (
  select * from public.yt_pos_owner_revision_requests
  where requester_id=auth.uid()
  order by created_at desc limit 100
 ) q
 join public.yt_member_orders o on o.id=q.order_id
 left join public.work_accounts r on r.auth_user_id=q.reviewer_id;
 return rows;
end $$;

create or replace function private.yt_play_bell_cancel(p_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.yt_play_bell_requests%rowtype;
begin
 if not private.yt_play_customer() then raise exception 'customer_only'; end if;
 update public.yt_play_bell_requests
 set cancelled_at=clock_timestamp(),cancelled_by=auth.uid()
 where id=p_id and customer_id=auth.uid()
   and acknowledged_at is null and cancelled_at is null
 returning * into v;
 if not found then raise exception 'bell_request_not_cancellable'; end if;
 return jsonb_build_object('id',v.id,'status','cancelled','cancelled_at',v.cancelled_at);
end $$;

create or replace function public.yt_play_bell_cancel(p_id uuid)
returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_play_bell_cancel(p_id)
$$;

create or replace function private.yt_play_bell_call(p_table text,p_type text,p_note text,p_lat double precision,p_lng double precision)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.yt_play_upgrade_settings%rowtype;v_id uuid;v_distance double precision;
begin
 if not private.yt_play_customer() then raise exception 'customer_only';end if;
 select * into s from public.yt_play_upgrade_settings where id=true;
 if not s.bell_enabled or s.bell_lat is null or s.bell_lng is null then raise exception 'bell_disabled';end if;
 if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'location_required';end if;
 v_distance:=6371000*2*asin(sqrt(power(sin(radians(p_lat-s.bell_lat)/2),2)+cos(radians(s.bell_lat))*cos(radians(p_lat))*power(sin(radians(p_lng-s.bell_lng)/2),2)));
 if v_distance>s.bell_radius_m then raise exception 'outside_service_area';end if;
 if char_length(btrim(coalesce(p_table,''))) not between 1 and 32
  or not exists(select 1 from public.yt_play_bell_types where id=p_type and enabled)
  or char_length(coalesce(p_note,''))>50 then raise exception 'invalid_bell_request';end if;
 if exists(select 1 from public.yt_play_bell_requests where customer_id=auth.uid() and cancelled_at is null
  and (acknowledged_at is null or acknowledged_at+make_interval(secs=>s.bell_complete_seconds)>clock_timestamp()))
 then raise exception 'bell_already_active';end if;
 insert into public.yt_play_bell_requests(customer_id,table_label,type_id,note)
 values(auth.uid(),btrim(p_table),p_type,coalesce(p_note,'')) returning id into v_id;
 return jsonb_build_object('id',v_id,'status','pending');
end $$;

create or replace function private.yt_play_bell_list()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare s public.yt_play_upgrade_settings%rowtype;v jsonb;
begin
 select * into s from public.yt_play_upgrade_settings where id=true;
 if private.yt_pos_work_cashier() or private.yt_work_owner() then
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'table',r.table_label,'type',r.type_id,
   'label_zh',t.label_zh,'label_en',t.label_en,'note',r.note,'created_at',r.created_at,
   'acknowledged_at',r.acknowledged_at,'cancelled_at',r.cancelled_at,
   'status',case when r.cancelled_at is not null then 'cancelled' when r.acknowledged_at is null then 'pending'
    when r.acknowledged_at+make_interval(secs=>s.bell_complete_seconds)>clock_timestamp() then 'acknowledged' else 'completed' end)
   order by r.created_at desc),'[]'::jsonb) into v from public.yt_play_bell_requests r
   join public.yt_play_bell_types t on t.id=r.type_id
   where r.created_at>clock_timestamp()-interval '24 hours';
 elsif private.yt_play_customer() then
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'table',r.table_label,'type',r.type_id,
   'created_at',r.created_at,'acknowledged_at',r.acknowledged_at,'cancelled_at',r.cancelled_at,
   'status',case when r.cancelled_at is not null then 'cancelled' when r.acknowledged_at is null then 'pending'
    when r.acknowledged_at+make_interval(secs=>s.bell_complete_seconds)>clock_timestamp() then 'acknowledged' else 'completed' end)
   order by r.created_at desc),'[]'::jsonb) into v from public.yt_play_bell_requests r
   where r.customer_id=auth.uid() and r.created_at>clock_timestamp()-interval '24 hours';
 else raise exception 'not_authenticated';end if;
 return v;
end $$;

create or replace function private.yt_play_bell_history()
returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('table',q.table_label,'type',t.label_zh,
  'created_at',q.created_at,'acknowledged_at',q.acknowledged_at,'acknowledged_by',q.acknowledged_by,
  'cancelled_at',q.cancelled_at,'status',case when q.cancelled_at is not null then 'cancelled' when q.acknowledged_at is null then 'pending' else 'acknowledged' end)
  order by q.created_at desc),'[]'::jsonb)
 from (select * from public.yt_play_bell_requests order by created_at desc limit 200) q
 join public.yt_play_bell_types t on t.id=q.type_id where private.yt_work_owner()
$$;

create or replace function public.yt_pos_owner_revision_requests_mine()
returns jsonb language sql security invoker set search_path='' as $$select private.yt_pos_owner_revision_requests_mine()$$;
create or replace function public.yt_play_bell_list()
returns jsonb language sql security invoker set search_path='' as $$select private.yt_play_bell_list()$$;
create or replace function public.yt_play_bell_history()
returns jsonb language sql security invoker set search_path='' as $$select private.yt_play_bell_history()$$;
create or replace function public.yt_play_bell_call(p_table text,p_type text,p_note text,p_lat double precision,p_lng double precision)
returns jsonb language sql security invoker set search_path='' as $$select private.yt_play_bell_call($1,$2,$3,$4,$5)$$;

revoke all on function private.yt_play_bell_cancel(uuid),public.yt_play_bell_cancel(uuid),
 private.yt_pos_owner_revision_requests_mine(),public.yt_pos_owner_revision_requests_mine(),
 private.yt_play_bell_call(text,text,text,double precision,double precision),public.yt_play_bell_call(text,text,text,double precision,double precision),
 private.yt_play_bell_list(),public.yt_play_bell_list(),private.yt_play_bell_history(),public.yt_play_bell_history()
 from public,anon;
grant execute on function private.yt_play_bell_cancel(uuid),private.yt_pos_owner_revision_requests_mine(),
 private.yt_play_bell_call(text,text,text,double precision,double precision),private.yt_play_bell_list(),private.yt_play_bell_history()
 to authenticated;
grant execute on function public.yt_play_bell_cancel(uuid),public.yt_pos_owner_revision_requests_mine(),
 public.yt_play_bell_call(text,text,text,double precision,double precision),public.yt_play_bell_list(),public.yt_play_bell_history()
 to authenticated;
