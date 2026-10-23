
ALTER TABLE public.yt_pos_reward_rules DROP CONSTRAINT IF EXISTS yt_pos_reward_rules_min_paid_drinks_check;
ALTER TABLE public.yt_pos_reward_rules ADD CONSTRAINT yt_pos_reward_rules_min_paid_drinks_check CHECK (min_paid_drinks >= 0 AND min_paid_drinks <= 20);
ALTER TABLE public.yt_pos_reward_holds DROP CONSTRAINT IF EXISTS yt_pos_reward_holds_min_paid_drinks_check;
ALTER TABLE public.yt_pos_reward_holds ADD CONSTRAINT yt_pos_reward_holds_min_paid_drinks_check CHECK (min_paid_drinks >= 0 AND min_paid_drinks <= 20);

DO $migration$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('private.yt_pos_owner_save_reward_v43(uuid,text,uuid,uuid,text,numeric,integer,numeric)'::regprocedure) INTO d;
 IF strpos(d,'p_min_drinks NOT BETWEEN 1 AND 20')=0 THEN RAISE EXCEPTION 'Expected owner reward minimum validation not found'; END IF;
 EXECUTE replace(d,'p_min_drinks NOT BETWEEN 1 AND 20','p_min_drinks NOT BETWEEN 0 AND 20');
END
$migration$;

DO $migration$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('private.yt_pos_order_minimum(uuid)'::regprocedure) INTO d;
 IF strpos(d,'greatest(1,coalesce(max(min_paid_drinks),1))')=0 OR strpos(d,'AND v>0')=0 THEN RAISE EXCEPTION 'Expected order minimum logic not found'; END IF;
 d:=replace(d,'greatest(1,coalesce(max(min_paid_drinks),1))','greatest(0,coalesce(max(min_paid_drinks),0))');
 d:=replace(d,'n>=needed AND v>=spend AND v>0','n>=needed AND v>=spend');
 EXECUTE d;
END
$migration$;

DO $migration$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('private.yt_pos_preorder_scan_by_hash(uuid,text,uuid,jsonb)'::regprocedure) INTO d;
 IF strpos(d,'IF v_drinks<1 THEN RAISE EXCEPTION ''minimum_one_paid_drink'';END IF;')=0 THEN RAISE EXCEPTION 'Expected POS scan minimum guard not found'; END IF;
 EXECUTE replace(d,'IF v_drinks<1 THEN RAISE EXCEPTION ''minimum_one_paid_drink'';END IF;','');
END
$migration$;

DO $migration$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('private.yt_pos_preorder_summary(uuid,jsonb)'::regprocedure) INTO d;
 IF strpos(d,'mins int:=1;spend numeric:=0;')=0 OR strpos(d,'net_drinks>=mins AND net_spend>=spend AND net_spend>0')=0 THEN RAISE EXCEPTION 'Expected POS cart summary minimum logic not found'; END IF;
 d:=replace(d,'mins int:=1;spend numeric:=0;','mins int:=0;spend numeric:=0;');
 d:=replace(d,'net_drinks>=mins AND net_spend>=spend AND net_spend>0','net_drinks>=mins AND net_spend>=spend AND (mins=0 OR net_spend>0)');
 EXECUTE d;
END
$migration$;

