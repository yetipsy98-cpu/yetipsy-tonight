-- These request buttons and RPCs are restricted to actual Cashier accounts, not delegated cashier permissions.
do $migration$
declare fn regprocedure; d text; needle text:='if not private.yt_pos_work_cashier() or private.yt_work_owner() then raise exception ''cashier_only''; end if;';
begin
  foreach fn in array array[
    'private.yt_pos_cashier_adjustment_submit(uuid,jsonb)'::regprocedure,
    'private.yt_pos_cashier_adjustment_requests_mine()'::regprocedure
  ] loop
    select pg_get_functiondef(fn) into d;
    if position('a.role=''cashier''' in d)=0 then
      d:=replace(d,needle,'if not exists(select 1 from public.work_accounts a where a.auth_user_id=actor and a.active and a.role=''cashier'') then raise exception ''cashier_only''; end if;');
      if d=pg_get_functiondef(fn) then raise exception 'Could not restrict adjustment request function to Cashier role'; end if;
      execute d;
    end if;
  end loop;
end;
$migration$;
