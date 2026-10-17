-- Restore operational store-box controls and move deletion to Owner's rule configuration.
create or replace function private.yt_store_box_progress(p_box uuid,p_action text,p_completed_delta integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b public.yt_store_boxes%rowtype;event_name text;
begin
 if not (private.yt_work_owner() or (private.yt_pos_work_staff() and exists(select 1 from public.work_accounts wa where wa.auth_user_id=auth.uid() and wa.role='cashier'))) then
  raise exception 'cashier_or_owner_only';
 end if;
 if p_box is null then raise exception 'invalid_store_box_progress';end if;
 if p_action='complete' then raise exception 'store_box_progress_retired';end if;
 if p_action not in ('pause','resume') then raise exception 'invalid_store_box_progress';end if;
 select * into b from public.yt_store_boxes where id=p_box for update;
 if not found then raise exception 'store_box_not_found';end if;
 if p_action='pause' then
  if b.status not in ('active','exhausted') then raise exception 'store_box_not_active';end if;
  update public.yt_store_boxes set status='paused',updated_at=clock_timestamp() where id=b.id returning * into b;event_name:='box_paused';
 else
  if b.status<>'paused' then raise exception 'store_box_not_paused';end if;
  update public.yt_store_boxes set status=case when served_units=total_units then 'exhausted' else 'active' end,updated_at=clock_timestamp() where id=b.id returning * into b;event_name:='box_resumed';
 end if;
 insert into public.yt_store_box_events(box_id,event_type,completed_delta,actor_id) values(b.id,event_name,0,auth.uid());
 return to_jsonb(b);
end $$;

revoke all on function private.yt_store_box_progress(uuid,text,integer) from public,anon;
grant execute on function private.yt_store_box_progress(uuid,text,integer) to authenticated;

create or replace function private.yt_store_box_rule_delete(p_product uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.yt_store_box_product_rules%rowtype;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_product is null then raise exception 'invalid_store_box_rule';end if;
 delete from public.yt_store_box_product_rules where product_id=p_product returning * into r;
 if not found then raise exception 'store_box_rule_not_found';end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(auth.uid(),'store_box.rule_delete','product',p_product,to_jsonb(r));
 return jsonb_build_object('deleted',true,'product_id',p_product);
end $$;

revoke all on function private.yt_store_box_rule_delete(uuid) from public,anon;
grant execute on function private.yt_store_box_rule_delete(uuid) to authenticated;

create or replace function public.yt_store_box_rule_delete(p_product uuid) returns jsonb
language sql set search_path='' as $$select private.yt_store_box_rule_delete(p_product)$$;
revoke all on function public.yt_store_box_rule_delete(uuid) from public,anon;
grant execute on function public.yt_store_box_rule_delete(uuid) to authenticated;

-- Cashier-created balances expire at the end of the configured business day.
-- Use the shared business-day cutoff calculation instead of elapsed 24-hour days.
do $$
declare function_def text;
 old_expr text := 'storage_expires_at=coalesce(storage_expires_at,clock_timestamp()+make_interval(days=>expiry_days))';
 new_expr text := 'storage_expires_at=coalesce(storage_expires_at,private.yt_business_start(private.yt_business_day(clock_timestamp())+expiry_days))';
begin
 function_def:=pg_get_functiondef('private.yt_pos_checkout_with_prep(uuid,text,jsonb)'::regprocedure);
 if position(old_expr in function_def)=0 then raise exception 'store_box_checkout_expiry_expression_not_found';end if;
 execute replace(function_def,old_expr,new_expr);
end $$;
