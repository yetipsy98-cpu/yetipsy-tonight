-- The hosted database rejects UPDATE without WHERE, including singleton settings.
do $$
declare def text;old_statement text:='update private.yt_kds_mode set enabled=v_enabled,version=version+1,changed_by=actor,changed_at=clock_timestamp();';
new_statement text:='update private.yt_kds_mode set enabled=v_enabled,version=version+1,changed_by=actor,changed_at=clock_timestamp() where yt_kds_mode.id=true;';
begin
 def:=pg_get_functiondef('private.yt_kds_multi(text,jsonb)'::regprocedure);
 if strpos(def,old_statement)=0 then raise exception 'kds_mode_update_guard_not_found';end if;
 execute replace(def,old_statement,new_statement);
end $$;
