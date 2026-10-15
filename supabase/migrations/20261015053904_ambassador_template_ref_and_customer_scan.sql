-- Put the Owner-managed Ambassador artwork on customer-issued Passes and add a short manual reference.
alter table public.yt_ambassador_passes
  add column if not exists reference_code text;

update public.yt_ambassador_passes
set reference_code = upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))
where reference_code is null;

alter table public.yt_ambassador_passes
  alter column reference_code set default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  alter column reference_code set not null;

create unique index if not exists yt_ambassador_passes_reference_code_uidx
  on public.yt_ambassador_passes(reference_code);

alter table public.yt_ambassador_qr_template
  add column if not exists date_x numeric not null default 50 check (date_x between 0 and 100),
  add column if not exists date_y numeric not null default 84 check (date_y between 0 and 100),
  add column if not exists ref_x numeric not null default 50 check (ref_x between 0 and 100),
  add column if not exists ref_y numeric not null default 92 check (ref_y between 0 and 100);

create or replace function public.yt_ambassador_qr_template_get()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v public.yt_ambassador_qr_template%rowtype;
begin
 if auth.uid() is null or not (
   private.yt_pos_work_staff()
   or private.yt_ambassador_work_access()
   or exists(select 1 from public.yt_ambassadors a where a.member_user_id=auth.uid() and a.active)
 ) then raise exception 'ambassador_access_required'; end if;
 select * into v from public.yt_ambassador_qr_template where singleton;
 if v.singleton is null then
  return jsonb_build_object('image_data_url',null,'qr_x',50,'qr_y',58,'qr_size',34,'date_x',50,'date_y',84,'ref_x',50,'ref_y',92);
 end if;
 return jsonb_build_object('image_data_url',v.image_data_url,'qr_x',v.qr_x,'qr_y',v.qr_y,'qr_size',v.qr_size,
  'date_x',v.date_x,'date_y',v.date_y,'ref_x',v.ref_x,'ref_y',v.ref_y);
end $function$;

create or replace function public.yt_ambassador_qr_template_save(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare v_image text:=coalesce(p_payload->>'image_data_url','');
 v_x numeric:=coalesce(nullif(p_payload->>'qr_x','')::numeric,50);
 v_y numeric:=coalesce(nullif(p_payload->>'qr_y','')::numeric,58);
 v_size numeric:=coalesce(nullif(p_payload->>'qr_size','')::numeric,34);
 v_date_x numeric:=coalesce(nullif(p_payload->>'date_x','')::numeric,50);
 v_date_y numeric:=coalesce(nullif(p_payload->>'date_y','')::numeric,84);
 v_ref_x numeric:=coalesce(nullif(p_payload->>'ref_x','')::numeric,50);
 v_ref_y numeric:=coalesce(nullif(p_payload->>'ref_y','')::numeric,92);
begin
 if not private.yt_work_owner() then raise exception 'owner_only'; end if;
 if length(v_image)>1400000 or v_image !~ '^data:image/(png|jpeg);base64,[A-Za-z0-9+/=]+$' then raise exception 'invalid_template'; end if;
 if v_x not between 0 and 100 or v_y not between 0 and 100 or v_size not between 10 and 80
   or v_date_x not between 0 and 100 or v_date_y not between 0 and 100
   or v_ref_x not between 0 and 100 or v_ref_y not between 0 and 100 then
  raise exception 'invalid_template_position';
 end if;
 insert into public.yt_ambassador_qr_template(singleton,image_data_url,qr_x,qr_y,qr_size,date_x,date_y,ref_x,ref_y,updated_at,updated_by)
 values(true,v_image,v_x,v_y,v_size,v_date_x,v_date_y,v_ref_x,v_ref_y,clock_timestamp(),auth.uid())
 on conflict(singleton) do update set image_data_url=excluded.image_data_url,qr_x=excluded.qr_x,qr_y=excluded.qr_y,
  qr_size=excluded.qr_size,date_x=excluded.date_x,date_y=excluded.date_y,ref_x=excluded.ref_x,ref_y=excluded.ref_y,
  updated_at=excluded.updated_at,updated_by=excluded.updated_by;
 return jsonb_build_object('ok',true);
end $function$;

create or replace function private.yt_ambassador_pass_lookup(p_token text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare a public.yt_ambassadors%rowtype; v public.yt_ambassador_passes%rowtype; d date:=private.yt_business_day(now()); pp jsonb;
 token text:=regexp_replace(trim(p_token),'^(YTAMB:|ambassador:|https?://[^ ]*[?&]amb=)','', 'i');
begin
 perform private.yt_ambassador_assert_work();
 if token ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
  select * into v from public.yt_ambassador_passes where pass_code=token::uuid and status='issued';
 elsif token ~* '^[0-9a-f]{8}$' then
  select * into v from public.yt_ambassador_passes where reference_code=upper(token) and status='issued';
 else
  raise exception 'ambassador_pass_not_found';
 end if;
 if v.id is null then raise exception 'ambassador_pass_not_found'; end if;
 select * into a from public.yt_ambassadors where id=v.ambassador_id and active;
 if a.id is null then raise exception 'ambassador_inactive'; end if;
 if a.member_user_id=auth.uid() or a.work_user_id=auth.uid() then raise exception 'cannot_redeem_own_pass'; end if;
 if d<>v.reservation_day or now()<private.yt_business_start(v.reservation_day) or now()>=private.yt_business_start(v.reservation_day+1) then raise exception 'ambassador_pass_not_valid_today'; end if;
 pp:=private.yt_ambassador_price(v.reservation_day);
 if coalesce((pp->>'male')::numeric,0)<=0 or coalesce((pp->>'female')::numeric,0)<=0 then raise exception 'ambassador_prices_not_configured'; end if;
 return jsonb_build_object('pass_id',v.id,'pass_code',v.pass_code,'reference_code',v.reference_code,
  'reservation_day',v.reservation_day,'pass_type',v.pass_type,'planned_pax',v.planned_pax,'guest_name',v.guest_name,
  'guest_phone',v.guest_phone,'remark',v.remark,'ambassador_name',coalesce(nullif(a.display_name,''),'Ambassador'),
  'commission_rate',a.commission_rate,'male_price',(pp->>'male')::numeric,'female_price',(pp->>'female')::numeric,
  'checked_pax',(select coalesce(sum(c.male_count+c.female_count),0) from public.yt_ambassador_checkins c where c.pass_id=v.id),
  'sales',(select coalesce(sum(c.sales),0) from public.yt_ambassador_checkins c where c.pass_id=v.id),
  'commission',(select coalesce(sum(c.commission_amount),0) from public.yt_ambassador_checkins c where c.pass_id=v.id));
end $$;

revoke all on function public.yt_ambassador_qr_template_get() from public,anon;
grant execute on function public.yt_ambassador_qr_template_get() to authenticated,service_role;
revoke all on function public.yt_ambassador_qr_template_save(jsonb) from public,anon;
grant execute on function public.yt_ambassador_qr_template_save(jsonb) to authenticated,service_role;
revoke all on function private.yt_ambassador_pass_lookup(text) from public,anon;
grant execute on function private.yt_ambassador_pass_lookup(text) to authenticated,service_role;
