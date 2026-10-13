CREATE OR REPLACE FUNCTION private.yt_moon_preorder_summary(p_draft uuid, p_cart jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE original jsonb;rows jsonb:='[]'::jsonb;discount numeric:=0;bad int:=0;h record;balance numeric;gross numeric;paid int;reward_name text;
 r_mode text;r_type text;r_value numeric;r_min_drinks int;r_min_spend numeric;
BEGIN
 IF NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 original:=private.yt_pos_preorder_summary(p_draft,p_cart);gross:=coalesce((original->>'purchased_gross_rm')::numeric,0);paid:=coalesce((original->>'paid_drinks')::integer,0);
 FOR h IN SELECT ph.*,c.code,c.kind,c.reward_id,c.issued_on,c.valid_until,c.status code_status FROM public.yt_moon_preorder_holds ph JOIN public.yt_moon_guest_codes c ON c.id=ph.code_id
 WHERE ph.operator_id=auth.uid() AND ph.draft_id=p_draft AND ph.state='held' ORDER BY ph.created_at,ph.id LOOP
  reward_name:=NULL;r_mode:=NULL;
  SELECT r.name,rr.mode,rr.discount_type,rr.discount_value,rr.min_paid_drinks,rr.min_spend_rm
   INTO reward_name,r_mode,r_type,r_value,r_min_drinks,r_min_spend
   FROM public.rewards r JOIN public.yt_pos_reward_rules rr ON rr.reward_id=r.id AND rr.mode<>'disabled' WHERE r.id=h.reward_id AND r.active;
  IF h.expires_at<=clock_timestamp() OR h.code_status<>'available' OR h.issued_on>(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date OR h.valid_until<(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date
   OR reward_name IS NULL OR paid<r_min_drinks OR gross<r_min_spend OR (r_mode IN('product','series') AND h.product_id IS NULL) THEN bad:=bad+1;
  ELSIF r_mode='any_drink' THEN discount:=discount+CASE WHEN r_type='percent' THEN least(gross*r_value/100,gross) ELSE r_value END;END IF;
  rows:=rows||jsonb_build_array(jsonb_build_object('id',h.id,'source','moon','code',h.code,'state',CASE WHEN h.expires_at>clock_timestamp() AND h.code_status='available' THEN 'chosen' ELSE 'expired' END,'kind',h.kind,'reward_name',reward_name,'chosen_product_id',h.product_id,'chosen_product_name',h.drink_name,'discount_rm',CASE WHEN r_mode='any_drink' THEN CASE WHEN r_type='percent' THEN least(gross*r_value/100,gross) ELSE r_value END ELSE 0 END,'discount_type',CASE WHEN r_mode='any_drink' THEN r_type ELSE 'free' END,'valid',h.expires_at>clock_timestamp() AND h.code_status='available','expires_at',h.expires_at));
 END LOOP;
 balance:=greatest(0,(original->>'payable_rm')::numeric-discount);
 RETURN original||jsonb_build_object('moon_holds',rows,'holds',coalesce(original->'holds','[]'::jsonb)||rows,'reserved_discount_rm',(original->>'reserved_discount_rm')::numeric+discount,'payable_rm',balance,'unresolved_count',coalesce((original->>'unresolved_count')::int,0)+bad,'can_submit',coalesce((original->>'can_submit')::boolean,false) AND bad=0 AND (jsonb_array_length(rows)=0 OR (paid>=1 AND gross>=discount+0.01 AND balance>0)));
END;$function$
;