DO $migration$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('private.yt_pos_preorder_attach(uuid,uuid)'::regprocedure) INTO d;
 IF strpos(d,'AND paid<1')=0 OR strpos(d,'state=''chosen'')=0 THEN RAISE EXCEPTION 'Expected POS attach minimum guard not found'; END IF;
 d:=replace(d,'IF EXISTS(SELECT 1 FROM public.yt_pos_preorder_holds
 WHERE draft_id=p_draft AND operator_id=auth.uid() AND state=''chosen'') AND paid<1
 THEN RAISE EXCEPTION ''minimum_one_paid_drink'';END IF;','');
 EXECUTE d;
END
$migration$;

DO $migration$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('private.yt_moon_preorder_scan(uuid,text,jsonb,text)'::regprocedure) INTO d;
 IF strpos(d,'IF v_paid<1 OR v_gross<=0 THEN RAISE EXCEPTION ''minimum_one_paid_drink'';END IF;')=0 THEN RAISE EXCEPTION 'Expected Moon scan minimum guard not found'; END IF;
 EXECUTE replace(d,'IF v_paid<1 OR v_gross<=0 THEN RAISE EXCEPTION ''minimum_one_paid_drink'';END IF;','');
END
$migration$;

DO $migration$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('private.yt_moon_preorder_summary(uuid,jsonb)'::regprocedure) INTO d;
 IF strpos(d,'paid>=1 AND gross>=discount+0.01 AND balance>0')=0 THEN RAISE EXCEPTION 'Expected Moon summary minimum logic not found'; END IF;
 d:=replace(d,
  'paid>=1 AND gross>=discount+0.01 AND balance>0',
  'paid>=1 AND gross>=discount+0.01 AND balance>0 OR (paid=0 AND gross=0 AND jsonb_array_length(rows)>0 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(rows) AS x(value) WHERE x.value->>''discount_type''<>''free'' OR NOT coalesce((x.value->>''valid'')::boolean,false) OR nullif(x.value->>''chosen_product_name'','''') IS NULL))');
 EXECUTE d;
END
$migration$;

DO $migration$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('private.yt_moon_preorder_attach(uuid,uuid)'::regprocedure) INTO d;
 IF strpos(d,'IF paid_drinks<1 THEN RAISE EXCEPTION ''minimum_one_paid_drink'';END IF;')=0 THEN RAISE EXCEPTION 'Expected Moon attach minimum guard not found'; END IF;
 EXECUTE replace(d,'IF paid_drinks<1 THEN RAISE EXCEPTION ''minimum_one_paid_drink'';END IF;','');
END
$migration$;

DO $migration$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('private.yt_pos_create_order(uuid,text,text,jsonb,text)'::regprocedure) INTO d;
 IF strpos(d,'or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>30')=0 THEN RAISE EXCEPTION 'Expected empty-order validation not found'; END IF;
 EXECUTE replace(d,
  'or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>30',
  'or (jsonb_array_length(p_items)<1 and coalesce(current_setting(''yt.pos.allow_empty_order'',true),'''')<>''on'') or jsonb_array_length(p_items)>30');
END
$migration$;

DO $migration$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('private.yt_pos_create_order_with_rewards(uuid,text,text,jsonb,text,uuid)'::regprocedure) INTO d;
 IF strpos(d,'data jsonb;detail jsonb;prior private.yt_pos_draft_submissions%rowtype;hash text;')=0
  OR strpos(d,'data:=private.yt_pos_create_order(p_request,p_table,p_note,p_items,p_channel);')=0 THEN
  RAISE EXCEPTION 'Expected reward order creation wrapper not found';
 END IF;
 d:=replace(d,
  'data jsonb;detail jsonb;prior private.yt_pos_draft_submissions%rowtype;hash text;',
  'data jsonb;detail jsonb;prior private.yt_pos_draft_submissions%rowtype;hash text;v_summary jsonb;');
 d:=replace(d,
  'data:=private.yt_pos_create_order(p_request,p_table,p_note,p_items,p_channel);',
  'if jsonb_array_length(p_items)=0 then
  v_summary:=private.yt_moon_preorder_summary(p_draft,p_items);
  if not coalesce((v_summary->>''can_submit'')::boolean,false) then raise exception ''minimum_purchase_not_met'';end if;
  if not exists(select 1 from jsonb_array_elements(coalesce(v_summary->''holds'',''[]''::jsonb)) as h(value)
    where h.value->>''state''=''chosen'' and h.value->>''discount_type''=''free''
      and coalesce((h.value->>''valid'')::boolean,false))
    or exists(select 1 from jsonb_array_elements(coalesce(v_summary->''holds'',''[]''::jsonb)) as h(value)
      where h.value->>''state'' is distinct from ''chosen'' or h.value->>''discount_type'' is distinct from ''free''
        or not coalesce((h.value->>''valid'')::boolean,false)) then
    raise exception ''minimum_purchase_not_met'';
  end if;
  perform set_config(''yt.pos.allow_empty_order'',''on'',true);
 end if;
 data:=private.yt_pos_create_order(p_request,p_table,p_note,p_items,p_channel);
 if jsonb_array_length(p_items)=0 then perform set_config(''yt.pos.allow_empty_order'',''off'',true);end if;');
 EXECUTE d;
END
$migration$;
