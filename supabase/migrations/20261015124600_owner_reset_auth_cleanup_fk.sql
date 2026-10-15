-- Let the existing resumable reset cleanup finish safely when deleting accounts.
-- Account-owned tokens and customer bell requests should not outlive their user;
-- retained bell history drops only the deleted staff acknowledger reference.
alter table public.yt_play_member_tokens
  drop constraint if exists yt_play_member_tokens_customer_id_fkey;
alter table public.yt_play_member_tokens
  add constraint yt_play_member_tokens_customer_id_fkey
  foreign key (customer_id) references auth.users(id) on delete cascade;

alter table public.yt_play_invite_tokens
  drop constraint if exists yt_play_invite_tokens_inviter_customer_id_fkey;
alter table public.yt_play_invite_tokens
  add constraint yt_play_invite_tokens_inviter_customer_id_fkey
  foreign key (inviter_customer_id) references auth.users(id) on delete cascade;

alter table public.yt_play_bell_requests
  drop constraint if exists yt_play_bell_requests_customer_id_fkey;
alter table public.yt_play_bell_requests
  add constraint yt_play_bell_requests_customer_id_fkey
  foreign key (customer_id) references auth.users(id) on delete cascade;

alter table public.yt_play_bell_requests
  drop constraint if exists yt_play_bell_requests_acknowledged_by_fkey;
alter table public.yt_play_bell_requests
  add constraint yt_play_bell_requests_acknowledged_by_fkey
  foreign key (acknowledged_by) references auth.users(id) on delete set null;

-- Also invalidate these ephemeral records in any later business-record reset.
do $patch$
declare
  v_definition text;
  v_updated text;
begin
  select pg_get_functiondef(
    'private.yt_owner_reset_v9(uuid,text,text,uuid,uuid,bigint[],text[])'::regprocedure
  ) into v_definition;

  if position('public.yt_play_referral_events restart identity' in v_definition) = 0 then
    raise exception 'owner_reset_auth_cleanup_patch_anchor_missing';
  end if;
  if position('public.yt_play_member_tokens' in v_definition) > 0
     or position('public.yt_play_invite_tokens' in v_definition) > 0
     or position('public.yt_play_bell_requests' in v_definition) > 0 then
    raise exception 'owner_reset_auth_cleanup_tables_already_present';
  end if;

  v_updated := replace(
    v_definition,
    'public.yt_play_referral_events restart identity',
    'public.yt_play_referral_events,public.yt_play_member_tokens,public.yt_play_invite_tokens,public.yt_play_bell_requests restart identity'
  );
  execute v_updated;
end
$patch$;
