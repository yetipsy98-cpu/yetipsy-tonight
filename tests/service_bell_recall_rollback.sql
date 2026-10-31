BEGIN;
DO $test$
DECLARE member uuid;actor uuid;s public.yt_play_upgrade_settings%rowtype;kind text;r jsonb;r2 jsonb;first_id uuid;second_id uuid;before_count int;
BEGIN
 SELECT * INTO STRICT s FROM public.yt_play_upgrade_settings WHERE id=true;
 SELECT id INTO kind FROM public.yt_play_bell_types WHERE enabled ORDER BY sort_order LIMIT 1;
 SELECT auth_user_id INTO actor FROM public.work_accounts WHERE active AND NOT must_change_password AND role='cashier' LIMIT 1;
 IF actor IS NULL THEN SELECT auth_user_id INTO actor FROM public.work_accounts WHERE active AND NOT must_change_password AND role='owner' LIMIT 1;END IF;
 SELECT p.auth_user_id INTO member FROM public.pin_accounts p WHERE NOT EXISTS(SELECT 1 FROM public.work_accounts w WHERE w.auth_user_id=p.auth_user_id)
 AND NOT EXISTS(SELECT 1 FROM public.yt_play_bell_requests b WHERE b.customer_id=p.auth_user_id AND b.cancelled_at IS NULL AND (b.acknowledged_at IS NULL OR b.acknowledged_at+make_interval(secs=>s.bell_complete_seconds)>clock_timestamp())) LIMIT 1;
 IF member IS NULL OR actor IS NULL OR kind IS NULL THEN RAISE EXCEPTION 'missing_test_identity';END IF;
 INSERT INTO public.yt_play_bell_requests(customer_id,table_label,type_id,note,cancelled_at,cancelled_by) VALUES(member,'TEST',kind,'ROLLBACK cancelled fixture',clock_timestamp(),member);
 SELECT count(*) INTO before_count FROM public.yt_play_bell_requests;
 PERFORM set_config('request.jwt.claim.sub',member::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
 BEGIN PERFORM public.yt_play_bell_call('1',kind,'test',NULL,NULL);RAISE EXCEPTION 'FAIL location bypass';EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'location_required' THEN RAISE;END IF;END;
 r:=public.yt_play_bell_call('1',kind,'ROLLBACK bell regression',s.bell_lat,s.bell_lng);first_id:=(r->>'id')::uuid;
 IF r->>'status'<>'pending' THEN RAISE EXCEPTION 'FAIL first call';END IF;
 BEGIN PERFORM public.yt_play_bell_call('1',kind,'duplicate',s.bell_lat,s.bell_lng);RAISE EXCEPTION 'FAIL double click created duplicate';EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'bell_already_active' THEN RAISE;END IF;END;
 PERFORM public.yt_play_bell_cancel(first_id);
 r2:=public.yt_play_bell_call('1',kind,'ROLLBACK call after cancel',s.bell_lat,s.bell_lng);second_id:=(r2->>'id')::uuid;
 IF second_id IS NULL OR second_id=first_id THEN RAISE EXCEPTION 'FAIL recall after cancel';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.yt_play_bell_requests WHERE id=first_id AND cancelled_at IS NOT NULL AND acknowledged_at IS NULL) THEN RAISE EXCEPTION 'FAIL cancelled history modified';END IF;
 PERFORM set_config('request.jwt.claim.sub',actor::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
 PERFORM public.yt_play_bell_ack(second_id);
 PERFORM set_config('request.jwt.claim.sub',member::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
 BEGIN PERFORM public.yt_play_bell_call('1',kind,'cooldown',s.bell_lat,s.bell_lng);RAISE EXCEPTION 'FAIL acknowledgement cooldown bypass';EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'bell_already_active' THEN RAISE;END IF;END;
 UPDATE public.yt_play_bell_requests SET acknowledged_at=clock_timestamp()-make_interval(secs=>s.bell_complete_seconds+1) WHERE id=second_id;
 r:=public.yt_play_bell_call('1',kind,'ROLLBACK call after completion',s.bell_lat,s.bell_lng);
 IF r->>'status'<>'pending' OR (SELECT count(*) FROM public.yt_play_bell_requests)<>before_count+3 THEN RAISE EXCEPTION 'FAIL completion recall';END IF;
END $test$;
ROLLBACK;
SELECT 'PASS cancelled history preserved; call, duplicate protection, cancel and recall, cashier acknowledgement, cooldown, completion recall and GPS checks; all test calls rolled back' result;
