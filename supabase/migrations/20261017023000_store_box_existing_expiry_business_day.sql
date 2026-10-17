-- Convert unexpired cashier-managed store-box balances from elapsed 24-hour expiry
-- to the configured business-day cutoff. The inferred original checkout day is
-- storage_expires_at minus the old expiry_days interval.
update public.yt_store_boxes b
set storage_expires_at=private.yt_business_start(
  private.yt_business_day(b.storage_expires_at-make_interval(days=>b.expiry_days))+b.expiry_days
),updated_at=clock_timestamp()
where b.cashier_managed
 and b.status in ('unclaimed','active','paused','exhausted')
 and b.storage_expires_at is not null
 and b.storage_expires_at>clock_timestamp()
 and b.expiry_days>0
 and b.storage_expires_at<>private.yt_business_start(
  private.yt_business_day(b.storage_expires_at-make_interval(days=>b.expiry_days))+b.expiry_days
 );
