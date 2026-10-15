-- Preserve pre-launch referral claims without restoring early rewards for new signups.
create or replace function private.yt_referral_sale_trigger() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.customer_id is not null and old.customer_id is distinct from new.customer_id
 and exists(select 1 from public.yt_referral_links l
  cross join public.yt_play_upgrade_settings s
  where l.invited_customer_id=new.customer_id and l.invited_at<s.launch_at)
 then perform private.yt_referral_purchase_activated(new.customer_id);end if;
 return new;
end $$;
