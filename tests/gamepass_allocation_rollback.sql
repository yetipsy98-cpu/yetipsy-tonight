-- Explicit transaction rollback only. Never call Auth/Storage APIs during validation.
do $$
declare actor uuid; member uuid; series uuid; product uuid; o uuid; item uuid; unsupported uuid; campaign uuid;
 token uuid:=gen_random_uuid(); req uuid:=gen_random_uuid(); r jsonb; b uuid; first_pass uuid; old_count bigint;
begin
 select auth_user_id into actor from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 select auth_user_id into member from public.pin_accounts where not exists(select 1 from public.work_accounts where auth_user_id=pin_accounts.auth_user_id) limit 1;
 if actor is null or member is null then raise exception 'fixture_missing';end if;
 select count(*) into old_count from public.game_passes;
 if has_function_privilege('anon','public.yt_pos_bundle_issue(uuid,uuid,uuid,uuid,integer)','execute') or has_function_privilege('anon','public.yt_pos_bundle_claim(uuid)','execute') then raise exception 'bundle_write_exposed';end if;
 insert into public.yt_pos_series(name,benefit_mode,game_plays,active) values('rollback bundle','games',1,true) returning id into series;
 insert into public.yt_shop_products(title,price_rm,series_id,active) values('rollback bundle drink',28,series,true) returning id into product;
 insert into public.campaigns(name,active) values('rollback bundle campaign',true) returning id into campaign;
 insert into public.yt_member_orders(source,status,amount_rm,created_by,payment_status) values('future_pos','confirmed',112,actor,'unpaid') returning id into o;
 insert into public.yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) values(o,product,'rollback drink',3,28) returning id into item;
 insert into public.yt_member_order_items(order_id,item_name,quantity,unit_price_rm) values(o,'unconfigured',1,28) returning id into unsupported;
 insert into public.yt_pos_item_units(order_item_id,unit_number) select item,n from generate_series(1,3) n on conflict do nothing;
 insert into public.yt_pos_item_units(order_item_id,unit_number) values(unsupported,1) on conflict do nothing;
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
 begin perform public.yt_pos_bundle_issue(o,campaign,token,req);raise exception 'expected_failure';exception when others then if sqlerrm<>'benefits_after_payment_only' then raise;end if;end;
 update public.yt_member_orders set status='fulfilled',payment_status='paid',paid_at=clock_timestamp(),paid_by=actor,payment_method='cash' where id=o;
 select pass_id into first_pass from public.yt_pos_issue_unit_pass(o,item,1,campaign,gen_random_uuid(),gen_random_uuid(),10);
 r=public.yt_pos_bundle_quote(o);if (r->>'eligible_units')::int<>2 or (r->>'unsupported_units')::int<>1 then raise exception 'mixed_quote_wrong';end if;
 r=public.yt_pos_bundle_issue(o,campaign,token,req);b=(r->>'id')::uuid;
 if (r->>'pass_count')::int<>2 or (r->>'excluded_count')::int<>2 then raise exception 'mixed_issue_wrong';end if;
 r=public.yt_pos_bundle_issue(o,campaign,token,req);if not (r->>'idempotent')::boolean or (r->>'id')::uuid<>b or (select count(*) from public.game_passes)<>old_count+3 then raise exception 'retry_duplicate';end if;
 r=public.yt_pos_bundle_quote(o);if (r#>>'{active_bundle,request_id}')::uuid<>req then raise exception 'cannot_recover';end if;
 begin perform public.yt_pos_bundle_issue(o,campaign,gen_random_uuid(),gen_random_uuid());raise exception 'expected_failure';exception when others then if sqlerrm<>'active_order_bundle_exists' then raise;end if;end;
 begin perform public.yt_pos_bundle_claim(token);raise exception 'expected_failure';exception when others then if sqlerrm<>'customer_only' then raise;end if;end;
 -- Expired whole QR reuses per-cup pass rows, without minting duplicate benefits.
 update public.yt_pos_pass_bundles set expires_at=clock_timestamp()-interval '1 second' where id=b;
 update public.game_passes set expires_at=clock_timestamp()-interval '1 second' where id in(select pass_id from public.yt_pos_pass_bundle_items where bundle_id=b);
 token=gen_random_uuid();req=gen_random_uuid();r=public.yt_pos_bundle_issue(o,campaign,token,req);b=(r->>'id')::uuid;
 if (r->>'pass_count')::int<>2 or (select count(*) from public.game_passes)<>old_count+3 then raise exception 'expired_reissue_duplicate';end if;
 -- Partial availability must roll back the entire member claim.
 update public.game_passes set expires_at=clock_timestamp()-interval '1 second' where id=(select pass_id from public.yt_pos_pass_bundle_items where bundle_id=b order by pass_id desc limit 1);
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',member)::text,true);
 begin perform public.yt_pos_bundle_claim(token);raise exception 'expected_failure';exception when others then if sqlerrm<>'bundle_pass_not_available' then raise;end if;end;
 if exists(select 1 from public.game_passes where id in(select pass_id from public.yt_pos_pass_bundle_items where bundle_id=b) and customer_id is not null) then raise exception 'partial_claim_committed';end if;
 update public.game_passes set expires_at=clock_timestamp()+interval '10 minutes' where id in(select pass_id from public.yt_pos_pass_bundle_items where bundle_id=b);
 r=public.yt_pos_bundle_claim(token);if (r->>'count')::int<>2 then raise exception 'claim_count_wrong';end if;
 if (select count(*) from public.yt_pos_item_units where order_item_id=item and assigned_customer_id=member)<>2 then raise exception 'units_not_assigned';end if;
 r=public.yt_pos_bundle_claim(token);if not (r->>'idempotent')::boolean or (r->>'count')::int<>2 then raise exception 'claim_retry_wrong';end if;
 if (public.yt_pos_bundle_preview(token)->>'valid')::boolean then raise exception 'claimed_preview_valid';end if;
end;$$;
