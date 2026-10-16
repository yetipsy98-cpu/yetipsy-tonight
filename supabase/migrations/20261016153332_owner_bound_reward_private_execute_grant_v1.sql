-- The public invoker wrapper delegates to this security-definer function.
-- Grant only authenticated callers; the function itself enforces the Owner role.
REVOKE ALL ON FUNCTION private.yt_owner_update_bound_reward_v1(uuid,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_owner_update_bound_reward_v1(uuid,jsonb,jsonb) TO authenticated;
