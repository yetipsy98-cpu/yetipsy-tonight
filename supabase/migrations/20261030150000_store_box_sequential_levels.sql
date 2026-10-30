-- Sequential Store Box challenges: one customer-selected drink per level.
alter table public.yt_store_box_product_rules drop constraint yt_store_box_rules_selection_mode_check;
alter table public.yt_store_box_product_rules add constraint yt_store_box_rules_selection_mode_check check (selection_mode = any (array['fixed'::text,'customer'::text,'levels'::text]));
alter table public.yt_store_boxes drop constraint yt_store_boxes_selection_mode_check;
alter table public.yt_store_boxes add constraint yt_store_boxes_selection_mode_check check (selection_mode = any (array['fixed'::text,'customer'::text,'levels'::text]));

create or replace function private.yt_store_box_rule_save_levels(
 p_product uuid,p_mode text,p_expiry_days integer default 30,p_unit_label text default '杯',p_components jsonb default '[]'::jsonb,p_active boolean default true
) returns jsonb language plpgsql security definer set search_path to '' as $function$
declare encoded jsonb; result jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only'; end if;
 if jsonb_typeof(coalesce(p_components,'null'::jsonb))<>'array' or jsonb_array_length(p_components) not between 1 and 20 then raise exception 'invalid_store_box_components'; end if;
 if exists(select 1 from jsonb_array_elements(p_components) c where jsonb_typeof(c)<>'object' or length(btrim(coalesce(c->>'name',''))) not between 1 and 60 or position('::' in coalesce(c->>'name',''))>0 or position('~~' in coalesce(c->>'name',''))>0 or coalesce(c->>'quantity','')<>'1' or jsonb_typeof(c->'options')<>'array' or jsonb_array_length(c->'options') not between 1 and 20) then raise exception 'invalid_store_box_components'; end if;
 if exists(select 1 from jsonb_array_elements(p_components) c, jsonb_array_elements(c->'options') o where jsonb_typeof(o)<>'string' or length(btrim(o#>>'{}')) not between 1 and 60 or position('~~' in (o#>>'{}'))>0) then raise exception 'invalid_store_box_components'; end if;
 select jsonb_agg(jsonb_build_object('name','@YTLEVEL@'||btrim(c->>'name')||'::'||(select string_agg(btrim(o#>>'{}'),'~~' order by n) from jsonb_array_elements(c->'options') with ordinality x(o,n)),'quantity',1) order by n) into encoded from jsonb_array_elements(p_components) with ordinality x(c,n);
 result:=private.yt_store_box_rule_save_v2(p_product,p_mode,1,1,p_expiry_days,p_unit_label,'customer',encoded,p_active);
 update public.yt_store_box_product_rules set selection_mode='levels' where product_id=p_product;
 return result||jsonb_build_object('selection_mode','levels');
end $function$;
create or replace function public.yt_store_box_rule_save_levels(p_product uuid,p_mode text,p_expiry_days integer default 30,p_unit_label text default '杯',p_components jsonb default '[]'::jsonb,p_active boolean default true)
returns jsonb language sql set search_path to '' as $function$ select private.yt_store_box_rule_save_levels(p_product,p_mode,p_expiry_days,p_unit_label,p_components,p_active) $function$;
revoke all on function private.yt_store_box_rule_save_levels(uuid,text,integer,text,jsonb,boolean) from public, anon, authenticated;
revoke all on function public.yt_store_box_rule_save_levels(uuid,text,integer,text,jsonb,boolean) from public, anon;
grant execute on function public.yt_store_box_rule_save_levels(uuid,text,integer,text,jsonb,boolean) to authenticated;

create or replace function private.yt_store_box_expand_levels() returns trigger language plpgsql set search_path to '' as $function$
declare source jsonb; expanded jsonb:='[]'::jsonb; item jsonb; unit_no integer; level_no integer; line_no integer:=0;
begin
 if new.selection_mode<>'levels' then return new; end if;
 for unit_no in 1..greatest(1,(select coalesce(quantity,1) from public.yt_member_order_items where id=new.source_order_item_id)) loop
  for level_no in 0..jsonb_array_length(new.components)-1 loop
   item:=new.components->level_no; line_no:=line_no+1;
   expanded:=expanded||jsonb_build_array(jsonb_build_object('key','c'||(level_no+1)||'-u'||unit_no,'name',item->>'name','total_units',1,'served_units',0));
  end loop;
 end loop;
 new.components:=expanded; new.total_units:=jsonb_array_length(expanded); return new;
end $function$;
drop trigger if exists yt_store_box_expand_levels_trg on public.yt_store_boxes;
create trigger yt_store_box_expand_levels_trg before insert on public.yt_store_boxes for each row execute function private.yt_store_box_expand_levels();

alter function private.yt_store_box_request_v3(uuid,integer,jsonb,uuid,text) rename to yt_store_box_request_v3_legacy;
create or replace function private.yt_store_box_request_v3(p_box uuid,p_quantity integer,p_selections jsonb,p_request uuid,p_table_label text default null)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare actor uuid:=auth.uid(); b public.yt_store_boxes%rowtype; r public.yt_store_box_requests%rowtype; component jsonb; chosen jsonb; option_name text; level_label text; opts text[]; normalized jsonb; summary text;
begin
 if not private.yt_store_box_customer() then raise exception 'customer_only'; end if;
 if p_box is null or p_request is null or p_quantity is null or p_quantity<1 or p_quantity>99 or length(coalesce(p_table_label,''))>40 or jsonb_typeof(coalesce(p_selections,'[]'::jsonb))<>'array' then raise exception 'invalid_store_box_request'; end if;
 perform pg_advisory_xact_lock(781943084);
 select * into r from public.yt_store_box_requests where client_request_id=p_request;
 if found then if r.box_id<>p_box or r.quantity<>p_quantity or r.customer_id<>actor then raise exception 'request_conflict'; end if; return to_jsonb(r); end if;
 select * into b from public.yt_store_boxes where id=p_box and customer_id=actor for update;
 if not found then raise exception 'store_box_not_found'; end if;
 if b.selection_mode<>'levels' then return private.yt_store_box_request_v3_legacy(p_box,p_quantity,p_selections,p_request,p_table_label); end if;
 if p_quantity<>1 or jsonb_array_length(p_selections)<>1 then raise exception 'invalid_store_box_selection'; end if;
 update public.yt_store_box_requests set status='expired' where box_id=b.id and status='pending' and expires_at<=clock_timestamp();
 if b.storage_expires_at<=clock_timestamp() then raise exception 'store_box_expired'; end if;
 if b.status<>'active' or b.served_units>=b.total_units then raise exception 'store_box_not_available'; end if;
 if exists(select 1 from public.yt_store_box_requests where box_id=b.id and status in('pending','accepted','preparing')) then raise exception 'store_box_request_already_active'; end if;
 select c into component from jsonb_array_elements(b.components) with ordinality e(c,n) where coalesce((c->>'served_units')::integer,0)<(c->>'total_units')::integer order by n limit 1;
 if component is null then raise exception 'store_box_not_available'; end if;
 chosen:=p_selections->0;
 if jsonb_typeof(chosen)<>'object' or chosen->>'key'<>component->>'key' or coalesce(chosen->>'quantity','')<>'1' then raise exception 'store_box_level_order_required'; end if;
 level_label:=split_part(split_part(component->>'name','@YTLEVEL@',2),'::',1);
 select array_agg(btrim(x)) into opts from unnest(string_to_array(split_part(component->>'name','::',2),'~~')) x;
 option_name:=btrim(coalesce(chosen->>'option',''));
 if not option_name=any(coalesce(opts,array[]::text[])) then raise exception 'invalid_store_box_selection'; end if;
 normalized:=jsonb_build_array(jsonb_build_object('key',component->>'key','name',level_label||' · '||option_name,'option',option_name,'quantity',1));
 insert into public.yt_store_box_requests(box_id,customer_id,quantity,component_key,component_name,selections,client_request_id,table_label)
 values(b.id,actor,1,component->>'key',level_label||' · '||option_name,normalized,p_request,nullif(btrim(p_table_label),'')) returning * into r;
 update public.yt_store_boxes set table_label=coalesce(nullif(btrim(p_table_label),''),table_label),updated_at=clock_timestamp() where id=b.id;
 insert into public.yt_store_box_events(box_id,request_id,event_type,quantity,customer_id,metadata) values(b.id,r.id,'drink_requested',1,actor,jsonb_build_object('selections',normalized));
 return to_jsonb(r);
end $function$;
revoke all on function private.yt_store_box_request_v3(uuid,integer,jsonb,uuid,text) from public, anon, authenticated;
grant execute on function private.yt_store_box_request_v3(uuid,integer,jsonb,uuid,text) to authenticated;
create or replace function public.yt_store_box_request_v3(p_box uuid,p_quantity integer,p_selections jsonb,p_request uuid,p_table_label text)
returns jsonb language sql set search_path to '' as $function$ select private.yt_store_box_request_v3(p_box,p_quantity,p_selections,p_request,p_table_label) $function$;
