-- Skills use a configured points cap; chance games keep their prize draw.
CREATE OR REPLACE FUNCTION private.yt_start_game(p_pass uuid, p_game uuid)
 RETURNS TABLE(session_id uuid, game_slug text, result_key text, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_actor uuid:=auth.uid();v_pass public.game_passes%rowtype;
 v_game public.games%rowtype;v_existing public.game_sessions%rowtype;
 v_total integer:=0;v_roll integer;v_entry public.reward_pool_entries%rowtype;
 v_ids uuid[]:=array[]::uuid[];v_weights integer[]:=array[]::integer[];
 v_rewards uuid[]:=array[]::uuid[];v_results text[]:=array[]::text[];
 v_idx integer;v_choice uuid;v_result text;v_entry_id uuid;
 cfg public.yt_loyalty_config%rowtype; v_today date:=(clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date;
begin
 if v_actor is null or exists(select 1 from public.work_accounts where auth_user_id=v_actor) then raise exception 'not_authenticated'; end if;
 perform pg_advisory_xact_lock(781943081);
 select * into v_pass from public.game_passes where id=p_pass for update;
 if not found or v_pass.customer_id<>v_actor then raise exception 'pass_not_owned'; end if;
 if v_pass.status='revoked' then raise exception 'pass_revoked';end if;
 if v_pass.status<>'claimed' or v_pass.expires_at<=clock_timestamp() then raise exception 'pass_expired_or_used';end if;
 select * into v_game from public.games where id=p_game;
 if not found or not v_game.active or v_game.mode not in ('chance','skill') then raise exception 'game_not_available'; end if;
 select * into v_existing from public.game_sessions where pass_id=p_pass;
 if found then
  if v_existing.status='cancelled' then raise exception 'pass_expired_or_used';end if;
  if v_existing.customer_id<>v_actor or v_existing.game_id<>p_game then raise exception 'pass_already_used'; end if;
  return query select v_existing.id,v_game.slug,v_existing.result_key,case when v_existing.status='started' then 'resumed' else v_existing.status end;
  return;
 end if;
 if v_pass.status<>'claimed' or v_pass.expires_at<=clock_timestamp() then raise exception 'pass_expired_or_used'; end if;
 if not exists(
  select 1 from public.campaign_games cg
  join public.campaigns c on c.id=cg.campaign_id
  where cg.campaign_id=v_pass.campaign_id and cg.game_id=p_game
  and c.active and (c.starts_at is null or c.starts_at<=now())
  and (c.ends_at is null or c.ends_at>now())
 ) then raise exception 'game_not_in_campaign'; end if;
 select * into cfg from public.yt_loyalty_config where id=true;
 if v_game.mode='skill' then
  insert into public.game_sessions(pass_id,customer_id,game_id,points_max_snapshot,reaction_perfect_snapshot,reaction_zero_snapshot,points_validity_snapshot) values(p_pass,v_actor,p_game,v_game.points_max,v_game.reaction_perfect_ms,v_game.reaction_zero_ms,cfg.points_validity_days) returning id into v_existing.id;
  update public.game_passes set selection='game' where id=p_pass;
  return query select v_existing.id,v_game.slug,null::text,'started'::text;return;
 end if;
 for v_entry in
  select e.* from public.reward_pool_entries e join public.rewards r on r.id=e.reward_id
  where e.campaign_id=v_pass.campaign_id and e.game_id=p_game and r.active and e.weight>0
  order by e.id for update of e
 loop
  if v_entry.max_total is not null and v_entry.issued_total>=v_entry.max_total then continue; end if;
  if v_entry.max_daily is not null and v_entry.issued_day=v_today and v_entry.issued_today>=v_entry.max_daily then continue; end if;
  v_total:=v_total+v_entry.weight;
  v_ids:=array_append(v_ids,v_entry.id);
  v_weights:=array_append(v_weights,v_entry.weight);
  v_rewards:=array_append(v_rewards,v_entry.reward_id);
  v_results:=array_append(v_results,v_entry.result_key);
 end loop;
 if v_total<1 then raise exception 'reward_pool_empty_or_sold_out'; end if;
 v_roll:=floor(random()*v_total)::integer+1;
 for v_idx in 1..array_length(v_ids,1) loop
  v_roll:=v_roll-v_weights[v_idx];
  if v_roll<=0 then
    v_entry_id:=v_ids[v_idx];v_choice:=v_rewards[v_idx];v_result:=v_results[v_idx];
    exit;
  end if;
 end loop;
 if v_entry_id is null then raise exception 'reward_pool_invalid'; end if;
 update public.reward_pool_entries set
   issued_total=issued_total+1,
   issued_today=case when issued_day=v_today then issued_today+1 else 1 end,
   issued_day=v_today
 where id=v_entry_id;
 insert into public.game_sessions(pass_id,customer_id,game_id,result_key,planned_reward_id)
 values(p_pass,v_actor,p_game,v_result,v_choice) returning id into v_existing.id;
 update public.game_sessions set points_equivalent_snapshot=(select points_equivalent from public.rewards where id=v_choice),points_validity_snapshot=cfg.points_validity_days where id=v_existing.id;
 update public.game_passes set selection='game' where id=p_pass;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id)
 values(v_actor,'game.start','game_session',v_existing.id);
 return query select v_existing.id,v_game.slug,v_result,'started'::text;
end $function$;
create or replace function private.yt_game_result(p_session uuid,p_score numeric default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.game_sessions%rowtype;p public.game_passes%rowtype;g public.games%rowtype;r public.rewards%rowtype;b public.yt_game_best_records%rowtype;v_score numeric;percent integer;rounds jsonb;
begin
 if auth.uid() is null or exists(select 1 from public.work_accounts where auth_user_id=auth.uid()) then raise exception 'customer_only';end if;
 perform pg_advisory_xact_lock(781943081);
 select * into s from public.game_sessions where id=p_session for update;
 if not found or s.customer_id<>auth.uid() then raise exception 'session_not_owned';end if;
 select * into p from public.game_passes where id=s.pass_id;
 if p.status='revoked' or s.status='cancelled' then raise exception 'pass_revoked';end if;
 select * into g from public.games where id=s.game_id;
 if s.status<>'completed' and (p.expires_at<=clock_timestamp() or s.started_at>clock_timestamp()-interval '2 seconds') then raise exception 'game_not_finished_or_expired';end if;
 if s.scored_at is null then
  if g.mode='skill' then
   rounds:=coalesce(s.progress->'rounds','[]');
   if jsonb_array_length(rounds)<>3 or s.progress->>'active_round' is not null then raise exception 'game_rounds_incomplete';end if;
   if g.slug='stop-the-bar' then select coalesce(max(value::numeric),0) into v_score from jsonb_array_elements_text(rounds);percent:=v_score::integer;
   elsif g.slug='reaction-test' then select min(value::numeric) into v_score from jsonb_array_elements_text(rounds) where value is not null;
    percent:=case when v_score is null then 0 else greatest(0,least(100,round(100*(s.reaction_zero_snapshot-v_score)/(s.reaction_zero_snapshot-s.reaction_perfect_snapshot))::integer)) end;
   else raise exception 'game_not_supported';end if;
  elsif g.slug='moon-dice' then
   v_score:=case s.result_key when 'R5' then 5 when 'R4' then 4 when 'R3' then 3 else p_score end;
   if v_score is null or v_score::text in('NaN','Infinity','-Infinity') or v_score<>trunc(v_score) or v_score not between 0 and 5 or (s.result_key='R0' and v_score>2) then raise exception 'invalid_game_score';end if;
  elsif g.slug in('mystery-card','mystery-box') then
   if s.progress->>'choice' is null then raise exception 'game_choice_required';end if;
   v_score:=case s.result_key when 'R5' then 5 when 'R4' then 4 when 'R3' then 3 else 1 end;
  else raise exception 'game_not_supported';end if;
  update public.game_sessions set score=v_score,achievement_percent=percent,scored_at=clock_timestamp() where id=s.id returning * into s;
  insert into public.yt_game_best_records(customer_id,game_id,best_score,played_count,best_at,last_played_at) values(s.customer_id,s.game_id,v_score,1,case when v_score is null then null else s.scored_at end,s.scored_at)
  on conflict(customer_id,game_id) do update set played_count=public.yt_game_best_records.played_count+1,last_played_at=excluded.last_played_at,
  best_at=case when excluded.best_score is not null and (public.yt_game_best_records.best_score is null or (g.slug='reaction-test' and excluded.best_score<public.yt_game_best_records.best_score) or (g.slug<>'reaction-test' and excluded.best_score>public.yt_game_best_records.best_score)) then excluded.best_at else public.yt_game_best_records.best_at end,
  best_score=case when excluded.best_score is not null and (public.yt_game_best_records.best_score is null or (g.slug='reaction-test' and excluded.best_score<public.yt_game_best_records.best_score) or (g.slug<>'reaction-test' and excluded.best_score>public.yt_game_best_records.best_score)) then excluded.best_score else public.yt_game_best_records.best_score end;
 end if;
 select * into r from public.rewards where id=s.planned_reward_id;
 select * into b from public.yt_game_best_records where customer_id=s.customer_id and game_id=s.game_id;
 return jsonb_build_object('session_id',s.id,'game_slug',g.slug,'mode',g.mode,'session_score',s.score,'achievement_percent',s.achievement_percent,'points_max',s.points_max_snapshot,'points',case when g.mode='skill' then floor(s.points_max_snapshot*s.achievement_percent::numeric/100)::integer else s.points_equivalent_snapshot end,'reward_name',r.name,'settlement_choice',s.settlement_choice,'status',s.status,'points_awarded',s.points_awarded,'personal_best',b.best_score,'played_count',b.played_count);
end $$;
create or replace function public.yt_game_result(p_session uuid,p_score numeric default null) returns jsonb language sql security invoker set search_path='' as $$select private.yt_game_result(p_session,p_score)$$;
revoke all on function private.yt_game_result(uuid,numeric),public.yt_game_result(uuid,numeric) from public,anon;
grant execute on function private.yt_game_result(uuid,numeric),public.yt_game_result(uuid,numeric) to authenticated;
