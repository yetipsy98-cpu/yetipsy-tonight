CREATE OR REPLACE FUNCTION private.yt_pos_owner_backdate_requests_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $function$
declare rows jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',q.id,'order_id',q.order_id,'order_no',o.order_no,'table_label',o.table_label,
  'requested_business_day',q.requested_business_day,'status',q.status,'created_at',q.created_at,
  'order_created_at',o.created_at,'notes',o.notes,'amount_rm',o.amount_rm,'payment_status',o.payment_status,
  'reviewed_at',q.reviewed_at,'review_note',q.review_note,
  'requester_name',coalesce(w.username,'Cashier'),'created_by_name',coalesce(cw.username,'Cashier'),
  'reviewer_name',coalesce(r.username,'Owner'),
  'items',coalesce((select jsonb_agg(jsonb_build_object(
   'id',i.id,'product_id',i.product_id,'name',i.item_name,'quantity',i.quantity,
   'unit_price_rm',i.unit_price_rm,'line_total_rm',i.quantity*i.unit_price_rm
  ) order by i.item_name) from public.yt_member_order_items i
   where i.order_id=o.id and i.quantity>0),'[]'::jsonb)
 ) order by (q.status='pending') desc,q.created_at desc),'[]'::jsonb)
 into rows from (
  select * from public.yt_pos_order_backdate_requests order by created_at desc limit 100
 ) q join public.yt_member_orders o on o.id=q.order_id
 left join public.work_accounts w on w.auth_user_id=q.requester_id
 left join public.work_accounts cw on cw.auth_user_id=o.created_by
 left join public.work_accounts r on r.auth_user_id=q.reviewer_id;
 return rows;
end;$function$;
