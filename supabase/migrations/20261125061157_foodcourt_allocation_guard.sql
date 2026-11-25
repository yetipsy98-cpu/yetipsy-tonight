-- Keep the ordinary payment-method guard in force for historical receipts, too.
-- Only the guarded internal allocation helper may deliberately change a receipt's
-- FreeFlow/regular category while preserving its actual cash amount.
do $$declare def text;needle text;begin
 def:=pg_get_functiondef('private.yt_ff_payment_partition()'::regprocedure);
 needle:='if exists(select 1 from private.yt_foodcourt_history_orders h where h.order_id=new.order_id) then return new;end if;';
 if position(needle in def)=0 then raise exception 'history_partition_guard_changed';end if;
 execute replace(def,needle,'if current_setting(''yt.foodcourt.reclassify'',true)=''on'' and exists(select 1 from private.yt_foodcourt_history_orders h where h.order_id=new.order_id) then return new;end if;');
 def:=pg_get_functiondef('private.yt_foodcourt_reclassify(uuid,uuid)'::regprocedure);
 needle:='e public.yt_pos_payment_entries%rowtype;m text;';
 if position(needle in def)=0 then raise exception 'history_reclassify_declaration_changed';end if;
 def:=replace(def,needle,'e public.yt_pos_payment_entries%rowtype;m text;prior_mode text;');
 needle:='for e in select * from public.yt_pos_payment_entries';
 if position(needle in def)=0 then raise exception 'history_reclassify_loop_changed';end if;
 def:=replace(def,needle,'prior_mode:=coalesce(current_setting(''yt.foodcourt.reclassify'',true),'''');perform set_config(''yt.foodcourt.reclassify'',''on'',true);'||chr(10)||' '||needle);
 needle:='if transfer<>0 then raise exception ''allocation_balance_mismatch'';end if;';
 if position(needle in def)=0 then raise exception 'history_reclassify_balance_changed';end if;
 execute replace(def,needle,'perform set_config(''yt.foodcourt.reclassify'',prior_mode,true);'||chr(10)||' '||needle);
end$$;
