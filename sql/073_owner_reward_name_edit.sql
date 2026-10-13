CREATE OR REPLACE FUNCTION private.yt_owner_rename_reward(p_reward uuid, p_name text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_name text:=btrim(coalesce(p_name,''));v_old text;
BEGIN
 IF NOT private.yt_has_role('owner') OR NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'owner_only';END IF;
 IF p_reward IS NULL OR char_length(v_name) NOT BETWEEN 2 AND 120 THEN RAISE EXCEPTION 'invalid_reward_name';END IF;
 SELECT name INTO v_old FROM public.rewards WHERE id=p_reward FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'reward_not_found';END IF;
 UPDATE public.rewards SET name=v_name WHERE id=p_reward;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,metadata)
 VALUES(auth.uid(),'reward.name_updated','reward',p_reward,jsonb_build_object('old_name',v_old,'new_name',v_name));
 RETURN v_name;
END;$function$;

REVOKE ALL ON FUNCTION private.yt_owner_rename_reward(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.yt_owner_rename_reward(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.yt_owner_rename_reward(p_reward uuid, p_name text)
 RETURNS text
 LANGUAGE sql
 SET search_path TO ''
AS $function$ SELECT private.yt_owner_rename_reward(p_reward,p_name);$function$;

REVOKE ALL ON FUNCTION public.yt_owner_rename_reward(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.yt_owner_rename_reward(uuid,text) TO authenticated;