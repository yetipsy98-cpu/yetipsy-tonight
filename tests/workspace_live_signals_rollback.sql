-- Hosted read/notification regression. Rolls back all test changes and messages.
begin isolation level repeatable read;
do $test$
declare prior uuid[];actor uuid;n integer;
begin
 select coalesce(array_agg(id),'{}'::uuid[]) into prior from realtime.messages where topic like 'yt-work-%';
 update public.yt_member_orders set notes=notes where false;
 update public.yt_store_box_requests set id=id where false;
 if exists(select 1 from realtime.messages where topic like 'yt-work-%' and id<>all(prior)) then raise exception 'empty_update_must_not_signal';end if;
 update public.yt_member_orders set notes=case when notes='Live rollback probe' then 'Live rollback probe 2' else 'Live rollback probe' end where id=(select id from public.yt_member_orders limit 1);
 update public.yt_freeflow_requests set note=case when note='Live rollback probe' then 'Live rollback probe 2' else 'Live rollback probe' end where id=(select id from public.yt_freeflow_requests limit 1);
 update public.yt_play_bell_requests set note=case when note='Live rollback probe' then 'Live rollback probe 2' else 'Live rollback probe' end where id=(select id from public.yt_play_bell_requests limit 1);
 select count(*) into n from realtime.messages where topic like 'yt-work-%' and id<>all(prior);
 if n<>3 then raise exception 'work_signal_dedup_failed: %',n;end if;
 if exists(select 1 from realtime.messages where topic like 'yt-work-%' and id<>all(prior) and (not private or event<>'changed' or (payload-'scope'-'id')<>'{}'::jsonb)) then raise exception 'work_signal_payload_failed';end if;
 select auth_user_id into actor from public.work_accounts where role='owner' and active and not must_change_password limit 1;
 if actor is null then raise exception 'owner_missing';end if;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 perform set_config('realtime.topic','yt-work-orders',true);
 set local role authenticated;
 select count(*) into n from realtime.messages where id<>all(prior);
 if n<>1 then raise exception 'work_signal_owner_policy_failed %',n;end if;
 reset role;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 perform set_config('request.jwt.claims','{}',true);
 set local role authenticated;
 select count(*) into n from realtime.messages;
 if n<>0 then raise exception 'work_signal_customer_policy_failed';end if;
 reset role;
 set local role anon;
 select count(*) into n from realtime.messages;
 if n<>0 then raise exception 'work_signal_anon_policy_failed';end if;
 reset role;
end $test$;
select 'PASS hosted row changes -> 3 private minimal signals; zero-row reads do not signal; Owner topic access and member/anon denial; all data changes rolled back' result;
rollback;
