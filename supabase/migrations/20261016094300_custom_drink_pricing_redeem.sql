-- Custom drink pricing, immutable quote versions, and paid/member-bound ownership.
create table if not exists public.yt_pos_custom_materials (
 id uuid primary key default gen_random_uuid(),
 name text not null check (length(btrim(name)) between 1 and 80),
 unit_cost_rm numeric(12,4) not null check (unit_cost_rm >= 0),
 margin_percent numeric(5,2) not null check (margin_percent >= 0 and margin_percent < 100),
 min_discount_percent numeric(5,2) not null default 0 check (min_discount_percent between 0 and 100),
 max_discount_percent numeric(5,2) not null default 0 check (max_discount_percent between 0 and 100),
 active boolean not null default true,
 price_revision integer not null default 1,
 created_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp(),
 check (min_discount_percent <= max_discount_percent)
);
create table if not exists public.yt_pos_custom_drinks (
 id uuid primary key default gen_random_uuid(),
 share_token uuid not null unique default gen_random_uuid(),
 product_id uuid not null unique references public.yt_shop_products(id),
 public_name text not null check (length(btrim(public_name)) between 2 and 100),
 recipe_snapshot jsonb not null,
 total_cost_rm numeric(12,2) not null,
 suggested_min_rm numeric(12,2) not null,
 suggested_max_rm numeric(12,2) not null,
 quote_rm numeric(12,2) not null,
 customer_id uuid,
 created_by uuid not null,
 created_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp(),
 current_version integer not null default 1
);
create index if not exists yt_pos_custom_drinks_customer_idx on public.yt_pos_custom_drinks(customer_id,created_at desc);
create table if not exists public.yt_pos_custom_drink_versions (
 id bigint generated always as identity primary key,
 custom_drink_id uuid not null references public.yt_pos_custom_drinks(id) on delete cascade,
 version integer not null,
 recipe_snapshot jsonb not null,
 total_cost_rm numeric(12,2) not null,
 suggested_min_rm numeric(12,2) not null,
 suggested_max_rm numeric(12,2) not null,
 quote_rm numeric(12,2) not null,
 changed_by uuid not null,
 changed_at timestamptz not null default clock_timestamp(),
 change_kind text not null check (change_kind in ('created','repriced')),
 unique(custom_drink_id,version)
);
alter table public.yt_pos_custom_materials enable row level security;
alter table public.yt_pos_custom_drinks enable row level security;
alter table public.yt_pos_custom_drink_versions enable row level security;
revoke all on public.yt_pos_custom_materials, public.yt_pos_custom_drinks, public.yt_pos_custom_drink_versions from anon, authenticated;

create or replace function private.yt_pos_custom_calculate(p_recipe jsonb)
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
declare e jsonb; m public.yt_pos_custom_materials%rowtype; q integer;
 v_recipe jsonb:='[]'::jsonb; v_cost numeric:=0; v_base numeric:=0;
 v_min_d numeric:=0; v_max_d numeric:=0; line_base numeric;
begin
 if jsonb_typeof(p_recipe)<>'array' or jsonb_array_length(p_recipe)<1 or jsonb_array_length(p_recipe)>40 then raise exception 'custom_recipe_invalid'; end if;
 for e in select value from jsonb_array_elements(p_recipe) loop
  begin q:=(e->>'quantity')::integer; exception when others then raise exception 'custom_recipe_invalid'; end;
  if q<1 or q>50 then raise exception 'custom_recipe_invalid'; end if;
  select * into m from public.yt_pos_custom_materials where id=(e->>'material_id')::uuid;
  if not found then raise exception 'custom_material_unavailable'; end if;
  line_base:=m.unit_cost_rm*q/(1-m.margin_percent/100);
  v_cost:=v_cost+m.unit_cost_rm*q;
  v_base:=v_base+line_base;
  v_min_d:=v_min_d+line_base*m.min_discount_percent/100;
  v_max_d:=v_max_d+line_base*m.max_discount_percent/100;
  v_recipe:=v_recipe||jsonb_build_array(jsonb_build_object(
   'material_id',m.id,'name',m.name,'quantity',q,'unit_cost_rm',m.unit_cost_rm,
   'margin_percent',m.margin_percent,'min_discount_percent',m.min_discount_percent,
   'max_discount_percent',m.max_discount_percent,'price_revision',m.price_revision));
 end loop;
 return jsonb_build_object('recipe',v_recipe,'cost_rm',round(v_cost,2),
   'suggested_min_rm',greatest(round(v_base-v_max_d,2),round(v_cost,2)),
   'suggested_max_rm',greatest(round(v_base-v_min_d,2),round(v_cost,2)));
