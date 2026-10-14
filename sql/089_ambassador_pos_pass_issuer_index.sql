-- Cover the issuer lookup and date-filtered POS issue portal.
create index if not exists yt_ambassador_passes_issuer_day_idx on public.yt_ambassador_passes(issued_by,reservation_day,status);
