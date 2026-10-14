-- Match the POS Ambassador portal to the actual yt_ambassador_prices columns.
do $$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='private' and p.proname='yt_ambassador_pos_issue_portal';
  if v_def is null then raise exception 'private.yt_ambassador_pos_issue_portal is missing'; end if;
  if position('weekday_male_price' in v_def)=0 then
    raise exception 'expected legacy Ambassador price column not found';
  end if;
  v_def:=replace(v_def,'weekday_male_price','weekday_male');
  v_def:=replace(v_def,'weekday_female_price','weekday_female');
  v_def:=replace(v_def,'weekend_male_price','weekend_male');
  v_def:=replace(v_def,'weekend_female_price','weekend_female');
  execute v_def;
end $$;
