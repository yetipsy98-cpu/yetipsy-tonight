-- Allow Cashier and Owner to reuse, edit, and bind a custom drink to multiple members.
create table if not exists public.yt_pos_custom_drink_members (
  custom_drink_id uuid not null references public.yt_pos_custom_drinks(id) on delete cascade,
  customer_id uuid not null references auth.users(id) on delete cascade,
  first_order_id uuid,
  created_at timestamptz not null default clock_timestamp(),
  primary key (custom_drink_id, customer_id)
);
create index if not exists yt_pos_custom_drink_members_customer_idx
  on public.yt_pos_custom_drink_members(customer_id, custom_drink_id);
alter table public.yt_pos_custom_drink_members enable row level security;
revoke all on public.yt_pos_custom_drink_members from public, anon, authenticated, service_role;

-- Preserve every existing single-customer association as the first member.
insert into public.yt_pos_custom_drink_members(custom_drink_id, customer_id)
select d.id, d.customer_id
from public.yt_pos_custom_drinks d
where d.customer_id is not null
on conflict (custom_drink_id, customer_id) do nothing;

create or replace function private.yt_pos_custom_bind_member(p_order uuid, p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
 v_order public.yt_member_orders%rowtype;
 v_customer uuid;
 v_count integer;
begin
 if not (private.yt_pos_work_cashier() or private.yt_work_owner()) then raise exception 'cashier_only'; end if;
 if p_order is null or p_token is null then raise exception 'custom_member_binding_invalid'; end if;
 select * into v_order from public.yt_member_orders where id=p_order and source='future_pos' for update;
 if not found or v_order.status in ('cancelled','rejected') or v_order.payment_status<>'paid'
   or v_order.status='refunded' or coalesce(v_order.cancel_after_refund,false)
   or private.yt_pos_received(p_order)<v_order.amount_rm then
  raise exception 'custom_order_not_paid';
 end if;
 select t.customer_id into v_customer from public.yt_play_member_tokens t
 where t.token_hash=private.yt_play_hash(p_token) and t.expires_at>clock_timestamp();
 if v_customer is null then raise exception 'member_code_expired'; end if;
 if not exists(select 1 from public.pin_accounts where auth_user_id=v_customer)
   or exists(select 1 from public.work_accounts where auth_user_id=v_customer) then
  raise exception 'customer_only';
 end if;
 if not exists(
   select 1 from public.yt_member_order_items i
   join public.yt_pos_custom_drinks d on d.product_id=i.product_id
   where i.order_id=p_order and i.quantity>0
 ) then raise exception 'custom_order_no_custom_items'; end if;

 insert into public.yt_pos_custom_drink_members(custom_drink_id,customer_id,first_order_id)
 select distinct d.id,v_customer,p_order
 from public.yt_member_order_items i
 join public.yt_pos_custom_drinks d on d.product_id=i.product_id
 where i.order_id=p_order and i.quantity>0
 on conflict (custom_drink_id,customer_id) do nothing;
 get diagnostics v_count = row_count;

 -- Keep the legacy column as the first linked member for older readers.
 update public.yt_pos_custom_drinks d set customer_id=v_customer
 from public.yt_member_order_items i
 where i.order_id=p_order and i.quantity>0 and i.product_id=d.product_id and d.customer_id is null;

 return jsonb_build_object('bound',true,'already_bound',v_count=0,'custom_drinks',v_count);
end;
$function$;

create or replace function private.yt_pos_custom_attach_customer(p_order uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare cid uuid; paid boolean;
begin
 select exists(select 1 from public.yt_member_orders o where o.id=p_order and o.payment_status='paid'
  and o.status not in ('cancelled','refunded')) into paid;
 if not paid then return; end if;
 select customer_id into cid from public.yt_play_consumption_bindings where order_id=p_order limit 1;
 if cid is null then return; end if;
 insert into public.yt_pos_custom_drink_members(custom_drink_id,customer_id,first_order_id)
 select distinct d.id,cid,p_order
 from public.yt_member_order_items i
 join public.yt_pos_custom_drinks d on d.product_id=i.product_id
 where i.order_id=p_order and i.quantity>0
 on conflict (custom_drink_id,customer_id) do nothing;
 update public.yt_pos_custom_drinks d set customer_id=cid,updated_at=clock_timestamp()
 from public.yt_member_order_items i where i.order_id=p_order and i.product_id=d.product_id
 and d.customer_id is null;
end;
$function$;

create or replace function private.yt_pos_custom_my_list()
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
 select coalesce(jsonb_agg(jsonb_build_object('name',d.public_name,'created_at',d.created_at,
  'share_token',d.share_token,'last_updated_at',d.updated_at) order by d.created_at desc),'[]'::jsonb)
 from public.yt_pos_custom_drinks d
 where d.customer_id=auth.uid()
   or exists(select 1 from public.yt_pos_custom_drink_members m where m.custom_drink_id=d.id and m.customer_id=auth.uid());
$function$;

-- Cashier can edit saved custom drink recipes; database still enforces the cost floor.
create or replace function private.yt_pos_custom_update(p_id uuid,p_name text,p_recipe jsonb,p_quote numeric)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
 d public.yt_pos_custom_drinks%rowtype;
 calc jsonb;
 items jsonb;
 material_id uuid;
 quote_value numeric;
 next_version integer;
begin
 if not (private.yt_work_owner() or private.yt_pos_work_cashier()) then raise exception 'cashier_only'; end if;
 if p_id is null then raise exception 'custom_code_not_found'; end if;
 if length(btrim(coalesce(p_name,''))) not between 2 and 100 then raise exception 'custom_name_invalid'; end if;
 select * into d from public.yt_pos_custom_drinks where id=p_id for update;
 if not found then raise exception 'custom_code_not_found'; end if;
 items:=case when jsonb_typeof(p_recipe)='object' then p_recipe->'items' else p_recipe end;
 if jsonb_typeof(items)<>'array' then raise exception 'custom_recipe_invalid'; end if;
 for material_id in select (value->>'material_id')::uuid from jsonb_array_elements(items)
 loop
  if not exists(select 1 from public.yt_pos_custom_materials where id=material_id and active) then
   raise exception 'custom_material_unavailable';
  end if;
 end loop;
 calc:=private.yt_pos_custom_calculate(p_recipe);
 quote_value:=round(p_quote,2);
 if quote_value is null or quote_value<(calc->>'cost_rm')::numeric or quote_value>5000 then
  raise exception 'custom_quote_below_cost';
 end if;
 if not exists(select 1 from public.yt_shop_products where id=d.product_id and category='CUSTOM') then
  raise exception 'custom_product_missing';
 end if;
 if not exists(select 1 from public.yt_pos_custom_drink_versions where custom_drink_id=d.id and version=d.current_version) then
  insert into public.yt_pos_custom_drink_versions(
   custom_drink_id,version,recipe_snapshot,note,total_cost_rm,suggested_min_rm,
   suggested_max_rm,quote_rm,changed_by,change_kind
  ) values(d.id,d.current_version,d.recipe_snapshot,d.note,d.total_cost_rm,
   d.suggested_min_rm,d.suggested_max_rm,d.quote_rm,d.created_by,'created');
 end if;
 select greatest(d.current_version,coalesce(max(version),0))+1 into next_version
 from public.yt_pos_custom_drink_versions where custom_drink_id=d.id;
 update public.yt_shop_products set title=btrim(p_name),price_rm=quote_value,updated_at=clock_timestamp()
 where id=d.product_id and category='CUSTOM';
 update public.yt_pos_custom_drinks
 set public_name=btrim(p_name),recipe_snapshot=calc->'recipe',note=calc->>'note',
     total_cost_rm=(calc->>'cost_rm')::numeric,
     suggested_min_rm=(calc->>'suggested_min_rm')::numeric,
     suggested_max_rm=(calc->>'suggested_max_rm')::numeric,
     quote_rm=quote_value,current_version=next_version,updated_at=clock_timestamp()
 where id=d.id returning * into d;
 insert into public.yt_pos_custom_drink_versions(
  custom_drink_id,version,recipe_snapshot,note,total_cost_rm,suggested_min_rm,
  suggested_max_rm,quote_rm,changed_by,change_kind
 ) values(d.id,next_version,d.recipe_snapshot,d.note,d.total_cost_rm,
  d.suggested_min_rm,d.suggested_max_rm,d.quote_rm,auth.uid(),'edited');
 return jsonb_build_object('ok',true,'id',d.id,'version',d.current_version,
  'product',jsonb_build_object('id',d.product_id,'custom_id',d.id,
   'share_token',d.share_token,'name',d.public_name,'price_rm',d.quote_rm,
   'active',true,'category','CUSTOM','is_drink',true));
end;
$function$;

-- Cashier history excludes customer identities, recipes' costs, and material cost details.
create or replace function private.yt_pos_custom_cashier_history()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
 if not (private.yt_work_owner() or private.yt_pos_work_cashier()) then raise exception 'cashier_only'; end if;
 return coalesce((
  select jsonb_agg(jsonb_build_object(
   'id',d.id,'name',d.public_name,'note',d.note,'share_token',d.share_token,
   'created_by',d.created_by,
   'created_by_name',(select wa.username from public.work_accounts wa where wa.auth_user_id=d.created_by),
   'created_at',d.created_at,'current_version',d.current_version,
   'customer_count',(select count(*) from public.yt_pos_custom_drink_members m where m.custom_drink_id=d.id),
   'current_recipe',(select coalesce(jsonb_agg(jsonb_build_object(
      'material_id',x->'material_id','name',x->'name','quantity',x->'quantity',
      'note',x->'note','charge_full_bottle',x->'charge_full_bottle'
    )),'[]'::jsonb) from jsonb_array_elements(coalesce(d.recipe_snapshot,'[]'::jsonb)) x),
   'current_note',d.note,'current_quote_rm',d.quote_rm,
   'versions',(select jsonb_agg(jsonb_build_object(
    'version',v.version,'name',v.public_name,
    'recipe',(select coalesce(jsonb_agg(jsonb_build_object(
      'material_id',x->'material_id','name',x->'name','quantity',x->'quantity',
      'note',x->'note','charge_full_bottle',x->'charge_full_bottle'
    )),'[]'::jsonb) from jsonb_array_elements(coalesce(v.recipe_snapshot,'[]'::jsonb)) x),
    'note',v.note,'quote_rm',v.quote_rm,'changed_by',v.changed_by,
    'changed_by_name',(select wa.username from public.work_accounts wa where wa.auth_user_id=v.changed_by),
    'changed_at',v.changed_at,'change_kind',v.change_kind
   ) order by v.version desc) from public.yt_pos_custom_drink_versions v where v.custom_drink_id=d.id)
  ) order by d.created_at desc)
  from public.yt_pos_custom_drinks d
 ),'[]'::jsonb);
end;
$function$;

create or replace function public.yt_pos_custom_cashier_history()
returns jsonb
language sql
set search_path to ''
as $function$ select private.yt_pos_custom_cashier_history(); $function$;

revoke all on function public.yt_pos_custom_cashier_history() from public, anon;
grant execute on function public.yt_pos_custom_cashier_history() to authenticated;
grant execute on function private.yt_pos_custom_cashier_history() to authenticated;
