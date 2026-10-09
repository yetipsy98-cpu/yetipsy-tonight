-- Persist each skill attempt before settlement. A reload consumes an interrupted attempt;
-- completed attempts and a chance game's first choice are immutable.
create or replace function private.yt_game_checkpoint(p_session uuid,p_action text,p_round integer default null,p_score numeric default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.game_sessions%rowtype;p public.game_passes%rowtype;slug text;j jsonb;rounds jsonb;active integer;n integer;fail_value jsonb;
begin
 if auth.uid() is null then raise exception 'not_authenticated';end if;
 perform pg_advisory_xact_lock(781943081);
 select * into s from public.game_sessions where id=p_session for update;
 if not found or s.customer_id<>auth.uid() then raise exception 'session_not_owned';end if;
 select * into p from public.game_passes where id=s.pass_id;
 if p.status='revoked' then raise exception 'pass_revoked';end if;
 if s.status<>'started' or p.expires_at<=clock_timestamp() then raise exception 'pass_expired_or_used';end if;
 select g.slug into slug from public.games g where g.id=s.game_id;
 j:=s.progress;rounds:=coalesce(j->'rounds','[]'::jsonb);n:=jsonb_array_length(rounds);active:=nullif(j->>'active_round','')::integer;
 fail_value:=case when slug='reaction-test' then 'null'::jsonb else '0'::jsonb end;
 if p_action='resume' then
  if active is not null and slug in('reaction-test','stop-the-bar') then
   rounds:=rounds||jsonb_build_array(fail_value);j:=j||jsonb_build_object('rounds',rounds,'active_round',null);
  end if;
 elsif p_action='pick' then
  if slug not in('mystery-card','mystery-box') or p_round is null or p_round<1 or p_round>(case when slug='mystery-card' then 4 else 3 end) then raise exception 'invalid_game_choice';end if;
  if j ? 'choice' and (j->>'choice')::integer<>p_round then raise exception 'game_choice_locked';end if;
  j:=j||jsonb_build_object('choice',p_round);
 elsif p_action='begin' then
  if slug not in('reaction-test','stop-the-bar') or p_round is null or p_round<>n+1 or p_round not between 1 and 3 then raise exception 'game_round_locked';end if;
  if active is not null and active<>p_round then raise exception 'game_round_locked';end if;
  j:=j||jsonb_build_object('rounds',rounds,'active_round',p_round);
 elsif p_action='finish' then
  if slug not in('reaction-test','stop-the-bar') or p_round is null or p_round not between 1 and 3 then raise exception 'invalid_game_round';end if;
  if p_score is not null and (p_score::text in('NaN','Infinity','-Infinity') or p_score<>trunc(p_score) or (slug='reaction-test' and p_score not between 1 and 9000) or (slug='stop-the-bar' and p_score not between 0 and 100)) then raise exception 'invalid_game_score';end if;
  if p_round<=n then
   if rounds->(p_round-1) is distinct from coalesce(to_jsonb(p_score),'null'::jsonb) then raise exception 'game_round_locked';end if;
   return j;
  end if;
  if active is distinct from p_round or p_round<>n+1 then raise exception 'game_round_locked';end if;
  rounds:=rounds||jsonb_build_array(p_score);j:=j||jsonb_build_object('rounds',rounds,'active_round',null);
 else raise exception 'invalid_game_action';end if;
 update public.game_sessions set progress=j where id=s.id;
 return j;
end $$;
create or replace function public.yt_game_checkpoint(p_session uuid,p_action text,p_round integer default null,p_score numeric default null) returns jsonb language sql security invoker set search_path='' as $$select private.yt_game_checkpoint(p_session,p_action,p_round,p_score)$$;
revoke all on function private.yt_game_checkpoint(uuid,text,integer,numeric),public.yt_game_checkpoint(uuid,text,integer,numeric) from public,anon;
grant execute on function private.yt_game_checkpoint(uuid,text,integer,numeric),public.yt_game_checkpoint(uuid,text,integer,numeric) to authenticated;

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
 v_today date:=(clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date;
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
 insert into public.audit_logs(actor_id,action,entity_type,entity_id)
 values(v_actor,'game.start','game_session',v_existing.id);
 return query select v_existing.id,v_game.slug,v_result,'started'::text;
end $function$;

CREATE OR REPLACE FUNCTION private.yt_finish_game(p_session uuid)
 RETURNS TABLE(user_reward_id uuid, reward_name text, redeem_after timestamp with time zone, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor uuid:=auth.uid();v_session public.game_sessions%rowtype;
 v_reward public.rewards%rowtype;v_id uuid;v_after timestamptz;v_expires timestamptz;
begin
 if v_actor is null then raise exception 'not_authenticated'; end if;
 select * into v_session from public.game_sessions where id=p_session for update;
 if not found or v_session.customer_id<>v_actor then raise exception 'session_not_owned'; end if;
 if exists(select 1 from public.game_passes where id=v_session.pass_id and status='revoked') then raise exception 'pass_revoked';end if;
 if v_session.status='completed' then
   return query select w.id,r.name,w.redeem_after,w.expires_at
   from public.user_rewards w join public.rewards r on r.id=w.reward_id
   where w.session_id=p_session and w.customer_id=v_actor;
   return;
 end if;
 if exists(select 1 from public.game_passes gp where gp.id=v_session.pass_id and gp.expires_at<=clock_timestamp()) then raise exception 'pass_expired_or_used';end if;
 if v_session.status<>'started' or v_session.started_at>clock_timestamp()-interval '2 seconds'
 then raise exception 'game_not_finished'; end if;
 select * into v_reward from public.rewards where id=v_session.planned_reward_id;
 if not found then raise exception 'reward_missing'; end if;
 v_after:=case when v_reward.next_day_only then
 (((clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date+1)::timestamp at time zone 'Asia/Kuala_Lumpur')
 else clock_timestamp() end;
 v_expires:=clock_timestamp()+make_interval(days=>v_reward.validity_days);
 insert into public.user_rewards(customer_id,reward_id,session_id,redeem_after,expires_at)
 values(v_actor,v_reward.id,p_session,v_after,v_expires)
 on conflict(session_id) do nothing returning id into v_id;
 if v_id is null then select id into v_id from public.user_rewards
 where session_id=p_session and customer_id=v_actor;end if;
 if v_id is null then raise exception 'reward_not_issued'; end if;
 update public.game_sessions set status='completed',completed_at=clock_timestamp() where id=p_session;
 update public.game_passes set status='used',used_at=clock_timestamp() where id=v_session.pass_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id)
 values(v_actor,'game.finish','game_session',p_session);
 return query select v_id,v_reward.name,v_after,v_expires;
end;$function$;

CREATE OR REPLACE FUNCTION private.yt_finish_game_ranked(p_session uuid, p_score numeric DEFAULT NULL::numeric)
 RETURNS TABLE(user_reward_id uuid, reward_name text, redeem_after timestamp with time zone, expires_at timestamp with time zone, game_slug text, session_score numeric, personal_best numeric, played_count integer, personal_rank bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_actor uuid:=auth.uid(); v_session public.game_sessions%rowtype;
 v_slug text; v_score numeric; v_rows record;
 v_rounds jsonb;
 v_best public.yt_game_best_records%rowtype;
begin
 if v_actor is null then raise exception 'not_authenticated';end if;
 if exists(select 1 from public.work_accounts where auth_user_id=v_actor) then raise exception 'customer_only';end if;
 select * into v_session from public.game_sessions where id=p_session for update;
 if not found or v_session.customer_id<>v_actor then raise exception 'session_not_owned';end if;
 select slug into v_slug from public.games where id=v_session.game_id;
 if v_slug is null then raise exception 'game_not_found';end if;

 if exists(select 1 from public.game_passes where id=v_session.pass_id and status='revoked') then raise exception 'pass_revoked';end if;
 if v_session.scored_at is null then
  if p_score is not null and p_score::text in ('NaN','Infinity','-Infinity')
  then raise exception 'invalid_game_score';end if;
  if v_slug in ('mystery-card','mystery-box') then
   v_score:=case v_session.result_key when 'R5' then 5 when 'R4' then 4 when 'R3' then 3 else 1 end;
  elsif v_slug='moon-dice' then
   v_score:=case v_session.result_key when 'R5' then 5 when 'R4' then 4 when 'R3' then 3 else null end;
   if v_score is null then
    if p_score is null or p_score<>trunc(p_score) or p_score<0 or p_score>2
    then raise exception 'invalid_game_score';end if;
    v_score:=p_score;
   end if;
  elsif v_slug in ('reaction-test','stop-the-bar') then
   v_rounds:=coalesce(v_session.progress->'rounds','[]');
   if jsonb_array_length(v_rounds)<>3 or v_session.progress->>'active_round' is not null then raise exception 'game_rounds_incomplete';end if;
   if v_slug='reaction-test' then select min(value::numeric) into v_score from jsonb_array_elements_text(v_rounds) where value is not null;
   else select coalesce(max(value::numeric),0) into v_score from jsonb_array_elements_text(v_rounds);end if;
  else
   raise exception 'game_not_supported';
  end if;

  select * into v_rows from private.yt_finish_game(p_session);
  if not found then raise exception 'reward_settlement_failed';end if;
  update public.game_sessions set score=v_score,scored_at=clock_timestamp() where id=p_session;
  insert into public.yt_game_best_records(customer_id,game_id,best_score,played_count,best_at,last_played_at)
  values(v_actor,v_session.game_id,v_score,1,case when v_score is null then null else clock_timestamp() end,clock_timestamp())
  on conflict(customer_id,game_id) do update set
   played_count=public.yt_game_best_records.played_count+1,
   last_played_at=clock_timestamp(),
   best_at=case when excluded.best_score is not null and
     (public.yt_game_best_records.best_score is null or
      (v_slug='reaction-test' and excluded.best_score<public.yt_game_best_records.best_score) or
      (v_slug<>'reaction-test' and excluded.best_score>public.yt_game_best_records.best_score))
       then excluded.best_at else public.yt_game_best_records.best_at end,
   best_score=case when excluded.best_score is not null and
     (public.yt_game_best_records.best_score is null or
      (v_slug='reaction-test' and excluded.best_score<public.yt_game_best_records.best_score) or
      (v_slug<>'reaction-test' and excluded.best_score>public.yt_game_best_records.best_score))
       then excluded.best_score else public.yt_game_best_records.best_score end;
 else
  v_score:=v_session.score;
 end if;
 select * into v_best from public.yt_game_best_records
  where customer_id=v_actor and game_id=v_session.game_id;
 return query
 select w.id,r.name,w.redeem_after,w.expires_at,v_slug,v_score,v_best.best_score,v_best.played_count,
  (select ranking.pos from (
    select b.customer_id,row_number() over (order by
      case when v_slug='reaction-test' then b.best_score end asc nulls last,
      case when v_slug<>'reaction-test' then b.best_score end desc nulls last,
      b.best_at asc,b.customer_id) as pos
    from public.yt_game_best_records b
    where b.game_id=v_session.game_id and b.best_score is not null
   ) ranking where ranking.customer_id=v_actor)
 from public.user_rewards w join public.rewards r on r.id=w.reward_id
 where w.session_id=p_session and w.customer_id=v_actor;
end;$function$;
