BEGIN;
DO $test$
DECLARE owner_id uuid;member_id uuid;campaign_id uuid;card_id uuid;box_id uuid;skill_id uuid;pass_id uuid;session_id uuid;body jsonb;phrases text[]:=ARRAY['上上签 · A','好运签 · B','桃花签 · C','贵人签 · D','勇气签 · E','如愿签 · F'];
BEGIN
 SELECT auth_user_id INTO owner_id FROM public.work_accounts WHERE role='owner' AND active AND NOT must_change_password LIMIT 1;
 SELECT auth_user_id INTO member_id FROM public.pin_accounts p WHERE NOT EXISTS(SELECT 1 FROM public.work_accounts w WHERE w.auth_user_id=p.auth_user_id) LIMIT 1;
 SELECT id INTO card_id FROM public.games WHERE slug='mystery-card';SELECT id INTO box_id FROM public.games WHERE slug='mystery-box';SELECT id INTO skill_id FROM public.games WHERE slug='stop-the-bar';
 IF owner_id IS NULL OR member_id IS NULL OR card_id IS NULL OR box_id IS NULL OR skill_id IS NULL THEN RAISE EXCEPTION 'fixture_missing'; END IF;
 IF has_column_privilege('authenticated','public.games','points_max','select') OR has_column_privilege('authenticated','public.games','reaction_perfect_ms','select') THEN RAISE EXCEPTION 'skill_cap_public'; END IF;
 IF NOT has_column_privilege('authenticated','public.games','fortune_texts','select') THEN RAISE EXCEPTION 'public_game_copy_hidden'; END IF;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 body:=public.yt_owner_game_copy_save(card_id,phrases);
 IF body->'fortune_texts'<>to_jsonb(phrases) OR (SELECT choice_count FROM public.games WHERE id=card_id)<>6 OR (SELECT choice_count FROM public.games WHERE id=box_id)<>5 THEN RAISE EXCEPTION 'chance_presentation_not_saved'; END IF;
 INSERT INTO public.campaigns(name,active) VALUES('presentation rollback',true) RETURNING id INTO campaign_id;

 PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member_id)::text,true);
 BEGIN PERFORM public.yt_owner_game_copy_save(card_id,phrases);RAISE EXCEPTION 'expected_failure';EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'owner_only' THEN RAISE;END IF;END;
 INSERT INTO public.game_passes(campaign_id,issued_by,customer_id,status,claimed_at,expires_at) VALUES(campaign_id,owner_id,member_id,'claimed',now(),now()+interval '1 hour') RETURNING id INTO pass_id;
 INSERT INTO public.game_sessions(pass_id,customer_id,game_id) VALUES(pass_id,member_id,card_id) RETURNING id INTO session_id;
 PERFORM public.yt_game_checkpoint(session_id,'pick',6);
 BEGIN PERFORM public.yt_game_checkpoint(session_id,'pick',7);RAISE EXCEPTION 'expected_failure';EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT IN('invalid_game_choice','game_choice_locked') THEN RAISE;END IF;END;

 INSERT INTO public.game_passes(campaign_id,issued_by,customer_id,status,claimed_at,expires_at) VALUES(campaign_id,owner_id,member_id,'claimed',now(),now()+interval '1 hour') RETURNING id INTO pass_id;
 INSERT INTO public.game_sessions(pass_id,customer_id,game_id) VALUES(pass_id,member_id,box_id) RETURNING id INTO session_id;
 PERFORM public.yt_game_checkpoint(session_id,'pick',5);
 BEGIN PERFORM public.yt_game_checkpoint(session_id,'pick',6);RAISE EXCEPTION 'expected_failure';EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT IN('invalid_game_choice','game_choice_locked') THEN RAISE;END IF;END;

 INSERT INTO public.game_passes(campaign_id,issued_by,customer_id,status,claimed_at,expires_at) VALUES(campaign_id,owner_id,member_id,'claimed',now(),now()+interval '1 hour') RETURNING id INTO pass_id;
 INSERT INTO public.game_sessions(pass_id,customer_id,game_id,points_max_snapshot,progress,started_at) VALUES(pass_id,member_id,skill_id,123,'{"rounds":[100,70,40],"active_round":null}',now()-interval '5 seconds') RETURNING id INTO session_id;
 body:=public.yt_game_result(session_id,null);
 IF body ? 'points_max' OR (body->>'achievement_percent')::integer<>100 OR (body->>'points')::integer<>123 THEN RAISE EXCEPTION 'skill_result_privacy_or_scoring_failed'; END IF;
END;
$test$;
ROLLBACK;
