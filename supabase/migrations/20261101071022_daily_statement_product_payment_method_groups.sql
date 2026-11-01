DO $fix$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('private.yt_pos_day_preview(date)'::regprocedure) INTO d;
 IF strpos(d,'select i.product_id,i.item_name,sum(i.quantity)::bigint quantity')=0
 OR strpos(d,'join (select distinct order_id from public.yt_pos_payment_entries where business_day=d and kind=''sale'') sold')=0 THEN RAISE EXCEPTION 'Expected daily statement item query not found';END IF;
 d:=replace(d,'jsonb_agg(to_jsonb(x) order by x.quantity desc,x.item_name)','jsonb_agg(to_jsonb(x) order by x.item_name,x.product_id,x.payment_method)');
 d:=replace(d,'select i.product_id,i.item_name,sum(i.quantity)::bigint quantity','select i.product_id,i.item_name,sold.method payment_method,sum(i.quantity)::bigint quantity');
 d:=replace(d,'join (select distinct order_id from public.yt_pos_payment_entries where business_day=d and kind=''sale'') sold',
  'join (select distinct on (order_id) order_id,method from public.yt_pos_payment_entries where business_day=d and kind=''sale'' order by order_id,received_at,id) sold');
 d:=replace(d,'where i.quantity>0 group by i.product_id,i.item_name','where i.quantity>0 group by i.product_id,i.item_name,sold.method');
 EXECUTE d;
END $fix$;
