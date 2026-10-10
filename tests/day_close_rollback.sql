-- Run only in a transaction that is rolled back.
do $$
declare owner_id uuid;cashier_id uuid;member_id uuid;product uuid;o uuid;request uuid:=gen_random_uuid();r jsonb;c jsonb;d date;before_cash numeric;f text;
begin
 select auth_user_id into owner_id from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 select auth_user_id into cashier_id from public.work_accounts where role='cashier' and active and not must_change_password limit 1;
 select auth_user_id into member_id from public.pin_accounts limit 1;
 if owner_id is null or cashier_id is null or member_id is null then raise exception 'fixture_missing';end if;
 if has_function_privilege('anon','public.yt_pos_day_statement_close(date,text,uuid,text)','execute') then raise exception 'public_close';end if;
 if has_function_privilege('authenticated','public.yt_pos_day_close(date,numeric,numeric,numeric,text,uuid,text)','execute') then raise exception 'legacy_cash_close_exposed';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member_id)::text,true);
 begin perform public.yt_pos_day_preview();raise exception 'expected_failure';exception when others then if sqlerrm<>'cashier_only' then raise;end if;end;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 -- Isolate aged blockers without deleting any records; all changes roll back.
 update public.yt_member_orders set created_at=now() where source='future_pos' and payment_status='unpaid' and status in ('pending','confirmed','fulfilled');
 insert into public.yt_business_cutoffs(effective_day,cutoff_minutes) values('2026-01-01',360),('2026-01-02',480);
 if private.yt_business_day(timestamptz '2026-01-02 07:59:59+08')<>date '2026-01-01' or private.yt_business_day(timestamptz '2026-01-02 08:00:00+08')<>date '2026-01-02' then raise exception 'cutoff_transition_wrong';end if;
 -- Restore default for current fixture date before reporting.
 insert into public.yt_business_cutoffs(effective_day,cutoff_minutes) values((now() at time zone 'Asia/Kuala_Lumpur')::date-1,360) on conflict(effective_day) do update set cutoff_minutes=360;
 d:=private.yt_business_day(now());r:=public.yt_pos_day_preview(d);before_cash:=(r#>>'{stats,cash_rm}')::numeric;
 insert into public.yt_shop_products(title,price_rm,active) values('rollback day close drink',20,true) returning id into product;
 insert into public.yt_member_orders(source,status,amount_rm,created_by,created_at) values('future_pos','confirmed',20,owner_id,now()-interval '73 hours') returning id into o;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) values(o,product,'rollback day close drink',1,20);
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',cashier_id)::text,true);
 begin perform public.yt_pos_action(o,'fulfilled');raise exception 'expected_failure';exception when others then if sqlerrm<>'aged_order_owner_required' then raise;end if;end;
 r:=public.yt_pos_day_preview(d);
 if (r->>'blocker_count')::integer<1 then raise exception 'blocker_missing';end if;
 begin perform public.yt_pos_day_statement_close(d,'rollback check',request,r->>'fingerprint');raise exception 'expected_failure';exception when others then if sqlerrm<>'aged_orders_block_day_close' then raise;end if;end;
 begin perform public.yt_pos_aged_resolve(o,'complete','already received','cash');raise exception 'expected_failure';exception when others then if sqlerrm<>'owner_only' then raise;end if;end;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 perform public.yt_pos_aged_resolve(o,'complete','verified receipt','cash');
 r:=public.yt_pos_day_preview(d);
 if (r#>>'{stats,cash_rm}')::numeric<>before_cash+20 then raise exception 'ledger_capture_wrong';end if;
 if not exists(select 1 from public.yt_pos_orders_day('paid',d,150) x,jsonb_array_elements(x) y where y->>'id'=o::text) then raise exception 'paid_day_filter_wrong';end if;
 if (r#>>'{stats,units}')::integer<1 or not exists(select 1 from jsonb_array_elements(r->'items') x where x->>'item_name'='rollback day close drink') then raise exception 'statement_items_missing';end if;
 f:=r->>'fingerprint';
 -- Prior day may already be closed in user data; reopen transactionally if needed.
 if r#>>'{closing,state}'='closed' then perform public.yt_pos_day_reopen(d,'rollback test');r:=public.yt_pos_day_preview(d);f:=r->>'fingerprint';end if;
 c:=public.yt_pos_day_statement_close(d,'verified pending orders',request,f);
 if c#>>'{snapshot,statement_version}'<>'2' or c#>>'{snapshot,stats,units}' is null then raise exception 'statement_snapshot_missing';end if;
 if public.yt_pos_day_statement_close(d,'verified pending orders',request,f)->>'id'<>c->>'id' then raise exception 'retry_not_idempotent';end if;
 begin perform public.yt_pos_day_statement_close(d,'different retry',request,f);raise exception 'expected_failure';exception when others then if sqlerrm<>'request_conflict' then raise;end if;end;
 insert into public.yt_member_orders(source,status,amount_rm,created_by) values('future_pos','fulfilled',20,owner_id) returning id into o;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) values(o,product,'rollback day close drink',1,20);
 perform public.yt_pos_action(o,'paid',null,'cash');
 r:=public.yt_pos_day_preview(d);if r#>>'{closing,state}'<>'reopened' then raise exception 'new_payment_must_reopen';end if;
 begin perform public.yt_pos_day_statement_close(d,'stale preview',gen_random_uuid(),f);raise exception 'expected_failure';exception when others then if sqlerrm<>'day_close_changed_reload' then raise;end if;end;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',cashier_id)::text,true);
 begin perform public.yt_business_cutoff_save(480);raise exception 'expected_failure';exception when others then if sqlerrm<>'owner_only' then raise;end if;end;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',owner_id)::text,true);
 c:=public.yt_business_cutoff_save(420);if c#>>'{next,effective_day}'<>(d+1)::text then raise exception 'cutoff_not_next_day';end if;
end $$;
