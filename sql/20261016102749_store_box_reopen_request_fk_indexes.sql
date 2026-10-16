-- Index Store Box reopen request foreign keys for cleanup and requester lookups.
create index if not exists yt_store_box_reopen_customer_idx
 on public.yt_store_box_reopen_requests(customer_id);
create index if not exists yt_store_box_reopen_reviewed_by_idx
 on public.yt_store_box_reopen_requests(reviewed_by)
 where reviewed_by is not null;
