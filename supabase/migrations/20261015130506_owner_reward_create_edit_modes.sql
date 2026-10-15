CREATE OR REPLACE FUNCTION private.yt_pos_owner_reward_rules()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
 IF NOT private.yt_has_role('owner') OR NOT private.yt_pos_work_staff() THEN
  RAISE EXCEPTION 'owner_only';
 END IF;
 RETURN coalesce((
  SELECT jsonb_agg(jsonb_build_object(
   'reward_id',r.id,'reward_name',r.name,'active',r.active,
   'description',r.description,'category',r.category,'validity_days',r.validity_days,
   'next_day_only',r.next_day_only,'redeem_start_at',r.redeem_start_at,
   'redeem_end_at',r.redeem_end_at,'daily_start_local',r.daily_start_local,
   'daily_end_local',r.daily_end_local,
   'mode',coalesce(rule.mode,'legacy'),'product_id',rule.product_id,
   'series_id',rule.series_id,'discount_type',coalesce(rule.discount_type,'free'),
   'discount_value',coalesce(rule.discount_value,0),
   'min_paid_drinks',coalesce(rule.min_paid_drinks,1),
   'min_spend_rm',coalesce(rule.min_spend_rm,0),'configured',rule.reward_id is not null,
   'updated_at',rule.updated_at
  ) ORDER BY r.name,r.id)
  FROM public.rewards r
  LEFT JOIN public.yt_pos_reward_rules rule ON rule.reward_id=r.id
 ),'[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION private.yt_owner_update_bound_reward_v1(
 p_reward uuid,p_reward_data jsonb,p_binding jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
 v_name text:=btrim(coalesce(p_reward_data->>'name',''));
 v_description text:=left(coalesce(p_reward_data->>'description',''),1000);
 v_category text:=coalesce(nullif(p_reward_data->>'category',''),'custom');
 v_validity int:=(p_reward_data->>'validity_days')::int;
 v_next_day boolean:=coalesce((p_reward_data->>'next_day_only')::boolean,true);
 v_use_from timestamptz:=nullif(p_reward_data->>'use_from','')::timestamptz;
 v_use_until timestamptz:=nullif(p_reward_data->>'use_until','')::timestamptz;
 v_daily_from time:=nullif(p_reward_data->>'daily_from','')::time;
 v_daily_until time:=nullif(p_reward_data->>'daily_until','')::time;
 v_mode text:=p_binding->>'mode';
 v_product uuid:=nullif(p_binding->>'product_id','')::uuid;
 v_series uuid:=nullif(p_binding->>'series_id','')::uuid;
 v_type text:=p_binding->>'discount_type';
 v_value numeric:=coalesce(nullif(p_binding->>'discount_value','')::numeric,0);
 v_min int:=coalesce(nullif(p_binding->>'min_paid_drinks','')::int,1);
 v_spend numeric:=coalesce(nullif(p_binding->>'min_spend_rm','')::numeric,0);
BEGIN
 IF auth.uid() IS NULL OR NOT private.yt_has_role('owner') OR NOT private.yt_pos_work_staff() THEN
  RAISE EXCEPTION 'owner_only';
 END IF;
 IF p_reward IS NULL OR jsonb_typeof(p_reward_data) IS DISTINCT FROM 'object'
    OR jsonb_typeof(p_binding) IS DISTINCT FROM 'object'
    OR char_length(v_name) NOT BETWEEN 2 AND 120 OR v_validity NOT BETWEEN 1 AND 365
    OR v_category NOT IN ('drink','voucher','gift','event','custom')
    OR ((v_daily_from IS NULL)<>(v_daily_until IS NULL))
    OR (v_use_from IS NOT NULL AND v_use_until IS NOT NULL AND v_use_until<=v_use_from) THEN
  RAISE EXCEPTION 'invalid_reward';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM public.rewards WHERE id=p_reward FOR UPDATE) THEN
  RAISE EXCEPTION 'reward_not_found';
 END IF;
 UPDATE public.rewards SET name=v_name,description=v_description,redeem_rules=v_description,
  category=v_category,validity_days=v_validity,next_day_only=v_next_day,
  redeem_start_at=v_use_from,redeem_end_at=v_use_until,
  daily_start_local=v_daily_from,daily_end_local=v_daily_until
 WHERE id=p_reward;
 PERFORM private.yt_pos_owner_save_reward_v43(
  p_reward,v_mode,v_product,v_series,v_type,v_value,v_min,v_spend
 );
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 VALUES(auth.uid(),'reward.update_bound','reward',p_reward,
  jsonb_build_object('category',v_category,'validity_days',v_validity,'mode',v_mode));
 RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.yt_owner_update_bound_reward_v1(
 p_reward uuid,p_reward_data jsonb,p_binding jsonb
)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $function$
 SELECT private.yt_owner_update_bound_reward_v1(p_reward,p_reward_data,p_binding);
$function$;

REVOKE ALL ON FUNCTION private.yt_owner_update_bound_reward_v1(uuid,jsonb,jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.yt_owner_update_bound_reward_v1(uuid,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.yt_owner_update_bound_reward_v1(uuid,jsonb,jsonb) TO authenticated;
NOTIFY pgrst,'reload schema';
