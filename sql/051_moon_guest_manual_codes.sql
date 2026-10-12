
-- Moon guest codes: independent of membership. No records inserted by migration.
CREATE TABLE public.yt_moon_guest_codes(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 code text NOT NULL UNIQUE CHECK(code ~ '^YT-MOON-[A-Z0-9]{8}$'),
 kind text NOT NULL CHECK(kind IN ('R5','R4','R3','R0')),
 issued_on date NOT NULL,valid_until date NOT NULL,
 status text NOT NULL DEFAULT 'available' CHECK(status IN ('available','reserved','redeemed')),
 legacy_used boolean NOT NULL DEFAULT false,
 notes text NOT NULL DEFAULT '',
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 created_by uuid,reserved_order_id uuid,reserved_item_id uuid,
 redeemed_order_id uuid,redeemed_at timestamptz,redeemed_by uuid,
 CHECK(valid_until>=issued_on),CHECK(length(notes)<=300)
);
CREATE INDEX yt_moon_guest_reserved_idx ON public.yt_moon_guest_codes(reserved_order_id) WHERE status='reserved';
ALTER TABLE public.yt_moon_guest_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.yt_moon_guest_codes FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.yt_moon_norm(p text) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $$
DECLARE c text;
BEGIN
 c:=upper(regexp_replace(coalesce(p,''),'[^a-zA-Z0-9]','','g'));
 IF c~'^[A-Z0-9]{8}$' THEN c:='YTMOON'||c;END IF;
 IF c!~'^YTMOON[A-Z0-9]{8}$' THEN RAISE EXCEPTION 'moon_invalid_code';END IF;
 RETURN 'YT-MOON-'||substring(c FROM 7);
END;$$;
CREATE FUNCTION private.yt_moon_owner_add(p_code text,p_kind text,p_issued date,p_until date,p_used boolean DEFAULT false,p_note text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c text;v uuid;
BEGIN
 IF NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only';END IF;
 IF p_kind NOT IN('R5','R4','R3','R0') OR p_issued IS NULL OR p_until IS NULL
 OR p_until<p_issued OR p_until>p_issued+365 OR length(coalesce(p_note,''))>300
 THEN RAISE EXCEPTION 'moon_invalid_details';END IF;
 c:=private.yt_moon_norm(p_code);
 INSERT INTO public.yt_moon_guest_codes(code,kind,issued_on,valid_until,legacy_used,status,notes,created_by,redeemed_at)
 VALUES(c,p_kind,p_issued,p_until,coalesce(p_used,false),CASE WHEN p_used THEN 'redeemed' ELSE 'available' END,
 coalesce(p_note,''),auth.uid(),CASE WHEN p_used THEN clock_timestamp() ELSE NULL END)
 ON CONFLICT(code) DO NOTHING RETURNING id INTO v;
 IF v IS NULL THEN RAISE EXCEPTION 'moon_duplicate_code';END IF;
 RETURN jsonb_build_object('id',v,'code',c,'kind',p_kind);
END;$$;
CREATE FUNCTION private.yt_moon_owner_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v jsonb;
BEGIN
 IF NOT private.yt_work_owner() THEN RAISE EXCEPTION 'owner_only';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'code',code,'kind',kind,
 'issued',issued_on,'until',valid_until,'status',status,'order',coalesce(reserved_order_id,redeemed_order_id))
 ORDER BY created_at DESC),'[]'::jsonb) INTO v
 FROM (SELECT * FROM public.yt_moon_guest_codes ORDER BY created_at DESC LIMIT 500) sub;
 RETURN v;
