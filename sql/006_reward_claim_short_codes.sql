-- Applied through Supabase MCP: reward_claim_short_codes_v5.
CREATE TABLE private.yt_offer_short_codes (
 offer_id uuid PRIMARY KEY REFERENCES public.reward_offers(id) ON DELETE CASCADE,
 code_hash text NOT NULL UNIQUE CHECK(length(code_hash)=64),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE private.yt_offer_short_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.yt_offer_short_codes FROM PUBLIC,anon,authenticated;
CREATE TABLE private.yt_offer_code_attempts (
 customer_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 window_started_at timestamptz NOT NULL,
 attempts integer NOT NULL CHECK(attempts BETWEEN 1 AND 21)
);
ALTER TABLE private.yt_offer_code_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.yt_offer_code_attempts FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.yt_create_offer_v5(p_reward uuid,p_token uuid,p_from timestamptz,p_until timestamptz,p_max integer,p_per_user integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_offer uuid;v_code text;v_bytes bytea;i int;j int;
 alphabet constant text:='23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
BEGIN
 IF auth.uid() IS NULL OR NOT private.yt_has_role('owner') THEN RAISE EXCEPTION 'owner_only';END IF;
 v_offer:=private.yt_create_offer(p_reward,p_token,p_from,p_until,p_max,p_per_user);
 FOR j IN 1..5 LOOP
  v_code:='';v_bytes:=extensions.gen_random_bytes(8);
  FOR i IN 0..7 LOOP v_code:=v_code||substr(alphabet,1+(get_byte(v_bytes,i)%32),1);END LOOP;
  BEGIN
   INSERT INTO private.yt_offer_short_codes(offer_id,code_hash)
   VALUES(v_offer,encode(sha256(convert_to(v_code,'UTF8')),'hex'));
   RETURN jsonb_build_object('offer_id',v_offer,'short_code',v_code,
    'display_code',substr(v_code,1,4)||'-'||substr(v_code,5,4),'expires_at',p_until);
  EXCEPTION WHEN unique_violation THEN NULL;END;
 END LOOP;
 RAISE EXCEPTION 'short_code_generation_failed';
END;$$;
CREATE FUNCTION public.yt_create_offer_v5(p_reward uuid,p_token uuid,p_from timestamptz,p_until timestamptz,p_max integer,p_per_user integer)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.yt_create_offer_v5(p_reward,p_token,p_from,p_until,p_max,p_per_user);
$$;
REVOKE ALL ON FUNCTION private.yt_create_offer_v5(uuid,uuid,timestamptz,timestamptz,integer,integer),public.yt_create_offer_v5(uuid,uuid,timestamptz,timestamptz,integer,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_create_offer_v5(uuid,uuid,timestamptz,timestamptz,integer,integer),public.yt_create_offer_v5(uuid,uuid,timestamptz,timestamptz,integer,integer) TO authenticated;
CREATE OR REPLACE FUNCTION private.yt_claim_offer_by_hash(p_hash text, p_request uuid)
 RETURNS TABLE(award_id uuid, reward_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor uuid:=auth.uid();v_offer public.reward_offers%rowtype;v_r public.rewards%rowtype;
 v_existing uuid;v_n integer;v_after timestamptz;v_expires timestamptz;v_award uuid;
begin
 if v_actor is null or p_hash is null or p_request is null then raise exception 'not_authenticated'; end if;
 select o.* into v_offer from public.reward_offers o
 where o.token_hash=p_hash for update;
 if not found then raise exception 'offer_not_found'; end if;
 select c.award_id into v_existing from public.reward_offer_claims c
 where c.offer_id=v_offer.id and c.customer_id=v_actor and c.request_id=p_request;
 if v_existing is not null then
   return query select w.id,r.name from public.user_rewards w join public.rewards r on r.id=w.reward_id where w.id=v_existing;
   return;
 end if;
 if not v_offer.active or v_offer.starts_at>clock_timestamp() or v_offer.ends_at<=clock_timestamp()
    or v_offer.claimed_count>=v_offer.max_claims then raise exception 'offer_unavailable'; end if;
 select count(*) into v_n from public.reward_offer_claims c where c.offer_id=v_offer.id and c.customer_id=v_actor;
 if v_n>=v_offer.per_user_limit then raise exception 'account_claim_limit'; end if;
 select * into v_r from public.rewards where id=v_offer.reward_id and active;
 if not found then raise exception 'reward_unavailable'; end if;
 v_after:=case when v_r.next_day_only then
  (((clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date+1)::timestamp at time zone 'Asia/Kuala_Lumpur')
  else clock_timestamp() end;
 v_expires:=clock_timestamp()+make_interval(days=>v_r.validity_days);
 insert into public.user_rewards(customer_id,reward_id,issued_by,redeem_after,expires_at,request_id)
 values(v_actor,v_r.id,v_offer.issued_by,v_after,v_expires,p_request)
 returning id into v_award;
 insert into public.reward_offer_claims(offer_id,customer_id,award_id,claim_no,request_id)
 values(v_offer.id,v_actor,v_award,v_n+1,p_request);
 update public.reward_offers set claimed_count=claimed_count+1 where id=v_offer.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(v_actor,'reward.offer_claim','user_reward',v_award);
 return query select v_award,v_r.name;
end $function$
;
REVOKE ALL ON FUNCTION private.yt_claim_offer_by_hash(text,uuid) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION private.yt_claim_offer(p_token uuid,p_request uuid)
RETURNS TABLE(award_id uuid,reward_name text) LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR p_token IS NULL OR p_request IS NULL THEN RAISE EXCEPTION 'not_authenticated';END IF;
 RETURN QUERY SELECT * FROM private.yt_claim_offer_by_hash(encode(sha256(convert_to(p_token::text,'UTF8')),'hex'),p_request);
END;$$;
CREATE FUNCTION private.yt_claim_offer_code(p_code text,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor uuid:=auth.uid();v_now timestamptz:=clock_timestamp();v_attempts int;v_code text;v_hash text;v_awards jsonb;
BEGIN
 IF actor IS NULL OR p_request IS NULL THEN RAISE EXCEPTION 'not_authenticated';END IF;
 INSERT INTO private.yt_offer_code_attempts AS a(customer_id,window_started_at,attempts)
 VALUES(actor,v_now,1) ON CONFLICT(customer_id) DO UPDATE SET
 attempts=CASE WHEN a.window_started_at<=v_now-interval '1 minute' THEN 1 ELSE least(a.attempts+1,21) END,
 window_started_at=CASE WHEN a.window_started_at<=v_now-interval '1 minute' THEN v_now ELSE a.window_started_at END
 RETURNING attempts INTO v_attempts;
 IF v_attempts>20 THEN RETURN jsonb_build_object('error_code','claim_code_rate_limited');END IF;
 v_code:=upper(regexp_replace(coalesce(p_code,''),'[[:space:]-]','','g'));
 IF v_code!~'^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$'
 THEN RETURN jsonb_build_object('error_code','claim_code_invalid');END IF;
 SELECT o.token_hash INTO v_hash FROM private.yt_offer_short_codes c JOIN public.reward_offers o ON o.id=c.offer_id
 WHERE c.code_hash=encode(sha256(convert_to(v_code,'UTF8')),'hex');
 IF NOT FOUND THEN RETURN jsonb_build_object('error_code','claim_code_invalid');END IF;
 BEGIN
  SELECT jsonb_agg(to_jsonb(a)) INTO v_awards FROM private.yt_claim_offer_by_hash(v_hash,p_request) a;
  RETURN jsonb_build_object('awards',coalesce(v_awards,'[]'::jsonb));
 EXCEPTION WHEN raise_exception THEN RETURN jsonb_build_object('error_code',SQLERRM);END;
END;$$;
CREATE FUNCTION public.yt_claim_offer_code(p_code text,p_request uuid)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.yt_claim_offer_code(p_code,p_request);$$;
REVOKE ALL ON FUNCTION private.yt_claim_offer_code(text,uuid),public.yt_claim_offer_code(text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_claim_offer_code(text,uuid),public.yt_claim_offer_code(text,uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