end;$function$;

create or replace function private.yt_pos_custom_materials()
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'unit_cost_rm',unit_cost_rm,
  'margin_percent',margin_percent,'min_discount_percent',min_discount_percent,
  'max_discount_percent',max_discount_percent,'active',active,'price_revision',price_revision)
  order by active desc,name) from public.yt_pos_custom_materials
  where active or private.yt_work_owner()),'[]'::jsonb);
end;$function$;

create or replace function private.yt_pos_custom_material_save(
 p_id uuid,p_name text,p_unit_cost numeric,p_margin numeric,p_min_discount numeric,p_max_discount numeric,p_active boolean
) returns jsonb language plpgsql security definer set search_path=''
as $function$
declare m public.yt_pos_custom_materials%rowtype;
begin
 if not private.yt_work_owner() then raise exception 'owner_only'; end if;
 if length(btrim(coalesce(p_name,''))) not between 1 and 80 or p_unit_cost is null or p_unit_cost<0
  or p_margin is null or p_margin<0 or p_margin>=100 or p_min_discount is null or p_min_discount<0
  or p_max_discount is null or p_max_discount<p_min_discount or p_max_discount>100 then
  raise exception 'custom_material_invalid';
 end if;
 if p_id is null then
  insert into public.yt_pos_custom_materials(name,unit_cost_rm,margin_percent,min_discount_percent,max_discount_percent,active)
  values(btrim(p_name),p_unit_cost,p_margin,p_min_discount,p_max_discount,coalesce(p_active,true)) returning * into m;
 else
  update public.yt_pos_custom_materials set name=btrim(p_name),unit_cost_rm=p_unit_cost,margin_percent=p_margin,
   min_discount_percent=p_min_discount,max_discount_percent=p_max_discount,active=coalesce(p_active,true),
   price_revision=price_revision+case when unit_cost_rm is distinct from p_unit_cost or margin_percent is distinct from p_margin
    or min_discount_percent is distinct from p_min_discount or max_discount_percent is distinct from p_max_discount then 1 else 0 end,
   updated_at=clock_timestamp() where id=p_id returning * into m;
  if not found then raise exception 'custom_material_unavailable'; end if;
 end if;
 return jsonb_build_object('id',m.id,'name',m.name,'unit_cost_rm',m.unit_cost_rm,'margin_percent',m.margin_percent,
  'min_discount_percent',m.min_discount_percent,'max_discount_percent',m.max_discount_percent,'active',m.active,'price_revision',m.price_revision);
end;$function$;

