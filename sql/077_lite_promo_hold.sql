-- Hold only new-user promotions for fifth+ linked accounts; no change to earned points.
CREATE TABLE IF NOT EXISTS public.yt_lite_held_promos (
 customer_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 kind text NOT NULL CHECK(kind IN ('welcome','friend')),
 source_customer_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 reward_id uuid NOT NULL REFERENCES public.rewards(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 released_at timestamptz,
 PRIMARY KEY(customer_id,kind,source_customer_id)
);
ALTER TABLE public.yt_lite_held_promos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.yt_lite_held_promos FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION private.yt_award_promo(p_recipient uuid, p_kind text, p_source uuid, p_reward uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.rewards%rowtype; v_wallet uuid; v_start timestamptz; v_end timestamptz;
begin
 if p_recipient is null or p_source is null or p_reward is null then return false;end if;
 if p_kind not in ('welcome','friend','inviter') then raise exception 'invalid_promo';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_recipient::text||p_kind||p_source::text,0));
 if exists(select 1 from public.yt_promo_grants where customer_id=p_recipient and kind=p_kind and source_customer_id=p_source)
 then return false;end if;
 -- New-user promotions only: 5+ associated accounts require Owner release.
 if p_kind in ('welcome','friend') and
    not exists(select 1 from public.yt_lite_owner_reviews where user_id=p_recipient) and
    exists(
      select 1 from public.yt_lite_device_links me
      join public.yt_lite_device_links other on other.device_digest=me.device_digest
      where me.user_id=p_recipient
      group by me.device_digest having count(distinct other.user_id)>=5
    )
 then
   insert into public.yt_lite_held_promos(customer_id,kind,source_customer_id,reward_id)
   values(p_recipient,p_kind,p_source,p_reward)
   on conflict(customer_id,kind,source_customer_id) do nothing;
   return false;
 end if;
 select * into r from public.rewards where id=p_reward and active;
 if not found then return false;end if;
 if not exists(select 1 from public.pin_accounts where auth_user_id=p_recipient)
  or exists(select 1 from public.work_accounts where auth_user_id=p_recipient)
 then raise exception 'customer_only';end if;
 v_start:=greatest(
   clock_timestamp(),
   case when r.next_day_only then
      (((clock_timestamp() at time zone 'Asia/Kuala_Lumpur')::date+1)::timestamp at time zone 'Asia/Kuala_Lumpur')
     else clock_timestamp() end,
   coalesce(r.redeem_start_at,clock_timestamp())
 );
 v_end:=least(clock_timestamp()+make_interval(days=>r.validity_days),
              coalesce(r.redeem_end_at,'infinity'::timestamptz));
 if v_end<=v_start then return false;end if;
 insert into public.user_rewards(customer_id,reward_id,redeem_after,expires_at)
 values(p_recipient,r.id,v_start,v_end) returning id into v_wallet;
 insert into public.yt_promo_grants(customer_id,kind,source_customer_id,reward_id,user_reward_id)
 values(p_recipient,p_kind,p_source,r.id,v_wallet);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 values(p_recipient,'loyalty.'||p_kind,'user_reward',v_wallet,jsonb_build_object('source_user_id',p_source));
 return true;
end;$function$

