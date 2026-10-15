create index if not exists yt_store_box_events_created_at_idx on public.yt_store_box_events(created_at desc);
create index if not exists yt_pos_revision_requests_requester_recent_idx on public.yt_pos_owner_revision_requests(requester_id,created_at desc) where requester_id is not null;