create or replace function private.yt_pos_custom_create(p_name text,p_recipe jsonb,p_quote numeric)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare calc jsonb; pid uuid; d public.yt_pos_custom_drinks%rowtype; quote numeric;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only'; end if;
 if length(btrim(coalesce(p_name,''))) not between 2 and 100 then raise exception 'custom_name_invalid'; end if;
 for pid in select (value->>'material_id')::uuid from jsonb_array_elements(p_recipe) loop
  if not exists(select 1 from public.yt_pos_custom_materials where id=pid and active) then raise exception 'custom_material_unavailable'; end if;
 end loop;
 calc:=private.yt_pos_custom_calculate(p_recipe); quote:=round(p_quote,2);
 if quote is null or quote< (calc->>'cost_rm')::numeric or quote>5000 then raise exception 'custom_quote_below_cost'; end if;
 insert into public.yt_shop_products(title,category,price_rm,redeem_points,active,sort_order,series_id,is_drink)
 values(btrim(p_name),'CUSTOM',quote,null,true,999999,null,true) returning id into pid;
 insert into public.yt_pos_custom_drinks(product_id,public_name,recipe_snapshot,total_cost_rm,suggested_min_rm,suggested_max_rm,quote_rm,created_by)
 values(pid,btrim(p_name),calc->'recipe',(calc->>'cost_rm')::numeric,(calc->>'suggested_min_rm')::numeric,
  (calc->>'suggested_max_rm')::numeric,quote,auth.uid()) returning * into d;
 insert into public.yt_pos_custom_drink_versions(custom_drink_id,version,recipe_snapshot,total_cost_rm,
  suggested_min_rm,suggested_max_rm,quote_rm,changed_by,change_kind)
 values(d.id,1,d.recipe_snapshot,d.total_cost_rm,d.suggested_min_rm,d.suggested_max_rm,d.quote_rm,auth.uid(),'created');
 return jsonb_build_object('ok',true,'id',d.id,'product_id',d.product_id,'share_token',d.share_token,
  'name',d.public_name,'price_rm',d.quote_rm,'cost_rm',d.total_cost_rm,
  'suggested_min_rm',d.suggested_min_rm,'suggested_max_rm',d.suggested_max_rm,'active',true,'category','CUSTOM','is_drink',true);
end;$function$;

