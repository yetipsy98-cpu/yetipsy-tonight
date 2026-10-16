-- Existing QR quotes may have used different per-material rules. Keep their audit
-- snapshots, but force the next Redeem scan through the current global pricing.
update public.yt_pos_custom_materials m
set margin_percent=s.margin_percent,
    min_discount_percent=0,
    max_discount_percent=s.max_discount_percent,
    price_revision=m.price_revision+1,
    updated_at=clock_timestamp()
from public.yt_pos_custom_pricing_settings s
where s.id=true;
