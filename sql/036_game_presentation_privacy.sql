-- Customer-facing game presentation: more chance choices, editable fortune
-- copy, and no public exposure of the skill-game scoring cap/thresholds.

ALTER TABLE public.games
 ADD COLUMN choice_count smallint NOT NULL DEFAULT 3 CHECK(choice_count BETWEEN 3 AND 8),
 ADD COLUMN fortune_texts text[] NOT NULL DEFAULT '{}'::text[] CHECK(cardinality(fortune_texts) BETWEEN 0 AND 8);

UPDATE public.games SET choice_count=6,fortune_texts=ARRAY[
 '上上签 · 今夜好事正在靠近。',
 '好运签 · 你选的路会有惊喜。',
 '桃花签 · 今晚有人记得你的笑。',
 '贵人签 · 会有人为你带来好消息。',
 '勇气签 · 先迈一步，好运才会出现。',
 '如愿签 · 心里想的事，正在慢慢成真。'
] WHERE slug='mystery-card';
UPDATE public.games SET choice_count=5 WHERE slug='mystery-box';

CREATE OR REPLACE FUNCTION private.yt_owner_game_copy_save(p_game uuid,p_fortunes text[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE g public.games%rowtype;clean text[];
BEGIN
 IF NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only'; END IF;
 SELECT * INTO g FROM public.games WHERE id=p_game FOR UPDATE;
 IF NOT FOUND OR g.slug<>'mystery-card' THEN RAISE EXCEPTION 'game_not_supported'; END IF;
 IF p_fortunes IS NULL OR cardinality(p_fortunes)<>g.choice_count
    OR EXISTS(SELECT 1 FROM unnest(p_fortunes) x WHERE x IS NULL OR length(btrim(x)) NOT BETWEEN 2 AND 60)
 THEN RAISE EXCEPTION 'invalid_fortune_texts'; END IF;
 SELECT array_agg(btrim(x) ORDER BY n) INTO clean FROM unnest(p_fortunes) WITH ORDINALITY q(x,n);
 UPDATE public.games SET fortune_texts=clean WHERE id=g.id;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 VALUES(auth.uid(),'game.fortunes_updated','game',g.id,jsonb_build_object('count',cardinality(clean)));
 RETURN jsonb_build_object('ok',true,'id',g.id,'fortune_texts',to_jsonb(clean));
END;
$function$;

CREATE OR REPLACE FUNCTION public.yt_owner_game_copy_save(p_game uuid,p_fortunes text[])
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $function$ SELECT private.yt_owner_game_copy_save(p_game,p_fortunes); $function$;

REVOKE ALL ON FUNCTION private.yt_owner_game_copy_save(uuid,text[]),public.yt_owner_game_copy_save(uuid,text[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_owner_game_copy_save(uuid,text[]),public.yt_owner_game_copy_save(uuid,text[]) TO authenticated;

CREATE OR REPLACE FUNCTION private.yt_game_checkpoint(p_session uuid,p_action text,p_round integer DEFAULT NULL,p_score numeric DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE s public.game_sessions%rowtype;p public.game_passes%rowtype;slug text;j jsonb;rounds jsonb;active integer;n integer;fail_value jsonb;v_choice_limit integer;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
 PERFORM pg_advisory_xact_lock(781943081);
 SELECT * INTO s FROM public.game_sessions WHERE id=p_session FOR UPDATE;
 IF NOT FOUND OR s.customer_id<>auth.uid() THEN RAISE EXCEPTION 'session_not_owned'; END IF;
 SELECT * INTO p FROM public.game_passes WHERE id=s.pass_id;
 IF p.status='revoked' THEN RAISE EXCEPTION 'pass_revoked'; END IF;
 IF s.status<>'started' OR p.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'pass_expired_or_used'; END IF;
 SELECT g.slug,g.choice_count INTO slug,v_choice_limit FROM public.games g WHERE g.id=s.game_id;
 j:=s.progress;rounds:=coalesce(j->'rounds','[]'::jsonb);n:=jsonb_array_length(rounds);active:=nullif(j->>'active_round','')::integer;
 fail_value:=CASE WHEN slug='reaction-test' THEN 'null'::jsonb ELSE '0'::jsonb END;
 IF p_action='resume' THEN
  IF active IS NOT NULL AND slug IN('reaction-test','stop-the-bar') THEN
   rounds:=rounds||jsonb_build_array(fail_value);j:=j||jsonb_build_object('rounds',rounds,'active_round',null);
  END IF;
 ELSIF p_action='pick' THEN
  IF slug NOT IN('mystery-card','mystery-box') OR p_round IS NULL OR p_round<1 OR p_round>v_choice_limit THEN RAISE EXCEPTION 'invalid_game_choice'; END IF;
  IF j ? 'choice' AND (j->>'choice')::integer<>p_round THEN RAISE EXCEPTION 'game_choice_locked'; END IF;
  j:=j||jsonb_build_object('choice',p_round);
 ELSIF p_action='begin' THEN
  IF slug NOT IN('reaction-test','stop-the-bar') OR p_round IS NULL OR p_round<>n+1 OR p_round NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION 'game_round_locked'; END IF;
  IF active IS NOT NULL AND active<>p_round THEN RAISE EXCEPTION 'game_round_locked'; END IF;
  j:=j||jsonb_build_object('rounds',rounds,'active_round',p_round);
 ELSIF p_action='finish' THEN
  IF slug NOT IN('reaction-test','stop-the-bar') OR p_round IS NULL OR p_round NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION 'invalid_game_round'; END IF;
  IF p_score IS NOT NULL AND (p_score::text IN('NaN','Infinity','-Infinity') OR p_score<>trunc(p_score) OR (slug='reaction-test' AND p_score NOT BETWEEN 1 AND 9000) OR (slug='stop-the-bar' AND p_score NOT BETWEEN 0 AND 100)) THEN RAISE EXCEPTION 'invalid_game_score'; END IF;
  IF p_round<=n THEN
   IF rounds->(p_round-1) IS DISTINCT FROM coalesce(to_jsonb(p_score),'null'::jsonb) THEN RAISE EXCEPTION 'game_round_locked'; END IF;
   RETURN j;
  END IF;
  IF active IS DISTINCT FROM p_round OR p_round<>n+1 THEN RAISE EXCEPTION 'game_round_locked'; END IF;
  rounds:=rounds||jsonb_build_array(p_score);j:=j||jsonb_build_object('rounds',rounds,'active_round',null);
 ELSE RAISE EXCEPTION 'invalid_game_action'; END IF;
 UPDATE public.game_sessions SET progress=j WHERE id=s.id;
 RETURN j;
END;
$function$;

CREATE OR REPLACE FUNCTION private.yt_game_result(p_session uuid,p_score numeric DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE s public.game_sessions%rowtype;p public.game_passes%rowtype;g public.games%rowtype;r public.rewards%rowtype;b public.yt_game_best_records%rowtype;v_score numeric;percent integer;rounds jsonb;
BEGIN
 IF auth.uid() IS NULL OR EXISTS(SELECT 1 FROM public.work_accounts WHERE auth_user_id=auth.uid()) THEN RAISE EXCEPTION 'customer_only'; END IF;
 PERFORM pg_advisory_xact_lock(781943081);
 SELECT * INTO s FROM public.game_sessions WHERE id=p_session FOR UPDATE;
 IF NOT FOUND OR s.customer_id<>auth.uid() THEN RAISE EXCEPTION 'session_not_owned'; END IF;
 SELECT * INTO p FROM public.game_passes WHERE id=s.pass_id;
 IF p.status='revoked' OR s.status='cancelled' THEN RAISE EXCEPTION 'pass_revoked'; END IF;
 SELECT * INTO g FROM public.games WHERE id=s.game_id;
 IF s.status<>'completed' AND (p.expires_at<=clock_timestamp() OR s.started_at>clock_timestamp()-interval '2 seconds') THEN RAISE EXCEPTION 'game_not_finished_or_expired'; END IF;
 IF s.scored_at IS NULL THEN
  IF g.mode='skill' THEN
   rounds:=coalesce(s.progress->'rounds','[]');
   IF jsonb_array_length(rounds)<>3 OR s.progress->>'active_round' IS NOT NULL THEN RAISE EXCEPTION 'game_rounds_incomplete'; END IF;
   IF g.slug='stop-the-bar' THEN SELECT coalesce(max(value::numeric),0) INTO v_score FROM jsonb_array_elements_text(rounds);percent:=v_score::integer;
   ELSIF g.slug='reaction-test' THEN SELECT min(value::numeric) INTO v_score FROM jsonb_array_elements_text(rounds) WHERE value IS NOT NULL;
    percent:=CASE WHEN v_score IS NULL THEN 0 ELSE greatest(0,least(100,round(100*(s.reaction_zero_snapshot-v_score)/(s.reaction_zero_snapshot-s.reaction_perfect_snapshot))::integer)) END;
   ELSE RAISE EXCEPTION 'game_not_supported'; END IF;
  ELSIF g.slug='moon-dice' THEN
   v_score:=CASE s.result_key WHEN 'R5' THEN 5 WHEN 'R4' THEN 4 WHEN 'R3' THEN 3 ELSE p_score END;
   IF v_score IS NULL OR v_score::text IN('NaN','Infinity','-Infinity') OR v_score<>trunc(v_score) OR v_score NOT BETWEEN 0 AND 5 OR (s.result_key='R0' AND v_score>2) THEN RAISE EXCEPTION 'invalid_game_score'; END IF;
  ELSIF g.slug IN('mystery-card','mystery-box') THEN
   IF s.progress->>'choice' IS NULL THEN RAISE EXCEPTION 'game_choice_required'; END IF;
   v_score:=CASE s.result_key WHEN 'R5' THEN 5 WHEN 'R4' THEN 4 WHEN 'R3' THEN 3 ELSE 1 END;
  ELSE RAISE EXCEPTION 'game_not_supported'; END IF;
  UPDATE public.game_sessions SET score=v_score,achievement_percent=percent,scored_at=clock_timestamp() WHERE id=s.id RETURNING * INTO s;
  INSERT INTO public.yt_game_best_records(customer_id,game_id,best_score,played_count,best_at,last_played_at) VALUES(s.customer_id,s.game_id,v_score,1,CASE WHEN v_score IS NULL THEN NULL ELSE s.scored_at END,s.scored_at)
  ON CONFLICT(customer_id,game_id) DO UPDATE SET played_count=public.yt_game_best_records.played_count+1,last_played_at=excluded.last_played_at,
  best_at=CASE WHEN excluded.best_score IS NOT NULL AND (public.yt_game_best_records.best_score IS NULL OR (g.slug='reaction-test' AND excluded.best_score<public.yt_game_best_records.best_score) OR (g.slug<>'reaction-test' AND excluded.best_score>public.yt_game_best_records.best_score)) THEN excluded.best_at ELSE public.yt_game_best_records.best_at END,
  best_score=CASE WHEN excluded.best_score IS NOT NULL AND (public.yt_game_best_records.best_score IS NULL OR (g.slug='reaction-test' AND excluded.best_score<public.yt_game_best_records.best_score) OR (g.slug<>'reaction-test' AND excluded.best_score>public.yt_game_best_records.best_score)) THEN excluded.best_score ELSE public.yt_game_best_records.best_score END;
 END IF;
 SELECT * INTO r FROM public.rewards WHERE id=s.planned_reward_id;
 SELECT * INTO b FROM public.yt_game_best_records WHERE customer_id=s.customer_id AND game_id=s.game_id;
 RETURN jsonb_build_object('session_id',s.id,'game_slug',g.slug,'mode',g.mode,'session_score',s.score,'achievement_percent',s.achievement_percent,'points',CASE WHEN g.mode='skill' THEN floor(s.points_max_snapshot*s.achievement_percent::numeric/100)::integer ELSE s.points_equivalent_snapshot END,'reward_name',r.name,'settlement_choice',s.settlement_choice,'status',s.status,'points_awarded',s.points_awarded,'personal_best',b.best_score,'played_count',b.played_count);
END;
$function$;

-- Customers and work accounts may read public presentation only. Skill caps and
-- thresholds remain available to the guarded Owner RPC, not the table API.
REVOKE SELECT ON public.games FROM authenticated;
GRANT SELECT(id,slug,title,mode,active,created_at,choice_count,fortune_texts) ON public.games TO authenticated;
