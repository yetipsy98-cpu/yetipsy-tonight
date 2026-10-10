-- Cover Store Box foreign keys used by cleanup, audit and workbench lookups.
create index yt_store_box_rules_reward_idx on public.yt_store_box_product_rules(completion_reward_id) where completion_reward_id is not null;
create index yt_store_box_rules_updated_by_idx on public.yt_store_box_product_rules(updated_by) where updated_by is not null;
create index yt_store_boxes_product_idx on public.yt_store_boxes(product_id) where product_id is not null;
create index yt_store_boxes_reward_idx on public.yt_store_boxes(completion_reward_id) where completion_reward_id is not null;
create index yt_store_boxes_created_by_idx on public.yt_store_boxes(created_by) where created_by is not null;
create index yt_store_box_claims_box_idx on public.yt_store_box_claims(box_id);
create index yt_store_box_claims_issued_by_idx on public.yt_store_box_claims(issued_by) where issued_by is not null;
create index yt_store_box_claims_claimed_by_idx on public.yt_store_box_claims(claimed_by) where claimed_by is not null;
create index yt_store_box_claims_cancelled_by_idx on public.yt_store_box_claims(cancelled_by) where cancelled_by is not null;
create index yt_store_box_requests_box_idx on public.yt_store_box_requests(box_id);
create index yt_store_box_requests_customer_idx on public.yt_store_box_requests(customer_id) where customer_id is not null;
create index yt_store_box_requests_accepted_by_idx on public.yt_store_box_requests(accepted_by) where accepted_by is not null;
create index yt_store_box_requests_served_by_idx on public.yt_store_box_requests(served_by) where served_by is not null;
create index yt_store_box_events_request_idx on public.yt_store_box_events(request_id) where request_id is not null;
create index yt_store_box_events_actor_idx on public.yt_store_box_events(actor_id) where actor_id is not null;
create index yt_store_box_events_customer_idx on public.yt_store_box_events(customer_id) where customer_id is not null;
