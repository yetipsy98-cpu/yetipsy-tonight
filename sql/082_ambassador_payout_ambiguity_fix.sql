create or replace function private.yt_ambassador_payout(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare aid uuid; amt numeric; method text; note text; bal numeric; payout_id uuid; d date:=private.yt_business_day(now());
begin
 perform private.yt_ambassador_assert_owner();
 begin aid:=(p_payload->>'ambassador_id')::uuid; amt:=(p_payload->>'amount')::numeric; exception when others then raise exception 'invalid_payout'; end;
 method:=left(trim(coalesce(p_payload->>'method','')),40); note:=left(trim(coalesce(p_payload->>'note','')),300);
 if amt<=0 or amt>1000000 or method='' then raise exception 'invalid_payout'; end if;
 perform 1 from public.yt_ambassadors as amb where amb.id=aid and amb.active for update;
 if not found then raise exception 'ambassador_not_found'; end if;
 select coalesce(sum(l.amount),0) into bal from public.yt_ambassador_ledger as l where l.ambassador_id=aid;
 if amt>bal then raise exception 'payout_exceeds_balance'; end if;
 insert into public.yt_ambassador_ledger(ambassador_id,entry_type,amount,method,note,created_by,business_day)
 values(aid,'payout',-amt,method,note,auth.uid(),d) returning yt_ambassador_ledger.id into payout_id;
 return jsonb_build_object('id',payout_id,'balance',bal-amt);
end $$;
