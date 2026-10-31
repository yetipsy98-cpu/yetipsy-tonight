-- Applied and verified on production; allow configured zero-purchase gifts.
ALTER TABLE public.yt_pos_preorder_holds DROP CONSTRAINT yt_pos_preorder_holds_min_paid_drinks_check;
ALTER TABLE public.yt_pos_preorder_holds ADD CONSTRAINT yt_pos_preorder_holds_min_paid_drinks_check CHECK (min_paid_drinks BETWEEN 0 AND 20);
DO $fix$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('private.yt_pos_draft_price(jsonb)'::regprocedure) INTO d;
 IF strpos(d,'OR jsonb_array_length(p_cart)<1')=0 THEN RAISE EXCEPTION 'Expected draft validation not found'; END IF;
 EXECUTE replace(d,'OR jsonb_array_length(p_cart)<1','');
END $fix$;