END;$$;
CREATE FUNCTION private.yt_moon_lookup(p_order uuid,p_code text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.yt_member_orders%rowtype;v public.yt_moon_guest_codes%rowtype;
BEGIN
 IF NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 SELECT * INTO o FROM public.yt_member_orders WHERE id=p_order AND source='future_pos';
 IF NOT FOUND OR o.payment_status<>'unpaid' OR o.status NOT IN ('confirmed','fulfilled')
 THEN RAISE EXCEPTION 'redeem_order_not_ready';END IF;
 SELECT * INTO v FROM public.yt_moon_guest_codes WHERE code=private.yt_moon_norm(p_code);
 IF NOT FOUND THEN RAISE EXCEPTION 'moon_code_not_found';END IF;
 IF v.status='redeemed' THEN RAISE EXCEPTION 'moon_already_redeemed';END IF;
 IF v.status='reserved' AND v.reserved_order_id<>p_order THEN RAISE EXCEPTION 'moon_reserved_elsewhere';END IF;
 IF v.valid_until<(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date THEN RAISE EXCEPTION 'moon_expired';END IF;
 IF v.issued_on>(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date THEN RAISE EXCEPTION 'moon_not_started';END IF;
 RETURN jsonb_build_object('id',v.id,'kind',v.kind,'code',v.code,'until',v.valid_until,'status',v.status);
END;$$;
CREATE FUNCTION private.yt_moon_reserve(p_order uuid,p_code text,p_drink text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.yt_member_orders%rowtype;v public.yt_moon_guest_codes%rowtype;item uuid;drink text;discount numeric;
BEGIN
 IF NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('moon:'||private.yt_moon_norm(p_code),0));
 SELECT * INTO o FROM public.yt_member_orders WHERE id=p_order AND source='future_pos' FOR UPDATE;
 IF NOT FOUND OR o.payment_status<>'unpaid' OR o.status NOT IN ('confirmed','fulfilled') THEN RAISE EXCEPTION 'redeem_order_not_ready';END IF;
 SELECT * INTO v FROM public.yt_moon_guest_codes WHERE code=private.yt_moon_norm(p_code) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'moon_code_not_found';END IF;
 IF v.status='redeemed' THEN RAISE EXCEPTION 'moon_already_redeemed';END IF;
 IF v.status='reserved' THEN
   IF v.reserved_order_id=p_order THEN RETURN jsonb_build_object('id',v.id,'kind',v.kind,'idempotent',true);END IF;
   RAISE EXCEPTION 'moon_reserved_elsewhere';
 END IF;
 IF v.valid_until<(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date THEN RAISE EXCEPTION 'moon_expired';END IF;
 IF v.issued_on>(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date THEN RAISE EXCEPTION 'moon_not_started';END IF;
 IF NOT (private.yt_pos_order_minimum(p_order)->>'minimum_met')::boolean THEN RAISE EXCEPTION 'minimum_one_paid_drink';END IF;
 IF v.kind IN ('R5','R4','R3') THEN
  drink:=CASE WHEN v.kind='R3' THEN '彩虹 Shot' ELSE btrim(coalesce(p_drink,'')) END;
  IF length(drink)<2 OR length(drink)>110 THEN RAISE EXCEPTION 'moon_drink_required';END IF;
  INSERT INTO public.yt_member_order_items(order_id,item_name,quantity,unit_price_rm,is_drink_at_order)
  VALUES(p_order,drink||' · Moon 赠品',1,0,false) RETURNING id INTO item;
  INSERT INTO public.yt_pos_item_units(order_item_id,unit_number) VALUES(item,1);
  UPDATE public.yt_member_orders SET status='confirmed',updated_at=clock_timestamp() WHERE id=p_order;
  INSERT INTO public.yt_pos_order_chits(order_id) VALUES(p_order)
  ON CONFLICT(order_id) DO UPDATE SET status='queued',issued_at=clock_timestamp(),printed_at=NULL,printed_by=NULL;
 ELSIF o.amount_rm<=5 THEN RAISE EXCEPTION 'moon_minimum_payable';END IF;
 UPDATE public.yt_moon_guest_codes SET status='reserved',reserved_order_id=p_order,reserved_item_id=item WHERE id=v.id;
 RETURN jsonb_build_object('id',v.id,'kind',v.kind,'drink',drink,'discount',CASE WHEN v.kind='R0' THEN 5 ELSE 0 END);
END;$$;
CREATE FUNCTION private.yt_moon_release(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v public.yt_moon_guest_codes%rowtype;o public.yt_member_orders%rowtype;
BEGIN
 IF NOT private.yt_pos_work_staff() THEN RAISE EXCEPTION 'staff_only';END IF;
 SELECT * INTO v FROM public.yt_moon_guest_codes WHERE id=p_id FOR UPDATE;
 IF NOT FOUND OR v.status<>'reserved' THEN RAISE EXCEPTION 'moon_reservation_not_found';END IF;
 SELECT * INTO o FROM public.yt_member_orders WHERE id=v.reserved_order_id FOR UPDATE;
 IF NOT FOUND OR o.payment_status<>'unpaid' OR o.status NOT IN ('confirmed','pending') THEN RAISE EXCEPTION 'moon_release_unavailable';END IF;
 IF v.reserved_item_id IS NOT NULL THEN
  DELETE FROM public.yt_pos_item_units WHERE order_item_id=v.reserved_item_id;
  DELETE FROM public.yt_member_order_items WHERE id=v.reserved_item_id AND order_id=o.id;
  UPDATE public.yt_pos_order_chits SET status='queued',issued_at=clock_timestamp(),printed_at=NULL,printed_by=NULL WHERE order_id=o.id;
 END IF;
 UPDATE public.yt_moon_guest_codes SET status='available',reserved_order_id=NULL,reserved_item_id=NULL WHERE id=v.id;
 RETURN jsonb_build_object('ok',true);
END;$$;
CREATE FUNCTION private.yt_moon_on_checkout()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NEW.source<>'future_pos' THEN RETURN NEW;END IF;
 IF OLD.payment_status='unpaid' AND NEW.payment_status='paid' THEN
  IF EXISTS(SELECT 1 FROM public.yt_moon_guest_codes
     WHERE status='reserved' AND reserved_order_id=NEW.id AND valid_until<(clock_timestamp() AT TIME ZONE 'Asia/Kuala_Lumpur')::date)
  THEN RAISE EXCEPTION 'moon_expired';END IF;
  UPDATE public.yt_moon_guest_codes
  SET status='redeemed',redeemed_at=clock_timestamp(),redeemed_order_id=NEW.id,redeemed_by=NEW.paid_by
  WHERE status='reserved' AND reserved_order_id=NEW.id;
 ELSIF OLD.status<>'cancelled' AND NEW.status='cancelled' AND OLD.payment_status='unpaid' THEN
  UPDATE public.yt_moon_guest_codes SET status='available',reserved_order_id=NULL,reserved_item_id=NULL
  WHERE status='reserved' AND reserved_order_id=NEW.id;
 END IF;
 RETURN NEW;
END;$$;
CREATE TRIGGER yt_moon_checkout_after AFTER UPDATE OF payment_status,status ON public.yt_member_orders
FOR EACH ROW EXECUTE FUNCTION private.yt_moon_on_checkout();
CREATE FUNCTION public.yt_moon_owner_add(p_code text,p_kind text,p_issued date,p_until date,p_used boolean DEFAULT false,p_note text DEFAULT '')
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.yt_moon_owner_add(p_code,p_kind,p_issued,p_until,p_used,p_note);$$;
CREATE FUNCTION public.yt_moon_owner_list() RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.yt_moon_owner_list();$$;
CREATE FUNCTION public.yt_moon_lookup(p_order uuid,p_code text) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.yt_moon_lookup(p_order,p_code);$$;
CREATE FUNCTION public.yt_moon_reserve(p_order uuid,p_code text,p_drink text DEFAULT NULL) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.yt_moon_reserve(p_order,p_code,p_drink);$$;
CREATE FUNCTION public.yt_moon_release(p_id uuid) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.yt_moon_release(p_id);$$;
REVOKE ALL ON FUNCTION private.yt_moon_owner_add(text,text,date,date,boolean,text),private.yt_moon_owner_list(),private.yt_moon_lookup(uuid,text),private.yt_moon_reserve(uuid,text,text),private.yt_moon_release(uuid),
 public.yt_moon_owner_add(text,text,date,date,boolean,text),public.yt_moon_owner_list(),public.yt_moon_lookup(uuid,text),public.yt_moon_reserve(uuid,text,text),public.yt_moon_release(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.yt_moon_owner_add(text,text,date,date,boolean,text),private.yt_moon_owner_list(),private.yt_moon_lookup(uuid,text),private.yt_moon_reserve(uuid,text,text),private.yt_moon_release(uuid),
 public.yt_moon_owner_add(text,text,date,date,boolean,text),public.yt_moon_owner_list(),public.yt_moon_lookup(uuid,text),public.yt_moon_reserve(uuid,text,text),public.yt_moon_release(uuid) TO authenticated;
