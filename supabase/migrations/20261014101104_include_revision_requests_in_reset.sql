do $$
declare definition text; needle text:='public.yt_pos_order_revisions,public.yt_pos_payment_entries';
begin
 select pg_get_functiondef('private.yt_owner_reset_v9(uuid,text,text,uuid,uuid,bigint[],text[])'::regprocedure) into definition;
 if position(needle in definition)=0 then raise exception 'reset_function_shape_changed'; end if;
 definition:=replace(definition,needle,'public.yt_pos_owner_revision_requests,public.yt_pos_order_revisions,public.yt_pos_payment_entries');
 execute definition;
end $$;
