-- Qualify the Moon hold product column so it cannot collide with the PL/pgSQL variable.
DO $migration$
DECLARE
 definition text;
 fixed_definition text;
 old_fragment text := 'SELECT id,product_id,drink_name INTO hold_id,product_id,product_name FROM public.yt_moon_preorder_holds';
 new_fragment text := 'SELECT ph.id,ph.product_id,ph.drink_name INTO hold_id,product_id,product_name FROM public.yt_moon_preorder_holds AS ph';
BEGIN
 definition:=pg_get_functiondef('private.yt_moon_preorder_scan(uuid,text,jsonb,text)'::regprocedure);
 IF position(old_fragment IN definition)=0 THEN
  RAISE EXCEPTION 'Expected Moon product lookup fragment was not found; refusing to alter a different function version';
 END IF;
 fixed_definition:=replace(definition,old_fragment,new_fragment);
 IF fixed_definition=definition THEN
  RAISE EXCEPTION 'Moon product lookup qualification did not change the function';
 END IF;
 EXECUTE fixed_definition;
END;
$migration$;
