CREATE FUNCTION private.yt_owner_financial_export(p_start date,p_end date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $function$
DECLARE result jsonb;
BEGIN
 IF NOT private.yt_work_owner() OR NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'owner_only';END IF;
 IF p_start IS NULL OR p_end IS NULL OR p_start>p_end OR p_start<'2020-01-01' OR p_end-p_start>365 THEN RAISE EXCEPTION 'invalid_report_range';END IF;
 WITH ledger AS MATERIALIZED (
  SELECT e.*,o.order_no,o.table_label,o.amount_rm bill_rm,o.payment_status
  FROM public.yt_pos_payment_entries e JOIN public.yt_member_orders o ON o.id=e.order_id
  WHERE e.business_day BETWEEN p_start AND p_end
 ), sales AS (
  SELECT DISTINCT ON(order_id) order_id,method FROM ledger WHERE kind='sale' ORDER BY order_id,received_at,id
 ), product_rows AS MATERIALIZED (
  SELECT i.product_id,i.item_name,coalesce(nullif(p.category,''),'未分类') category,
   coalesce(s.name,'未设系列') series_name,sales.method payment_method,
   sum(i.quantity)::bigint quantity,sum(i.quantity*i.unit_price_rm)::numeric gross_rm,
   coalesce(sum(u.discount_rm),0)::numeric discount_rm,
   (sum(i.quantity*i.unit_price_rm)-coalesce(sum(u.discount_rm),0))::numeric net_rm
  FROM sales JOIN public.yt_member_order_items i ON i.order_id=sales.order_id
  LEFT JOIN public.yt_shop_products p ON p.id=i.product_id
  LEFT JOIN public.yt_pos_series s ON s.id=i.series_id_at_order
  LEFT JOIN LATERAL(SELECT coalesce(sum(x.reward_discount_rm),0) discount_rm FROM public.yt_pos_item_units x
   WHERE x.order_item_id=i.id AND NOT x.retired AND x.unit_number<=i.quantity)u ON true
  WHERE i.quantity>0 GROUP BY i.product_id,i.item_name,p.category,s.name,sales.method
 ), order_rows AS (
  SELECT order_id id,order_no,table_label,max(business_day) business_day,
   string_agg(DISTINCT method,', ' ORDER BY method) payment_method,
   max(bill_rm) bill_rm,sum(amount_rm) net_rm,max(bill_rm)-private.yt_pos_received(order_id) balance_rm,
   string_agg(DISTINCT CASE WHEN kind IN('adjustment','refund') THEN '于 '||to_char(received_at AT TIME ZONE 'Asia/Kuala_Lumpur','YYYY-MM-DD HH24:MI')||CASE WHEN kind='refund' THEN ' 修改退款' ELSE ' 修改补收' END||CASE WHEN coalesce(note,'')<>'' THEN '：'||note ELSE '' END END,'；') amendment_note
  FROM ledger GROUP BY order_id,order_no,table_label
 )
 SELECT jsonb_build_object('version',1,'complete',true,'start',p_start,'end',p_end,'generated_at',clock_timestamp(),'timezone','Asia/Kuala_Lumpur',
  'summary',(SELECT jsonb_build_object('sales_rm',coalesce(sum(amount_rm) FILTER(WHERE kind='sale'),0),'adjustments_rm',coalesce(sum(amount_rm) FILTER(WHERE kind='adjustment'),0),
   'refunds_rm',-coalesce(sum(amount_rm) FILTER(WHERE kind='refund'),0),'net_rm',coalesce(sum(amount_rm),0),'orders',count(DISTINCT order_id) FILTER(WHERE kind='sale'),'ledger_entries',count(*)) FROM ledger),
  'item_summary',(SELECT jsonb_build_object('quantity',coalesce(sum(quantity),0),'gross_rm',coalesce(sum(gross_rm),0),'discount_rm',coalesce(sum(discount_rm),0),'net_rm',coalesce(sum(net_rm),0),'products',count(DISTINCT product_id)) FROM product_rows),
  'days',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.day) FROM(SELECT business_day AS day,count(DISTINCT order_id) FILTER(WHERE kind='sale') orders,
   coalesce(sum(amount_rm) FILTER(WHERE kind='sale'),0) sales_rm,coalesce(sum(amount_rm) FILTER(WHERE kind='adjustment'),0) adjustments_rm,
   -coalesce(sum(amount_rm) FILTER(WHERE kind='refund'),0) refunds_rm,sum(amount_rm) net_rm FROM ledger GROUP BY business_day)x),'[]'::jsonb),
  'payments',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.method) FROM(SELECT method,count(DISTINCT order_id) orders,
   coalesce(sum(amount_rm) FILTER(WHERE kind='sale'),0) sales_rm,coalesce(sum(amount_rm) FILTER(WHERE kind='adjustment'),0) adjustments_rm,
   -coalesce(sum(amount_rm) FILTER(WHERE kind='refund'),0) refunds_rm,sum(amount_rm) net_rm FROM ledger GROUP BY method)x),'[]'::jsonb),
  'categories',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.category,x.series_name) FROM(SELECT category,series_name,sum(quantity) quantity,sum(gross_rm) gross_rm,sum(discount_rm) discount_rm,sum(net_rm) net_rm FROM product_rows GROUP BY category,series_name)x),'[]'::jsonb),
  'products',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.category,x.item_name,x.payment_method) FROM product_rows x),'[]'::jsonb),
  'orders',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.business_day,x.order_no,x.id) FROM order_rows x),'[]'::jsonb),
  'adjustments',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'order_no',order_no,'business_day',business_day,'kind',kind,'method',method,'amount_rm',amount_rm,'modified_at',received_at,'note',note) ORDER BY business_day,order_no,id) FROM ledger WHERE kind IN('adjustment','refund')),'[]'::jsonb),
  'counts',jsonb_build_object('orders',(SELECT count(*) FROM order_rows),'product_method_rows',(SELECT count(*) FROM product_rows),'adjustments',(SELECT count(*) FROM ledger WHERE kind IN('adjustment','refund')))
 ) INTO result;
 RETURN result;
END $function$;
CREATE FUNCTION public.yt_owner_financial_export(p_start date,p_end date)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $function$
 SELECT private.yt_owner_financial_export(p_start,p_end);
$function$;
REVOKE ALL ON FUNCTION private.yt_owner_financial_export(date,date),public.yt_owner_financial_export(date,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_owner_financial_export(date,date),public.yt_owner_financial_export(date,date) TO authenticated;
NOTIFY pgrst,'reload schema';
