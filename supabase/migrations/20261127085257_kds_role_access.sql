-- Staff keep production visibility; production mutations require existing Cashier/Owner permission.
do $$
declare sig text;definition text;anchor text:=E'begin\n';at_pos integer;guard text;
begin
 foreach sig in array array['private.yt_kds_multi(text,jsonb)','public.yt_pos_item_fulfill(uuid,uuid,boolean)','private.yt_store_box_request_action(uuid,text,integer,text)','private.yt_pos_action(uuid,text,text,text)','private.yt_freeflow_core(uuid,boolean,text,jsonb)'] loop
  definition:=pg_get_functiondef(sig::regprocedure);
  guard:=case sig
   when 'private.yt_kds_multi(text,jsonb)' then E' if p_action is distinct from ''snapshot'' and not coalesce(private.yt_pos_work_staff() and (private.yt_work_owner() or private.yt_pos_work_cashier()),false) then raise exception ''cashier_only'';end if;\n'
   when 'private.yt_freeflow_core(uuid,boolean,text,jsonb)' then E' if p_action in(''complete'',''complete_group'') and (p_guest or not coalesce(private.yt_pos_work_staff() and (private.yt_work_owner() or private.yt_pos_work_cashier()),false)) then raise exception ''cashier_only'';end if;\n'
   when 'private.yt_pos_action(uuid,text,text,text)' then E' if p_action=''fulfilled'' and not coalesce(private.yt_pos_work_staff() and (private.yt_work_owner() or private.yt_pos_work_cashier()),false) then raise exception ''cashier_only'';end if;\n'
   else E' if not coalesce(private.yt_pos_work_staff() and (private.yt_work_owner() or private.yt_pos_work_cashier()),false) then raise exception ''cashier_only'';end if;\n' end;
  at_pos:=strpos(definition,anchor);if at_pos=0 then raise exception 'kds_permission_patch_anchor_missing: %',sig;end if;
  execute overlay(definition placing guard from at_pos+length(anchor) for 0);
 end loop;
end $$;

create or replace function private.yt_kds_production_history(p_day date,p_status text default 'served',p_source text default 'all',p_search text default '',p_offset integer default 0,p_limit integer default 80) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;manager boolean:=coalesce(private.yt_pos_work_cashier() or private.yt_work_owner(),false);
begin
 if auth.uid() is null or not coalesce(private.yt_pos_work_staff(),false) then raise exception 'staff_only';end if;
 if p_status='cancelled' and not manager then raise exception 'cashier_only';end if;
 if p_day is null or p_status not in('served','cancelled') or p_source not in('all','order','freeflow','storebox') or p_offset<0 or p_limit not between 1 and 500 or length(coalesce(p_search,''))>120 then raise exception 'invalid_filter';end if;
 with grouped as (
  select max(id) id,max(completed_at) completed_at,kind,status,order_id,order_no,table_label,name,note,case when manager then reason end reason,case when manager then actor_id end actor_id,case when manager then actor_name end actor_name,count(*)::integer quantity
  from private.yt_kds_production_events where business_day=p_day and status=p_status and (p_source='all' or kind=p_source) and (coalesce(p_search,'')='' or concat_ws(' ',table_label,order_no,name,case when manager then actor_name end) ilike '%'||btrim(p_search)||'%')
  group by batch_id,kind,status,order_id,order_no,table_label,name,note,reason,actor_id,actor_name
 ),page as(select * from grouped order by completed_at desc,id desc offset p_offset limit p_limit)
 select jsonb_build_object('permissions',jsonb_build_object('can_view_cancelled',manager,'can_view_actor',manager,'can_view_audit',manager),'rows',coalesce((select jsonb_agg(to_jsonb(p) order by completed_at desc,id desc) from page p),'[]'),'total',(select count(*) from grouped),'offset',p_offset,'limit',p_limit) into result;
 return result;
end $$;
