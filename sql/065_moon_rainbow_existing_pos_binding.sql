-- Reuse the existing configured Rainbow Shot POS reward for Moon R3.
CREATE OR REPLACE FUNCTION private.yt_moon_reward_name(p_kind text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path='' AS $function$
 SELECT CASE p_kind
  WHEN 'R0' THEN 'Yetipsy Lucky Box · RM5 Voucher'
  WHEN 'R3' THEN 'RAINBOW SHOT X1'
  WHEN 'R4' THEN 'Yetipsy Lucky Box · 指定微醺特调'
  WHEN 'R5' THEN 'Yetipsy Lucky Box · 指定经典鸡尾酒'
  ELSE NULL END
$function$;
