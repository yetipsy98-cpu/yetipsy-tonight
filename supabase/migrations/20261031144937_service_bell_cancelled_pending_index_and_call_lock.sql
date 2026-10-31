DROP INDEX public.yt_play_one_pending_bell;
CREATE UNIQUE INDEX yt_play_one_pending_bell ON public.yt_play_bell_requests(customer_id)
 WHERE acknowledged_at IS NULL AND cancelled_at IS NULL;
DO $fix$
DECLARE d text;needle text:='if not private.yt_play_customer() then raise exception ''customer_only''; end if;';
BEGIN
 SELECT pg_get_functiondef('private.yt_play_bell_call(text,text,text,double precision,double precision)'::regprocedure) INTO d;
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'Expected bell customer guard not found';END IF;
 EXECUTE replace(d,needle,needle||E'\n  perform pg_advisory_xact_lock(hashtextextended(''yt-service-bell:''||auth.uid()::text,0));');
END $fix$;