create or replace function private.yt_pos_custom_scan(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
declare d public.yt_pos_custom_drinks%rowtype; calc jsonb; stale boolean;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only'; end if;
 select * into d from public.yt_pos_custom_drinks where share_token=p_token;
 if not found then raise exception 'custom_code_not_found'; end if;
 calc:=private.yt_pos_custom_calculate(d.recipe_snapshot);
 select exists(select 1 from jsonb_array_elements(d.recipe_snapshot) old
  join public.yt_pos_custom_materials cur on cur.id=(old->>'material_id')::uuid
  where (old->>'price_revision')::integer<>cur.price_revision) into stale;
 if stale then return jsonb_build_object('ok',false,'error_code','custom_reprice_required','id',d.id,
  'name',d.public_name,'cost_rm',calc->'cost_rm','suggested_min_rm',calc->'suggested_min_rm',
  'suggested_max_rm',calc->'suggested_max_rm','recipe',calc->'recipe'); end if;
 return jsonb_build_object('ok',true,'product',jsonb_build_object('id',d.product_id,'custom_id',d.id,'share_token',d.share_token,'name',d.public_name,
  'price_rm',d.quote_rm,'active',true,'category','CUSTOM','is_drink',false),'name',d.public_name);
end;$function$;

create or replace function private.yt_pos_custom_reprice(p_token uuid,p_quote numeric)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare d public.yt_pos_custom_drinks%rowtype; calc jsonb; q numeric; v integer;
begin
 if not private.yt_pos_work_cashier() then raise exception 'cashier_only'; end if;
 select * into d from public.yt_pos_custom_drinks where share_token=p_token for update;
 if not found then raise exception 'custom_code_not_found'; end if;
 calc:=private.yt_pos_custom_calculate(d.recipe_snapshot); q:=round(p_quote,2);
 if q is null or q<(calc->>'cost_rm')::numeric or q>5000 then raise exception 'custom_quote_below_cost'; end if;
 v:=d.current_version+1;
 update public.yt_shop_products set price_rm=q,updated_at=clock_timestamp() where id=d.product_id and category='CUSTOM';
 update public.yt_pos_custom_drinks set recipe_snapshot=calc->'recipe',total_cost_rm=(calc->>'cost_rm')::numeric,
  suggested_min_rm=(calc->>'suggested_min_rm')::numeric,suggested_max_rm=(calc->>'suggested_max_rm')::numeric,
  quote_rm=q,current_version=v,updated_at=clock_timestamp() where id=d.id returning * into d;
 insert into public.yt_pos_custom_drink_versions(custom_drink_id,version,recipe_snapshot,total_cost_rm,
  suggested_min_rm,suggested_max_rm,quote_rm,changed_by,change_kind)
 values(d.id,v,d.recipe_snapshot,d.total_cost_rm,d.suggested_min_rm,d.suggested_max_rm,d.quote_rm,auth.uid(),'repriced');
 return jsonb_build_object('ok',true,'id',d.id,'product',jsonb_build_object('id',d.product_id,'custom_id',d.id,'share_token',d.share_token,
  'name',d.public_name,'price_rm',d.quote_rm,'active',true,'category','CUSTOM','is_drink',false));
end;$function$;

create or replace function private.yt_pos_custom_my_list()
returns jsonb language sql stable security definer set search_path=''
as $function$
 select coalesce(jsonb_agg(jsonb_build_object('name',d.public_name,'created_at',d.created_at,
  'share_token',d.share_token,'last_updated_at',d.updated_at) order by d.created_at desc),'[]'::jsonb)
 from public.yt_pos_custom_drinks d where d.customer_id=auth.uid();
$function$;

create or replace function private.yt_pos_custom_owner_history()
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
begin
 if not private.yt_work_owner() then raise exception 'owner_only'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'name',d.public_name,'customer_id',d.customer_id,
  'created_by',d.created_by,'created_at',d.created_at,'versions',(select jsonb_agg(jsonb_build_object(
   'version',v.version,'recipe',v.recipe_snapshot,'cost_rm',v.total_cost_rm,'suggested_min_rm',v.suggested_min_rm,
   'suggested_max_rm',v.suggested_max_rm,'quote_rm',v.quote_rm,'changed_by',v.changed_by,
   'changed_at',v.changed_at,'change_kind',v.change_kind) order by v.version desc)
   from public.yt_pos_custom_drink_versions v where v.custom_drink_id=d.id))
  order by d.created_at desc) from public.yt_pos_custom_drinks d),'[]'::jsonb);
end;$function$;

create or replace function private.yt_pos_custom_attach_customer(p_order uuid)
returns void language plpgsql security definer set search_path=''
as $function$
declare cid uuid; paid boolean;
begin
 select exists(select 1 from public.yt_member_orders o where o.id=p_order and o.payment_status='paid'
  and o.status not in ('cancelled','refunded')) into paid;
 if not paid then return; end if;
 select customer_id into cid from public.yt_play_consumption_bindings where order_id=p_order limit 1;
 if cid is null then return; end if;
 update public.yt_pos_custom_drinks d set customer_id=cid,updated_at=clock_timestamp()
 from public.yt_member_order_items i where i.order_id=p_order and i.product_id=d.product_id
 and (d.customer_id is null or d.customer_id=cid);
end;$function$;
create or replace function private.yt_pos_custom_order_sync()
returns trigger language plpgsql security definer set search_path=''
as $function$
begin
 if TG_TABLE_NAME='yt_member_orders' then perform private.yt_pos_custom_attach_customer(NEW.id);
 else perform private.yt_pos_custom_attach_customer(NEW.order_id); end if;
 return NEW;
end;$function$;
drop trigger if exists yt_pos_custom_order_paid_sync on public.yt_member_orders;
create trigger yt_pos_custom_order_paid_sync after update of payment_status on public.yt_member_orders
 for each row execute function private.yt_pos_custom_order_sync();
drop trigger if exists yt_pos_custom_binding_sync on public.yt_play_consumption_bindings;
create trigger yt_pos_custom_binding_sync after insert or update of customer_id on public.yt_play_consumption_bindings
 for each row execute function private.yt_pos_custom_order_sync();

