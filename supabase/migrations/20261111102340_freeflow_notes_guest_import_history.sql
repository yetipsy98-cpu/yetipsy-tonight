-- Notes follow the cup; guest history can be claimed only by the authenticated member.
alter table public.yt_freeflow_requests add column note text not null default '' check(char_length(note)<=160);
alter table public.yt_freeflow_guests add column expires_at timestamptz not null default (clock_timestamp()+interval '10 days');
update public.yt_freeflow_guests set expires_at=created_at+interval '10 days';
alter table public.yt_freeflow_guests add column imported_customer_id uuid references auth.users(id);
alter table public.yt_freeflow_guests add column imported_at timestamptz;
create index yt_freeflow_members_guest_import on public.yt_freeflow_members(guest_id,session_id) where guest_id is not null;
create index yt_freeflow_requests_guest_import on public.yt_freeflow_requests(guest_id) where guest_id is not null;
create index yt_freeflow_guests_imported_customer on public.yt_freeflow_guests(imported_customer_id) where imported_customer_id is not null;

-- Preserve the complete dispatcher, including the independently configured GPS gate.
do $$declare d text;begin
 select pg_get_functiondef('private.yt_freeflow_core(uuid,boolean,text,jsonb)'::regprocedure) into d;
 if strpos(d,'insert into public.yt_freeflow_requests(member_id,customer_id,guest_id,product_id,item_name,table_label,request_id)')=0 then raise exception 'freeflow_note_patch_missing';end if;
 d:=replace(d,'where id=actor) then raise exception ''guest_token_invalid''','where id=actor and imported_customer_id is null and expires_at>clock_timestamp()) then raise exception ''guest_token_invalid''');
 d:=replace(d,'elsif p_action=''order'' then','elsif p_action=''order'' then'||E'\n  if char_length(coalesce(p_data->>''note'',''''))>160 then raise exception ''invalid_freeflow_note'';end if;');
 d:=replace(d,'v_request.product_id<>(p_data->>''product_id'')::uuid then','v_request.product_id<>(p_data->>''product_id'')::uuid or v_request.note<>btrim(coalesce(p_data->>''note'','''')) then');
 d:=replace(d,'insert into public.yt_freeflow_requests(member_id,customer_id,guest_id,product_id,item_name,table_label,request_id)','insert into public.yt_freeflow_requests(member_id,customer_id,guest_id,product_id,item_name,table_label,request_id,note)');
 d:=replace(d,'v_session.table_label,(p_data->>''request_id'')::uuid) returning id into v_id;','v_session.table_label,(p_data->>''request_id'')::uuid,btrim(coalesce(p_data->>''note'',''''))) returning id into v_id;');
 d:=replace(d,'''name'',r.item_name,','''name'',r.item_name,''note'',r.note,');
 d:=replace(d,'select item_name name,count(*) quantity from public.yt_freeflow_requests where member_id=m.id and status=''served'' group by item_name order by item_name','select item_name name,note,count(*) quantity from public.yt_freeflow_requests where member_id=m.id and status=''served'' group by item_name,note order by item_name,note');
 execute d;
end$$;

create or replace function freeflow_api.guest(p_action text,p_credential uuid,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare g public.yt_freeflow_guests%rowtype;s public.yt_freeflow_sessions%rowtype;v_hash text;code_hash text;
begin
 if p_credential is null then raise exception 'guest_token_invalid';end if;
 if p_action is null or p_action not in('bind','mine','order','restore') then raise exception 'invalid_freeflow_action';end if;
 v_hash:=private.yt_play_hash(p_credential);
 perform pg_advisory_xact_lock(hashtextextended('freeflow-guest-token:'||v_hash,0));
 if p_action='restore' then
  code_hash:=private.yt_play_hash((p_data->>'token')::uuid);
  select * into g from public.yt_freeflow_guests where token_hash=v_hash for update;
  if found then
   if g.last_recovery_hash=code_hash and g.imported_customer_id is null and g.expires_at>clock_timestamp() then return private.yt_freeflow_core(g.id,true,'mine','{}');end if;
   raise exception 'guest_restore_invalid';
  end if;
  select * into g from public.yt_freeflow_guests where recovery_hash=code_hash and recovery_expires_at>clock_timestamp() and imported_customer_id is null for update;
  if not found then raise exception 'guest_restore_invalid';end if;
  update public.yt_freeflow_guests set token_hash=v_hash,last_recovery_hash=code_hash,recovery_hash=null,recovery_expires_at=null,expires_at=clock_timestamp()+interval '10 days' where id=g.id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(null,'freeflow.guest_restored','freeflow_guest',g.id,'{}');
  return private.yt_freeflow_core(g.id,true,'mine','{}');
 end if;
 if p_action='bind' then
  select * into s from public.yt_freeflow_sessions where bind_token=(p_data->>'token')::uuid and token_expires_at>clock_timestamp();
  if not found then raise exception 'freeflow_token_expired';end if;
  select * into g from public.yt_freeflow_guests where token_hash=v_hash for update;
  if not found then insert into public.yt_freeflow_guests(token_hash) values(v_hash) returning * into g;end if;
  if g.imported_customer_id is not null or g.expires_at<=clock_timestamp() then raise exception 'guest_token_invalid';end if;
  return private.yt_freeflow_core(g.id,true,'bind',p_data);
 end if;
 select * into g from public.yt_freeflow_guests where token_hash=v_hash for share;
 if not found or g.imported_customer_id is not null or g.expires_at<=clock_timestamp() then raise exception 'guest_token_invalid';end if;
 return private.yt_freeflow_core(g.id,true,p_action,p_data);
end$$;

create function freeflow_api.import_guest(p_credential uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();g public.yt_freeflow_guests%rowtype;m public.yt_freeflow_members%rowtype;e public.yt_freeflow_members%rowtype;k uuid;n integer;cups integer;v_hash text;
begin
 if actor is null or not private.yt_play_customer() then raise exception 'customer_only';end if;
 if p_credential is null then raise exception 'guest_token_invalid';end if;
 v_hash:=private.yt_play_hash(p_credential);
 perform pg_advisory_xact_lock(hashtextextended('freeflow-guest-token:'||v_hash,0));
 select * into g from public.yt_freeflow_guests where token_hash=v_hash for update;
 if not found then raise exception 'guest_token_invalid';end if;
 if g.imported_customer_id=actor then return jsonb_build_object('imported',true,'idempotent',true);end if;
 if g.imported_customer_id is not null or g.expires_at<=clock_timestamp() then raise exception 'guest_token_invalid';end if;
 for k in select x from unnest(array[actor,g.id]) x order by x loop
  perform pg_advisory_xact_lock(hashtextextended('freeflow-member:'||k::text,0));
 end loop;
 for k in select distinct session_id from public.yt_freeflow_members where guest_id=g.id order by session_id loop
  perform 1 from public.yt_freeflow_sessions where id=k for update;
 end loop;
 if exists(select 1 from public.yt_freeflow_requests where guest_id=g.id and status='pending')
  and exists(select 1 from public.yt_freeflow_requests where customer_id=actor and status='pending') then raise exception 'freeflow_import_pending_conflict';end if;
 if exists(select 1 from public.yt_freeflow_members gm join public.yt_freeflow_sessions gs on gs.id=gm.session_id join public.yt_member_orders go on go.id=gs.order_id
  join public.yt_freeflow_members cm on cm.customer_id=actor join public.yt_freeflow_sessions cs on cs.id=cm.session_id join public.yt_member_orders co on co.id=cs.order_id
  where gm.guest_id=g.id and gm.status<>'closed' and gs.status<>'closed' and gs.ends_at>clock_timestamp()
   and cm.status<>'closed' and cs.status<>'closed' and cs.ends_at>clock_timestamp() and gs.id<>cs.id
   and go.status not in('pending','cancelled') and go.payment_status<>'refunded' and not go.cancel_after_refund
   and co.status not in('pending','cancelled') and co.payment_status<>'refunded' and not co.cancel_after_refund)
 then raise exception 'freeflow_import_active_conflict';end if;
 select count(*) into n from public.yt_freeflow_members where guest_id=g.id;
 select count(*) into cups from public.yt_freeflow_requests where guest_id=g.id and status='served';
 for m in select * from public.yt_freeflow_members where guest_id=g.id order by session_id for update loop
  select * into e from public.yt_freeflow_members where session_id=m.session_id and customer_id=actor for update;
  if found then
   update public.yt_freeflow_requests set member_id=e.id,customer_id=actor,guest_id=null where member_id=m.id;
   update public.yt_freeflow_members set status=case when e.status='closed' or m.status='closed' then 'closed' when e.status='paused' or m.status='paused' then 'paused' else 'active' end where id=e.id;
   delete from public.yt_freeflow_members where id=m.id;
  else
   update public.yt_freeflow_members set customer_id=actor,guest_id=null where id=m.id;
   update public.yt_freeflow_requests set customer_id=actor,guest_id=null where member_id=m.id;
  end if;
 end loop;
 update public.yt_freeflow_guests set imported_customer_id=actor,imported_at=clock_timestamp(),recovery_hash=null,recovery_expires_at=null,last_recovery_hash=null where id=g.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(actor,'freeflow.guest_imported','freeflow_guest',g.id,jsonb_build_object('sessions',n,'cups',cups));
 return jsonb_build_object('imported',true,'sessions',n,'cups',cups);
end$$;
create function public.yt_freeflow_import_guest(p_credential uuid) returns jsonb
language sql security invoker set search_path='' as $$select freeflow_api.import_guest(p_credential)$$;
revoke all on function freeflow_api.import_guest(uuid),public.yt_freeflow_import_guest(uuid) from public,anon,authenticated;
grant execute on function freeflow_api.import_guest(uuid),public.yt_freeflow_import_guest(uuid) to authenticated;
