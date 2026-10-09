create or replace function private.yt_owner_points_settings() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 return jsonb_build_object('actor_id',auth.uid(),'validity_days',(select points_validity_days from public.yt_loyalty_config where id=true),'games',(select jsonb_agg(jsonb_build_object('id',id,'slug',slug,'title',title,'mode',mode,'points_max',points_max,'perfect_ms',reaction_perfect_ms,'zero_ms',reaction_zero_ms) order by slug) from public.games where mode='skill'),'rewards',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'points',r.points_equivalent,'bound',exists(select 1 from public.yt_pos_reward_rules where reward_id=r.id and mode in('product','series','any_drink'))) order by r.name) from public.rewards r where r.active),'[]'),'items',coalesce((select jsonb_agg(to_jsonb(i)||jsonb_build_object('name',r.name) order by i.sort_order,i.id) from public.yt_point_shop_items i join public.rewards r on r.id=i.reward_id),'[]'));
end $$;
create or replace function private.yt_owner_points_save(p_kind text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare target uuid;n integer;perfect integer;zero_ms integer;lim integer;old public.yt_point_shop_items%rowtype;prior jsonb;prior_id uuid;begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if jsonb_typeof(p_data) is distinct from 'object' then raise exception 'invalid_points_settings';end if;
 perform pg_advisory_xact_lock(781943081);
 target:=nullif(p_data->>'id','')::uuid;
 if p_kind='shop' then
  if p_data->>'request' is null then raise exception 'invalid_exchange';end if;
  perform (p_data->>'request')::uuid;
  select entity_id,metadata->'data' into prior_id,prior from public.audit_logs where actor_id=auth.uid() and action='points.owner_settings' and metadata->>'kind'='shop' and metadata#>>'{data,request}'=p_data->>'request';
  if found then if prior<>p_data then raise exception 'request_conflict';end if;return jsonb_build_object('ok',true,'id',prior_id,'idempotent',true);end if;
 end if;
 if p_kind='game' then
  n:=(p_data->>'points_max')::integer;perfect:=(p_data->>'perfect_ms')::integer;zero_ms:=(p_data->>'zero_ms')::integer;
  if n is null or n not between 1 and 1000000 or perfect is null or perfect not between 1 and 8999 or zero_ms is null or zero_ms not between perfect+1 and 9000 then raise exception 'invalid_points_settings';end if;
  update public.games set points_max=n,reaction_perfect_ms=perfect,reaction_zero_ms=zero_ms where id=target and mode='skill';if not found then raise exception 'game_not_supported';end if;
 elsif p_kind='reward' then
  n:=nullif(p_data->>'points','')::integer;if n is not null and n not between 1 and 1000000 then raise exception 'invalid_points_settings';end if;
  update public.rewards set points_equivalent=n where id=target;if not found then raise exception 'reward_missing';end if;
 elsif p_kind='expiry' then
  n:=(p_data->>'days')::integer;if n is null or n not between 0 and 3650 then raise exception 'invalid_points_settings';end if;
  update public.yt_loyalty_config set points_validity_days=n,updated_by=auth.uid(),updated_at=clock_timestamp() where id=true;
 elsif p_kind='shop' then
  n:=(p_data->>'cost')::integer;lim:=nullif(p_data->>'stock','')::integer;
  if n is null or n not between 1 and 1000000 or p_data->>'reward' is null or p_data->>'active' is null then raise exception 'invalid_points_settings';end if;
  if not exists(select 1 from public.rewards r join public.yt_pos_reward_rules q on q.reward_id=r.id where r.id=(p_data->>'reward')::uuid and r.active and q.mode in('product','series','any_drink')) then raise exception 'reward_not_pos_bound';end if;
  if target is not null then select * into old from public.yt_point_shop_items where id=target for update;if not found then raise exception 'shop_item_unavailable';end if;if lim is not null and lim<old.stock_used then raise exception 'stock_below_used';end if;end if;
  insert into public.yt_point_shop_items(id,reward_id,points_cost,active,stock_limit,per_member_limit,sort_order,starts_at,ends_at,updated_by) values(coalesce(target,gen_random_uuid()),(p_data->>'reward')::uuid,n,(p_data->>'active')::boolean,lim,nullif(p_data->>'member_limit','')::integer,coalesce((p_data->>'sort')::integer,100),nullif(p_data->>'starts_at','')::timestamptz,nullif(p_data->>'ends_at','')::timestamptz,auth.uid()) on conflict(id) do update set reward_id=excluded.reward_id,points_cost=excluded.points_cost,active=excluded.active,stock_limit=excluded.stock_limit,per_member_limit=excluded.per_member_limit,sort_order=excluded.sort_order,starts_at=excluded.starts_at,ends_at=excluded.ends_at,updated_by=auth.uid(),updated_at=clock_timestamp() returning id into target;
 else raise exception 'invalid_points_settings';end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'points.owner_settings','points_settings',target,jsonb_build_object('kind',p_kind,'data',p_data));
 return jsonb_build_object('ok',true,'id',target);
end $$;
create or replace function public.yt_owner_points_settings() returns jsonb language sql security invoker set search_path='' as $$select private.yt_owner_points_settings()$$;
create or replace function public.yt_owner_points_save(p_kind text,p_data jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.yt_owner_points_save(p_kind,p_data)$$;
revoke all on function private.yt_owner_points_settings(),public.yt_owner_points_settings(),private.yt_owner_points_save(text,jsonb),public.yt_owner_points_save(text,jsonb) from public,anon;
grant execute on function private.yt_owner_points_settings(),public.yt_owner_points_settings(),private.yt_owner_points_save(text,jsonb),public.yt_owner_points_save(text,jsonb) to authenticated;
