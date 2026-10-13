-- Attach Moon guest codes at the same atomic POS preorder submission as membership rewards.
CREATE OR REPLACE FUNCTION private.yt_pos_create_order_with_rewards_v2(p_request uuid, p_table text, p_note text, p_items jsonb, p_channel text, p_draft uuid, p_checkout_mode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare data jsonb;existing_mode text;moon_check jsonb;moon_attached jsonb;
begin
 if not private.yt_pos_work_staff() then raise exception 'staff_only';end if;
 if p_checkout_mode not in ('pay_now','pay_later') then raise exception 'invalid_checkout_mode';end if;
 moon_check:=private.yt_moon_preorder_summary(p_draft,p_items);
 if not coalesce((moon_check->>'can_submit')::boolean,false) then raise exception 'moon_preorder_not_ready';end if;
 data:=private.yt_pos_create_order_with_rewards(p_request,p_table,p_note,p_items,p_channel,p_draft);
 if not coalesce((data->>'idempotent')::boolean,false) then
  moon_attached:=private.yt_moon_preorder_attach(p_draft,(data->>'id')::uuid);
  data:=data||jsonb_build_object('moon_cart',moon_attached);
 end if;
 select checkout_mode into existing_mode from public.yt_member_orders where id=(data->>'id')::uuid for update;
 if (data->>'idempotent')::boolean and existing_mode<>p_checkout_mode then raise exception 'request_conflict';end if;
 update public.yt_member_orders set checkout_mode=p_checkout_mode where id=(data->>'id')::uuid;
 return data||jsonb_build_object('checkout_mode',p_checkout_mode);
end $function$
;