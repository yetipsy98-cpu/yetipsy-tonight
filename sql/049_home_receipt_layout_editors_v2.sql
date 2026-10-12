
-- Config-only schema migration. Never touches orders, rewards or Store Box balances.
create table if not exists public.yt_home_layout (
 id smallint primary key default 1 check(id=1),
 draft jsonb not null default '{}'::jsonb,
 published jsonb not null default '{}'::jsonb,
 updated_at timestamptz not null default now(),
 updated_by uuid references auth.users(id) on delete set null
);
insert into public.yt_home_layout(id) values(1) on conflict(id) do nothing;
alter table public.yt_home_layout enable row level security;
revoke all on public.yt_home_layout from public,anon,authenticated;

create or replace function public.yt_home_layout_get()
returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce((select published from public.yt_home_layout where id=1),'{}'::jsonb);
$$;
create or replace function public.yt_home_layout_owner_get()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 return coalesce((select jsonb_build_object('draft',draft,'published',published,'updated_at',updated_at) from public.yt_home_layout where id=1),'{}'::jsonb);
end;$$;
create or replace function public.yt_home_layout_save(p_layout jsonb,p_publish boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare blocks jsonb; ids text[]; v jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if jsonb_typeof(p_layout)<>'object' or length(p_layout::text)>15000 then raise exception 'invalid_home_layout';end if;
 blocks:=p_layout->'blocks';
 if jsonb_typeof(blocks)<>'array' or jsonb_array_length(blocks)<>6 then raise exception 'invalid_home_blocks';end if;
 select array_agg(x->>'id' order by x->>'id') into ids from jsonb_array_elements(blocks) x;
 if ids<>array['carousel','claim','games','greeting','leaderboard','shortcuts']::text[] then raise exception 'invalid_home_blocks';end if;
 if exists(select 1 from jsonb_array_elements(blocks) x where jsonb_typeof(x->'visible')<>'boolean') then raise exception 'invalid_home_blocks';end if;
 if coalesce(p_layout->>'banner_ratio','16/9') not in ('32/9','16/9','2/1','4/3') or
    coalesce(p_layout->>'banner_fit','contain') not in ('contain','cover') then raise exception 'invalid_home_layout';end if;
 if coalesce(p_layout->>'accent','#E5B769') !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'invalid_home_layout';end if;
 update public.yt_home_layout
 set draft=p_layout,published=case when p_publish then p_layout else published end,
 updated_at=now(),updated_by=auth.uid() where id=1
 returning jsonb_build_object('draft',draft,'published',published,'updated_at',updated_at) into v;
 return v;
end;$$;
revoke all on function public.yt_home_layout_get(),public.yt_home_layout_owner_get(),public.yt_home_layout_save(jsonb,boolean) from public,anon,authenticated;
grant execute on function public.yt_home_layout_get() to anon,authenticated;
grant execute on function public.yt_home_layout_owner_get(),public.yt_home_layout_save(jsonb,boolean) to authenticated;

alter table public.yt_receipt_settings add column if not exists layout jsonb not null default '{}'::jsonb;
create or replace function public.yt_receipt_layout_save(p_layout jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ids text[]; answer jsonb;
begin
 if not private.yt_work_owner() then raise exception 'owner_only';end if;
 if jsonb_typeof(p_layout)<>'object' or length(p_layout::text)>12000
  or jsonb_typeof(p_layout->'blocks')<>'array'
  or jsonb_array_length(p_layout->'blocks')<>8 then raise exception 'invalid_receipt_layout';end if;
 select array_agg(x->>'id' order by x->>'id') into ids from jsonb_array_elements(p_layout->'blocks') x;
 if ids<>array['brand','discounts','document','footer','items','meta','payments','total']::text[] then raise exception 'invalid_receipt_layout';end if;
 if exists(select 1 from jsonb_array_elements(p_layout->'blocks') x where jsonb_typeof(x->'visible')<>'boolean') then raise exception 'invalid_receipt_layout';end if;
 if exists(select 1 from jsonb_array_elements(p_layout->'blocks') x
    where x->>'id' in ('items','document','total') and x->>'visible' <> 'true') then raise exception 'receipt_required_block';end if;
 if coalesce(p_layout->>'font_size','11') !~ '^(9|10|11|12|13|14)$' then raise exception 'invalid_receipt_layout';end if;
 update public.yt_receipt_settings set layout=p_layout,updated_at=now(),updated_by=auth.uid()
 where id=1 returning layout into answer;
 return answer;
end;$$;
revoke all on function public.yt_receipt_layout_save(jsonb) from public,anon,authenticated;
grant execute on function public.yt_receipt_layout_save(jsonb) to authenticated;
