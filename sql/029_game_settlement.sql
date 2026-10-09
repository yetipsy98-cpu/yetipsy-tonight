create or replace function private.yt_game_settle(p_session uuid,p_choice text) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.game_sessions%rowtype;p public.game_passes%rowtype;g public.games%rowtype;r public.rewards%rowtype;n integer;b bigint;award uuid;after_time timestamptz;expiry timestamptz;result jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.pin_accounts where auth_user_id=auth.uid()) or exists(select 1 from public.work_accounts where auth_user_id=auth.uid()) then raise exception 'customer_only';end if;
 if p_choice is null or p_choice not in('reward','points') then raise exception 'invalid_settlement_choice';end if;
 perform pg_advisory_xact_lock(781943081);
 select * into s from public.game_sessions where id=p_session for update;
 if not found or s.customer_id<>auth.uid() then raise exception 'session_not_owned';end if;
 select * into p from public.game_passes where id=s.pass_id for update;
 if p.status='revoked' or s.status='cancelled' then raise exception 'pass_revoked';end if;
 if s.settlement_choice is not null then
  if s.settlement_choice<>p_choice then raise exception 'game_settlement_locked';end if;
  select id into award from public.user_rewards where session_id=s.id;
  b:=private.yt_points_sync(s.customer_id);
  return jsonb_build_object('session_id',s.id,'choice',s.settlement_choice,'points',s.points_awarded,'reward_id',award,'balance',b,'idempotent',true);
 end if;
 if s.status<>'started' or p.status<>'claimed' or p.expires_at<=clock_timestamp() then raise exception 'pass_expired_or_used';end if;
 if s.scored_at is null then raise exception 'game_result_required';end if;
 select * into g from public.games where id=s.game_id;
 if g.mode='skill' and p_choice<>'points' then raise exception 'skill_points_only';end if;
 if p_choice='points' then
  n:=case when g.mode='skill' then floor(s.points_max_snapshot*s.achievement_percent::numeric/100)::integer else s.points_equivalent_snapshot end;
  if n is null then raise exception 'reward_points_not_configured';end if;
  if n not between 0 and 1000000 then raise exception 'invalid_game_points';end if;
  b:=private.yt_points_sync(s.customer_id);
  expiry:=case when s.points_validity_snapshot>0 then clock_timestamp()+make_interval(days=>s.points_validity_snapshot) else null end;
  insert into public.yt_point_entries(customer_id,game_pass_id,direction,points,reference,max_budget_points,remaining_points,expires_at,source) values(s.customer_id,s.pass_id,'earn',n,'GAME:'||s.id::text,case when g.mode='skill' then s.points_max_snapshot else n end,n,expiry,'game_points');
  update public.yt_point_wallets set balance=balance+n,lifetime_earned=lifetime_earned+n,updated_at=clock_timestamp() where customer_id=s.customer_id returning balance into b;
 else
  select * into r from public.rewards where id=s.planned_reward_id;
  if not found then raise exception 'reward_missing';end if;
  after_time:=case when r.next_day_only then (((clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date+1)::timestamp at time zone 'Asia/Kuala_Lumpur') else clock_timestamp() end;
  expiry:=clock_timestamp()+make_interval(days=>r.validity_days);
 after_time:=greatest(after_time,coalesce(r.redeem_start_at,after_time));expiry:=least(expiry,coalesce(r.redeem_end_at,expiry));if expiry<=after_time then raise exception 'reward_no_valid_window';end if;
  insert into public.user_rewards(customer_id,reward_id,session_id,redeem_after,expires_at) values(s.customer_id,r.id,s.id,after_time,expiry) returning id into award;
 end if;
 update public.game_sessions set status='completed',completed_at=clock_timestamp(),settlement_choice=p_choice,points_awarded=coalesce(n,0) where id=s.id;
 update public.game_passes set status='used',used_at=clock_timestamp(),selection=case when p_choice='points' then 'points' else 'game' end where id=p.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata) values(auth.uid(),'game.settle','game_session',s.id,jsonb_build_object('choice',p_choice,'points',n,'reward',award));
 return jsonb_build_object('session_id',s.id,'choice',p_choice,'points',coalesce(n,0),'reward_id',award,'balance',b,'expires_at',expiry,'idempotent',false);
end $$;
create or replace function public.yt_game_settle(p_session uuid,p_choice text) returns jsonb language sql security invoker set search_path='' as $$select private.yt_game_settle(p_session,p_choice)$$;
revoke all on function private.yt_game_settle(uuid,text),public.yt_game_settle(uuid,text) from public,anon;
grant execute on function private.yt_game_settle(uuid,text),public.yt_game_settle(uuid,text) to authenticated;
-- Obsolete callers cannot skip playing or grant a reward before the settlement choice.
create or replace function private.yt_claim_random_points(p_pass uuid) returns table(points_awarded integer,new_balance bigint,limit_points integer) language plpgsql security definer set search_path='' as $$begin raise exception 'points_after_game_only';end $$;
create or replace function private.yt_point_pass_quote(p_pass uuid) returns jsonb language plpgsql security definer set search_path='' as $$begin raise exception 'points_after_game_only';end $$;
create or replace function private.yt_finish_game(p_session uuid) returns table(user_reward_id uuid,reward_name text,redeem_after timestamptz,expires_at timestamptz) language plpgsql security definer set search_path='' as $$begin if exists(select 1 from public.game_sessions s join public.game_passes p on p.id=s.pass_id where s.id=p_session and s.customer_id=auth.uid() and p.status='revoked') then raise exception 'pass_revoked';end if;raise exception 'use_game_settlement';end $$;
create or replace function private.yt_finish_game_ranked(p_session uuid,p_score numeric default null) returns table(user_reward_id uuid,reward_name text,redeem_after timestamptz,expires_at timestamptz,game_slug text,session_score numeric,personal_best numeric,played_count integer,personal_rank bigint) language plpgsql security definer set search_path='' as $$begin if exists(select 1 from public.game_sessions s join public.game_passes p on p.id=s.pass_id where s.id=p_session and s.customer_id=auth.uid() and p.status='revoked') then raise exception 'pass_revoked';end if;raise exception 'use_game_settlement';end $$;
