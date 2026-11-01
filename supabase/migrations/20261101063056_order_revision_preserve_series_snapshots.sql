DO $fix$
DECLARE d text;needle text;replacement text;
BEGIN
 SELECT pg_get_functiondef('private.yt_pos_revision_lines(uuid,jsonb,boolean)'::regprocedure) INTO d;
 needle:='price:=case when product=old_line.product_id then old_line.unit_price_rm else p.price_rm end;';
 IF strpos(d,needle)=0 OR strpos(d,'''series_id'',p.series_id')=0 THEN RAISE EXCEPTION 'Expected revision line normalization not found';END IF;
 replacement:=E'-- A different product is a new line. Retire the original line in apply, retaining its immutable snapshot and benefit history.\n  if old_line.id is not null and product is distinct from old_line.product_id then item:=null;end if;\n  '||needle;
 d:=replace(d,needle,replacement);
 d:=replace(d,'''series_id'',p.series_id','''series_id'',case when product=old_line.product_id then old_line.series_id_at_order else p.series_id end');
 EXECUTE d;
END $fix$;
