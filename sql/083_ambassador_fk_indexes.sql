create index if not exists yt_ambassadors_created_by_idx on public.yt_ambassadors(created_by) where created_by is not null;
create index if not exists yt_ambassador_prices_updated_by_idx on public.yt_ambassador_prices(updated_by) where updated_by is not null;
create index if not exists yt_ambassador_special_prices_updated_by_idx on public.yt_ambassador_special_prices(updated_by) where updated_by is not null;
create index if not exists yt_ambassador_checkins_checked_by_idx on public.yt_ambassador_checkins(checked_by);
create index if not exists yt_ambassador_checkins_pass_id_idx on public.yt_ambassador_checkins(pass_id);
create index if not exists yt_ambassador_ledger_created_by_idx on public.yt_ambassador_ledger(created_by);
