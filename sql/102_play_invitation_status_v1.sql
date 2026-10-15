-- Show reward processing and eligibility in the invitation drawer.
create or replace function private.yt_play_invites() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('nickname',p.display_name,
 'registered_at',l.invited_at,'expires_at',l.invited_at+interval '168 hours',
 'first_paid_at',f.paid_at,'rewarded',coalesce(l.inviter_bonus_processed,false),
 'reward_status',r.status) order by l.invited_at desc),'[]'::jsonb)
 from public.yt_referral_links l left join public.profiles p on p.id=l.invited_customer_id
 left join public.yt_play_first_purchases f on f.customer_id=l.invited_customer_id
 left join public.yt_play_referral_events r on r.invited_customer_id=l.invited_customer_id
 where l.inviter_customer_id=auth.uid() and private.yt_play_customer()
$$;