create or replace function public.yt_pos_custom_materials()
returns jsonb language sql set search_path=''
as $function$ select private.yt_pos_custom_materials(); $function$;
create or replace function public.yt_pos_custom_material_save(p_id uuid,p_name text,p_unit_cost numeric,p_margin numeric,
 p_min_discount numeric,p_max_discount numeric,p_active boolean)
returns jsonb language sql set search_path=''
as $function$ select private.yt_pos_custom_material_save(p_id,p_name,p_unit_cost,p_margin,p_min_discount,p_max_discount,p_active); $function$;
create or replace function public.yt_pos_custom_create(p_name text,p_recipe jsonb,p_quote numeric)
returns jsonb language sql set search_path=''
as $function$ select private.yt_pos_custom_create(p_name,p_recipe,p_quote); $function$;
create or replace function public.yt_pos_custom_scan(p_token uuid)
returns jsonb language sql set search_path=''
as $function$ select private.yt_pos_custom_scan(p_token); $function$;
create or replace function public.yt_pos_custom_reprice(p_token uuid,p_quote numeric)
returns jsonb language sql set search_path=''
as $function$ select private.yt_pos_custom_reprice(p_token,p_quote); $function$;
create or replace function public.yt_pos_custom_my_list()
returns jsonb language sql set search_path=''
as $function$ select private.yt_pos_custom_my_list(); $function$;
create or replace function public.yt_pos_custom_owner_history()
returns jsonb language sql set search_path=''
as $function$ select private.yt_pos_custom_owner_history(); $function$;
revoke all on function public.yt_pos_custom_materials(),public.yt_pos_custom_material_save(uuid,text,numeric,numeric,numeric,numeric,boolean),
 public.yt_pos_custom_create(text,jsonb,numeric),public.yt_pos_custom_scan(uuid),public.yt_pos_custom_reprice(uuid,numeric),
 public.yt_pos_custom_my_list(),public.yt_pos_custom_owner_history() from public,anon;
grant execute on function public.yt_pos_custom_materials(),public.yt_pos_custom_material_save(uuid,text,numeric,numeric,numeric,numeric,boolean),
 public.yt_pos_custom_create(text,jsonb,numeric),public.yt_pos_custom_scan(uuid),public.yt_pos_custom_reprice(uuid,numeric),
 public.yt_pos_custom_my_list(),public.yt_pos_custom_owner_history() to authenticated;
revoke all on function private.yt_pos_custom_calculate(jsonb),private.yt_pos_custom_materials(),
 private.yt_pos_custom_material_save(uuid,text,numeric,numeric,numeric,numeric,boolean),private.yt_pos_custom_create(text,jsonb,numeric),
 private.yt_pos_custom_scan(uuid),private.yt_pos_custom_reprice(uuid,numeric),private.yt_pos_custom_my_list(),
 private.yt_pos_custom_owner_history(),private.yt_pos_custom_attach_customer(uuid),private.yt_pos_custom_order_sync() from public,anon,authenticated;

create or replace function private.yt_pos_catalog()
returns jsonb language sql stable security definer set search_path=''
as $function$
 select case when private.yt_pos_work_staff() then coalesce((
  select jsonb_agg(jsonb_build_object(
  'id',p.id,'name',p.title,'category',p.category,
  'is_drink',p.is_drink,'price_rm',p.price_rm,'active',p.active,'sort_order',p.sort_order,
  'series_id',p.series_id,'series_name',s.name,'benefit_mode',s.benefit_mode,
  'series_active',s.active,'game_plays',s.game_plays
  ) order by p.sort_order,p.category,p.title)
  from public.yt_shop_products p left join public.yt_pos_series s on s.id=p.series_id
  where (p.active or private.yt_has_role('owner')) and p.category<>'CUSTOM'
 ),'[]'::jsonb) else null end;
$function$;
