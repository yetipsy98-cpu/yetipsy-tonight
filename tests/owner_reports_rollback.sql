-- Explicit rollback only. The reporting RPC is read-only; fixture payments use temporary orders.
do $$
declare actor uuid; staff uuid; member uuid; start_date date:=date '2026-01-01'; finish_date date:=date '2026-01-02';
 o uuid; r jsonb; before_report jsonb; wanted numeric; expected_count bigint; product uuid;
begin
 select auth_user_id into actor from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 select auth_user_id into staff from public.work_accounts where role<>'owner' and active and not must_change_password limit 1;
 select auth_user_id into member from public.pin_accounts limit 1;
 if actor is null or member is null then raise exception 'fixture_missing';end if;
 if has_function_privilege('anon','public.yt_owner_report_v8(date,date,integer,text)','execute') then raise exception 'reports_exposed';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
 begin perform public.yt_owner_report_v8(start_date,finish_date);raise exception 'expected_failure';exception when others then if sqlerrm<>'owner_only' then raise;end if;end;
 if staff is not null then
  perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',staff)::text,true);
  begin perform public.yt_owner_report_v8(start_date,finish_date);raise exception 'expected_failure';exception when others then if sqlerrm<>'owner_only' then raise;end if;end;
 end if;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
 begin perform public.yt_owner_report_v8(finish_date,start_date);raise exception 'expected_failure';exception when others then if sqlerrm<>'invalid_report_range' then raise;end if;end;
 begin perform public.yt_owner_report_v8(start_date,start_date+366);raise exception 'expected_failure';exception when others then if sqlerrm<>'invalid_report_range' then raise;end if;end;
 begin perform public.yt_owner_report_v8(start_date,finish_date,0);raise exception 'expected_failure';exception when others then if sqlerrm<>'invalid_report_range' then raise;end if;end;
 before_report=public.yt_owner_report_v8(start_date,finish_date);
 insert into public.yt_shop_products(title,price_rm,active) values('rollback report drink',10,true) returning id into product;
 -- Created in December, paid on Malaysia Jan 1: reporting must follow paid_at.
 insert into public.yt_member_orders(source,status,amount_rm,created_by,created_at) values('future_pos','fulfilled',30,actor,timestamptz '2025-12-20 10:00:00+08') returning id into o;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) values(o,product,'rollback report drink',3,10);
 update public.yt_member_orders set payment_status='paid',paid_by=actor,payment_method='cash',paid_at=timestamptz '2025-12-31 16:30:00+00' where id=o;
 -- One second before the Malaysia start boundary: excluded.
 insert into public.yt_member_orders(source,status,amount_rm,created_by) values('future_pos','fulfilled',70,actor) returning id into o;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) values(o,product,'rollback report drink',7,10);
 update public.yt_member_orders set payment_status='paid',paid_by=actor,payment_method='cash',paid_at=timestamptz '2025-12-31 15:59:59+00' where id=o;
 -- Unpaid order inside the period: excluded from revenue.
 insert into public.yt_member_orders(source,status,amount_rm,created_by,created_at) values('future_pos','fulfilled',999,actor,timestamptz '2026-01-01 01:00:00+08');
 r=public.yt_owner_report_v8(start_date,finish_date);
 if (r#>>'{stats,range_amount}')::numeric<>(before_report#>>'{stats,range_amount}')::numeric+30 or (r#>>'{stats,range_orders}')::bigint<>(before_report#>>'{stats,range_orders}')::bigint+1 or (r#>>'{stats,range_items}')::numeric<>(before_report#>>'{stats,range_items}')::numeric+3 then raise exception 'payment_boundary_or_unpaid_count_wrong';end if;
 if not exists(select 1 from jsonb_array_elements(r->'days') x where x->>'day'='2026-01-01' and (x->>'amount_rm')::numeric>=30) then raise exception 'local_day_wrong';end if;
 if jsonb_array_length(r->'members')>40 or jsonb_array_length(r->'orders')>50 or jsonb_array_length(r->'products')>20 then raise exception 'report_unbounded';end if;
 if (r#>>'{member_stats,total}')::bigint<>(select count(*) from public.pin_accounts p where not exists(select 1 from public.work_accounts w where w.auth_user_id=p.auth_user_id)) then raise exception 'member_count_wrong';end if;
 r=public.yt_owner_report_v8(start_date,finish_date,1,'__no_member_matches_this_fixture__');if (r->>'member_filtered_total')::int<>0 or jsonb_array_length(r->'members')<>0 then raise exception 'member_search_wrong';end if;
 if r::text ~ '(token_hash|claim_token|access_token|refresh_token|password|birth_date)' then raise exception 'sensitive_auth_fields_leaked';end if;
end;$$;
