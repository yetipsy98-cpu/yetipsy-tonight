create index if not exists yt_ambassador_pos_sales_ambassador_idx on public.yt_ambassador_pos_sales(ambassador_id,created_at desc);
create index if not exists yt_ambassador_pos_sales_created_by_idx on public.yt_ambassador_pos_sales(created_by,created_at desc);
