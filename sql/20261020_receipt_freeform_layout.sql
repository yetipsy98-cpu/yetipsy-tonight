create or replace function public.yt_receipt_layout_save(p_layout jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
 ids text[];
 answer jsonb;
 mode_name text;
 elements jsonb;
 el jsonb;
 seen_keys text[];
 element_key text;
 element_type text;
 field_name text;
 required_name text;
 required_ok boolean;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if jsonb_typeof(p_layout)<>'object' or length(p_layout::text)>30000
  or jsonb_typeof(p_layout->'blocks')<>'array'
  or jsonb_array_length(p_layout->'blocks')<>8 then raise exception 'invalid_receipt_layout';end if;
 select array_agg(x->>'id' order by x->>'id') into ids from jsonb_array_elements(p_layout->'blocks') x;
 if ids<>array['brand','discounts','document','footer','items','meta','payments','total']::text[] then raise exception 'invalid_receipt_layout';end if;
 if exists(select 1 from jsonb_array_elements(p_layout->'blocks') x where jsonb_typeof(x->'visible')<>'boolean') then raise exception 'invalid_receipt_layout';end if;
 if exists(select 1 from jsonb_array_elements(p_layout->'blocks') x where x->>'id' in ('items','document','total') and x->>'visible'<>'true') then raise exception 'receipt_required_block';end if;
 if coalesce(p_layout->>'font_size','11') !~ '^(7|8|9|10|11|12|13|14|15|16|18|20|22|24)$' then raise exception 'invalid_receipt_layout';end if;
 if p_layout ? 'variants' then
  if jsonb_typeof(p_layout->'variants')<>'object' then raise exception 'invalid_receipt_layout';end if;
  foreach mode_name in array array['paid','unpaid'] loop
   elements:=p_layout #> array['variants',mode_name,'elements'];
   if elements is null then continue;end if;
   if jsonb_typeof(elements)<>'array' or jsonb_array_length(elements)>32 then raise exception 'invalid_receipt_elements';end if;
   seen_keys:=array[]::text[];
   for el in select value from jsonb_array_elements(elements) loop
    if jsonb_typeof(el)<>'object' then raise exception 'invalid_receipt_element';end if;
    element_key:=el->>'key';
    element_type:=el->>'type';
    field_name:=el->>'field';
    if element_key is null or element_key='' or length(element_key)>48 or element_key=any(seen_keys) then raise exception 'invalid_receipt_element_key';end if;
    seen_keys:=array_append(seen_keys,element_key);
    if element_type is null or element_type not in ('field','text','divider')
       or coalesce(el->>'width','') not in ('full','half')
       or coalesce(el->>'align','') not in ('left','center','right')
       or coalesce(el->>'font_size','') !~ '^(0|7|8|9|10|11|12|13|14|15|16|18|20|22|24)$'
       or jsonb_typeof(el->'visible') is distinct from 'boolean'
       or jsonb_typeof(el->'bold') is distinct from 'boolean' then raise exception 'invalid_receipt_element';end if;
    if element_type='field' and (field_name is null or field_name not in (
      'business_name','subtitle','address_line','contact_line','document','order_no','table','created_at','staff','paid_at','payment_method','notes','items','subtotal','discount_lines','discount_total','total','balance','payment_history','reserved_note','pending_warning','footer'
    )) then raise exception 'invalid_receipt_field';end if;
    if element_type='text' and (jsonb_typeof(el->'text')<>'string' or length(el->>'text')>240) then raise exception 'invalid_receipt_text';end if;
    if element_type='divider' and coalesce(el->>'divider','dashed') not in ('dashed','solid') then raise exception 'invalid_receipt_divider';end if;
   end loop;
   foreach required_name in array array['document','items','total'] loop
    select exists(select 1 from jsonb_array_elements(elements) e where e->>'type'='field' and e->>'field'=required_name and e->>'visible'='true') into required_ok;
    if not required_ok then raise exception 'receipt_required_field:%',required_name;end if;
   end loop;
  end loop;
 end if;
 update public.yt_receipt_settings set layout=p_layout,updated_at=now(),updated_by=auth.uid()
 where id=1 returning layout into answer;
 return answer;
end;
$$;
revoke all on function public.yt_receipt_layout_save(jsonb) from public,anon,authenticated;
grant execute on function public.yt_receipt_layout_save(jsonb) to authenticated;
