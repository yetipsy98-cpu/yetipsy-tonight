-- Include the business date that an expiry timestamp closes, so clients do not
-- label the next cutoff date as an extra calendar day.
do $$
declare
 target record;
 function_def text;
 old_expr text;
 new_expr text;
begin
 for target in
  select unnest(array[
   'private.yt_my_store_boxes()',
   'private.yt_store_box_staff_boxes()',
   'private.yt_store_box_staff_search(text)'
  ]) as signature
 loop
  function_def:=pg_get_functiondef(target.signature::regprocedure);
  if target.signature='private.yt_my_store_boxes()' then
   old_expr:='b.claimed_at,b.storage_expires_at,b.created_at,';
   new_expr:='b.claimed_at,b.storage_expires_at,private.yt_business_day(b.storage_expires_at-interval ''1 microsecond'') storage_expiry_business_day,private.yt_business_day(clock_timestamp()) current_business_day,b.created_at,';
  else
   old_expr:='b.claimed_at,b.storage_expires_at,b.updated_at,';
   new_expr:='b.claimed_at,b.storage_expires_at,private.yt_business_day(b.storage_expires_at-interval ''1 microsecond'') storage_expiry_business_day,private.yt_business_day(clock_timestamp()) current_business_day,b.updated_at,';
  end if;
  if position(old_expr in function_def)=0 then raise exception 'store_box_expiry_projection_not_found: %',target.signature;end if;
  execute replace(function_def,old_expr,new_expr);
 end loop;
end $$;
