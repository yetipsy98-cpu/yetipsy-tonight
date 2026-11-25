-- Display-only snapshots for revision previews/requests. Existing write/approval guards remain.
create or replace function private.yt_pos_owner_revision_preview(p_order uuid,p_items jsonb,p_cancel boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v public.yt_member_orders%rowtype;r jsonb;received numeric;before_items jsonb;
begin
 if not (private.yt_work_owner() or private.yt_pos_work_cashier()) then raise exception 'owner_only';end if;
 select * into v from public.yt_member_orders where id=p_order and source='future_pos';
 if not found or v.status in ('cancelled','refunded') then raise exception 'order_not_editable';end if;
 r:=private.yt_pos_revision_lines(p_order,p_items,p_cancel);received:=private.yt_pos_received(p_order);
 select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'unit_price_rm',i.unit_price_rm) order by i.id),'[]'::jsonb)
 into before_items from public.yt_member_order_items i where i.order_id=p_order and i.quantity>0;
 return r||jsonb_build_object('order_id',p_order,'updated_at',v.updated_at,'before_amount_rm',v.amount_rm,'received_rm',received,
 'before_state',jsonb_build_object('items',before_items,'table_label',v.table_label,'notes',v.notes,'payment_method',v.payment_method,'business_day',coalesce(v.pos_business_day,private.yt_business_day(v.created_at)),'amount_rm',v.amount_rm),
 'balance_rm',case when v.payment_status='paid' then (r->>'net')::numeric-received else (r->>'net')::numeric end,'benefits',private.yt_pos_order_benefits(p_order));
end $$;

-- Preserve retries of requests created before the display-only snapshot was added.
do $$declare definition text;needle text;begin
 definition:=pg_get_functiondef('private.yt_pos_owner_revision_request_submit_v2(uuid,jsonb,text,text,text,timestamptz,boolean,uuid,text)'::regprocedure);
 needle:='existing.request_payload<>payload';
 if position(needle in definition)=0 then raise exception 'revision_submit_definition_changed';end if;
 execute replace(definition,needle,$replacement$(existing.request_payload #- '{preview,before_state}')<>(payload #- '{preview,before_state}')$replacement$);
end $$;

-- Include the immutable audit snapshots for previously approved requests; never compare
-- a historical request against today's edited order. Legacy missing snapshots stay unknown.
create or replace function private.yt_pos_owner_revision_requests_list()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'order_id',q.order_id,'order_no',o.order_no,'table_label',o.table_label,
 'request_payload',q.request_payload,'before_state',coalesce(q.request_payload#>'{preview,before_state}',rev.before_state,case when o.updated_at=(q.request_payload->>'expected')::timestamptz then jsonb_build_object('items',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,'unit_price_rm',i.unit_price_rm) order by i.id),'[]'::jsonb) from public.yt_member_order_items i where i.order_id=o.id and i.quantity>0),'table_label',o.table_label,'notes',o.notes,'payment_method',o.payment_method,'business_day',coalesce(o.pos_business_day,private.yt_business_day(o.created_at))) end),
 'after_state',rev.after_state,'status',q.status,'created_at',q.created_at,'reviewed_at',q.reviewed_at,'review_note',q.review_note,
 'requester_name',coalesce(w.username,'Cashier'),'reviewer_name',coalesce(r.username,'Owner')) order by (q.status='pending') desc,q.created_at desc),'[]'::jsonb)
 into rows from (select * from public.yt_pos_owner_revision_requests order by created_at desc limit 100) q
 join public.yt_member_orders o on o.id=q.order_id left join public.work_accounts w on w.auth_user_id=q.requester_id left join public.work_accounts r on r.auth_user_id=q.reviewer_id
 left join public.yt_pos_order_revisions rev on rev.request_id=q.id;
 return rows;
end $$;

-- History uses each revision's own before/after, independent of later edits.
do $$declare definition text;needle text;begin
 definition:=pg_get_functiondef('private.yt_pos_owner_order_context(uuid)'::regprocedure);
 needle:='before_state->''amount_rm'' before_amount';
 if position(needle in definition)=0 then raise exception 'revision_context_definition_changed';end if;
 execute replace(definition,needle,'before_state,after_state,'||needle);
end $$;
revoke all on function private.yt_pos_owner_revision_preview(uuid,jsonb,boolean),private.yt_pos_owner_revision_requests_list() from public,anon;
grant execute on function private.yt_pos_owner_revision_preview(uuid,jsonb,boolean),private.yt_pos_owner_revision_requests_list() to authenticated;
