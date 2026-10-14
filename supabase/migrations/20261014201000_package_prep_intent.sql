create table if not exists private.yt_store_box_prep_intents(
 order_id uuid primary key references public.yt_member_orders(id) on delete cascade,
 actor_id uuid not null references auth.users(id),
 preps jsonb not null check(jsonb_typeof(preps)='array'),
 created_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp()
);
revoke all on table private.yt_store_box_prep_intents from public,anon,authenticated;

create or replace function private.yt_store_box_prep_intent_save(p_order uuid,p_preps jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 actor uuid:=auth.uid(); o public.yt_member_orders%rowtype; quote jsonb; item jsonb; line jsonb;
 selected jsonb; entry jsonb; candidate jsonb; normalized jsonb:='[]'::jsonb;
 quantity integer; available integer; total integer;
begin
 if actor is null or not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if p_order is null or p_preps is null or jsonb_typeof(p_preps)<>'array' or jsonb_array_length(p_preps)>50 then raise exception 'invalid_store_box_selection';end if;
 perform pg_advisory_xact_lock(781943084);
 select * into o from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found then raise exception 'order_not_found';end if;
 if o.payment_status<>'unpaid' or o.status not in('pending','confirmed','fulfilled') then raise exception 'order_not_ready_for_checkout';end if;
 quote:=private.yt_store_box_checkout_prep_quote(p_order);
 if exists(select 1 from jsonb_array_elements(p_preps) z where not exists(select 1 from jsonb_array_elements(quote->'items') x where x->>'item_id'=z->>'item_id')) then raise exception 'store_box_item_not_in_order';end if;
 if exists(select 1 from jsonb_array_elements(p_preps) z group by z->>'item_id' having count(*)>1) then raise exception 'duplicate_store_box_item';end if;
 for item in select value from jsonb_array_elements(quote->'items') loop
  select value into line from jsonb_array_elements(p_preps) where value->>'item_id'=item->>'item_id';
  if line is null then
   selected:=case when item->>'mode'='challenge' then jsonb_build_array(jsonb_build_object('key',item->'available'->0->>'key','quantity',1)) else '[]'::jsonb end;
  else selected:=coalesce(line->'selections','[]'::jsonb);end if;
  if jsonb_typeof(selected)<>'array' or jsonb_array_length(selected)>20 then raise exception 'invalid_store_box_selection';end if;
  total:=0;
  for entry in select value from jsonb_array_elements(selected) loop
   if coalesce(entry->>'key','')='' or coalesce(entry->>'quantity','')!~'^[0-9]{1,2}$' then raise exception 'invalid_store_box_selection';end if;
   quantity:=(entry->>'quantity')::integer;
   if quantity<1 then raise exception 'invalid_store_box_selection';end if;
   if exists(select 1 from jsonb_array_elements(selected) x where x->>'key'=entry->>'key' group by x->>'key' having count(*)>1) then raise exception 'duplicate_store_box_component';end if;
   select value into candidate from jsonb_array_elements(item->'available') where value->>'key'=entry->>'key';
   if candidate is null then raise exception 'store_box_component_unavailable';end if;
   available:=coalesce((candidate->>'quantity')::integer,0);
   if quantity>available then raise exception 'store_box_component_unavailable';end if;
   total:=total+quantity;
  end loop;
  if total>99 or total>(item->>'capacity')::integer then raise exception 'store_box_quantity_unavailable';end if;
  if item->>'mode'='challenge' and total<>1 then raise exception 'challenge_one_cup_only';end if;
  normalized:=normalized||jsonb_build_array(jsonb_build_object('item_id',item->>'item_id','selections',selected));
 end loop;
 insert into private.yt_store_box_prep_intents(order_id,actor_id,preps)
 values(p_order,actor,normalized)
 on conflict(order_id) do update set actor_id=excluded.actor_id,preps=excluded.preps,updated_at=clock_timestamp();
 return jsonb_build_object('order_id',p_order,'preps',normalized);
end $$;

create or replace function private.yt_store_box_prep_intent_get(p_order uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not private.yt_pos_work_cashier() then raise exception 'cashier_only';end if;
 if p_order is null or not exists(select 1 from public.yt_member_orders where id=p_order and source='future_pos') then raise exception 'order_not_found';end if;
 select preps into result from private.yt_store_box_prep_intents where order_id=p_order;
 return jsonb_build_object('order_id',p_order,'preps',result);
end $$;

create or replace function public.yt_store_box_prep_intent_save(p_order uuid,p_preps jsonb)
returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_prep_intent_save(p_order,p_preps)$$;
create or replace function public.yt_store_box_prep_intent_get(p_order uuid)
returns jsonb language sql security invoker set search_path='' as $$select private.yt_store_box_prep_intent_get(p_order)$$;
revoke all on function private.yt_store_box_prep_intent_save(uuid,jsonb),private.yt_store_box_prep_intent_get(uuid),public.yt_store_box_prep_intent_save(uuid,jsonb),public.yt_store_box_prep_intent_get(uuid) from public,anon;
grant execute on function private.yt_store_box_prep_intent_save(uuid,jsonb),private.yt_store_box_prep_intent_get(uuid),public.yt_store_box_prep_intent_save(uuid,jsonb),public.yt_store_box_prep_intent_get(uuid) to authenticated;