-- Enforce the one-code rule at the final order creation RPC, including legacy drafts.
do $migration$
declare old_def text; new_def text; needle text:='if not private.yt_pos_work_staff() then raise exception ''staff_only'';end if;';
begin
  select pg_get_functiondef('private.yt_pos_create_order_with_rewards_v4(uuid,text,text,jsonb,text,uuid,text,date)'::regprocedure) into old_def;
  if position('only_one_code_per_order' in old_def)=0 then
    new_def:=replace(old_def,needle,needle||E'\n if (select count(*) from public.yt_pos_preorder_holds h where h.operator_id=auth.uid() and h.draft_id=p_draft and h.state in (''pending'',''chosen'') and h.expires_at>clock_timestamp()) + (select count(*) from public.yt_moon_preorder_holds h where h.operator_id=auth.uid() and h.draft_id=p_draft and h.state=''held'' and h.expires_at>clock_timestamp()) > 1 then raise exception ''only_one_code_per_order'';end if;');
    if new_def=old_def then raise exception 'Could not add one-code checkout guard'; end if;
    execute new_def;
  end if;
end;
$migration$;
