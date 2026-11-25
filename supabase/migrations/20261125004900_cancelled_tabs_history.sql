-- Archive cancelled unpaid tabs alongside settled orders without treating them as sales.
do $$declare definition text;needle text;begin
 definition:=pg_get_functiondef('private.yt_pos_orders_day(text,date,integer)'::regprocedure);
 needle:='p_scope=''paid'' and x.payment_status in (''paid'',''refunded'')';
 if position(needle in definition)=0 then raise exception 'orders_day_filter_changed';end if;
 definition:=replace(definition,needle,'p_scope=''paid'' and (x.payment_status in (''paid'',''refunded'') or x.status=''cancelled'')');
 needle:='coalesce(x.pos_business_day,private.yt_business_day(x.paid_at))';
 if position(needle in definition)=0 then raise exception 'orders_day_date_changed';end if;
 definition:=replace(definition,needle,'coalesce(x.pos_business_day,private.yt_business_day(coalesce(x.paid_at,x.created_at)))');
 definition:=replace(definition,'case when p_scope=''paid'' then x.paid_at else x.created_at end','case when p_scope=''paid'' then coalesce(x.paid_at,x.created_at) else x.created_at end');
 execute definition;
end $$;
-- Direct cancellations may predate revision snapshots. Their existing order events
-- still carry the cancellation reason, timestamp and operator.
do $$declare definition text;needle text;begin
 definition:=pg_get_functiondef('private.yt_pos_owner_order_context(uuid)'::regprocedure);
 needle:='return b||jsonb_build_object(';
 if position(needle in definition)=0 then raise exception 'order_context_changed';end if;
 execute replace(definition,needle,$patch$return b||jsonb_build_object('events',coalesce((select jsonb_agg(to_jsonb(ev) order by ev.created_at desc) from(select e.event_type,e.note,e.created_at,coalesce(w.username,'Staff') actor_name from public.yt_pos_order_events e left join public.work_accounts w on w.auth_user_id=e.actor_id where e.order_id=p_order order by e.created_at desc,e.id desc limit 40) ev),'[]'::jsonb),$patch$);
end $$;
