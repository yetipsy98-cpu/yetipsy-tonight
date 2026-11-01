-- Display accounting days separately from the actual amendment timestamp.
DO $fix$
DECLARE d text;needle text;
BEGIN
 SELECT pg_get_functiondef('private.yt_pos_bill_v8(uuid)'::regprocedure) INTO d;
 needle:='''kind'',kind,''received_at'',received_at';
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'Expected bill payment history not found';END IF;
 EXECUTE replace(d,needle,needle||',''business_day'',business_day,''note'',note,''amendment_note'',case when kind in (''adjustment'',''refund'') then ''于 ''||to_char(received_at at time zone ''Asia/Kuala_Lumpur'',''YYYY-MM-DD HH24:MI'')||case when kind=''refund'' then '' 修改退款'' else '' 修改补收'' end else null end');
 SELECT pg_get_functiondef('private.yt_owner_report_v8(date,date,integer,text)'::regprocedure) INTO d;
 needle:='max(e.received_at) paid_at,string_agg';
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'Expected report order dates not found';END IF;
 EXECUTE replace(d,needle,'max(e.received_at) paid_at,max(e.business_day) business_day,string_agg(distinct case when e.kind in (''adjustment'',''refund'') then ''于 ''||to_char(e.received_at at time zone ''Asia/Kuala_Lumpur'',''YYYY-MM-DD HH24:MI'')||case when e.kind=''refund'' then '' 修改退款'' else '' 修改补收'' end||case when coalesce(e.note,'''')<>'''' then ''：''||e.note else '''' end end,''；'') amendment_note,string_agg');
END $fix$;
