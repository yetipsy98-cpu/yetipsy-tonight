create or replace function private.yt_store_box_progress(p_box uuid,p_action text,p_completed_delta integer default 0) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b public.yt_store_boxes%rowtype;event_name text;cancelled_requests integer:=0;revoked_claims integer:=0;
begin
 if not (private.yt_work_owner() or (private.yt_pos_work_staff() and exists(select 1 from public.work_accounts wa where wa.auth_user_id=auth.uid() and wa.role='cashier'))) then
  raise exception 'cashier_or_owner_only';
 end if;
 if p_box is null then raise exception 'invalid_store_box_progress';end if;
 if p_action='delete' and not private.yt_work_owner() then raise exception 'owner_only';end if;
 if p_action='complete' then raise exception 'store_box_progress_retired';end if;
 if p_action not in ('pause','resume','delete') then raise exception 'invalid_store_box_progress';end if;
 select * into b from public.yt_store_boxes where id=p_box for update;
 if not found then raise exception 'store_box_not_found';end if;
 if p_action='delete' then
  if b.status='cancelled' then raise exception 'store_box_already_deleted';end if;
  update public.yt_store_box_requests
   set status='cancelled',cancelled_by=auth.uid(),cancelled_at=clock_timestamp(),cancel_reason='存酒箱由 Owner 删除'
   where box_id=b.id and status in ('pending','accepted','preparing');
  get diagnostics cancelled_requests = row_count;
  update public.yt_store_box_claims
   set status='cancelled',claim_token=null,cancelled_by=auth.uid(),cancelled_at=clock_timestamp()
   where box_id=b.id and status='issued';
  get diagnostics revoked_claims = row_count;
  update public.yt_store_boxes set status='cancelled',updated_at=clock_timestamp() where id=b.id returning * into b;
  insert into public.yt_store_box_events(box_id,event_type,actor_id,note,metadata)
   values(b.id,'box_deleted',auth.uid(),'Owner 删除存酒箱',jsonb_build_object('cancelled_requests',cancelled_requests,'revoked_claims',revoked_claims));
  return to_jsonb(b);
 end if;
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
