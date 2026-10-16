-- Explicitly deny direct API access; security-definer RPCs enforce the approved workflow.
create policy yt_pos_custom_drink_members_deny_direct_access
on public.yt_pos_custom_drink_members
for all
to anon, authenticated
using (false)
with check (false);
