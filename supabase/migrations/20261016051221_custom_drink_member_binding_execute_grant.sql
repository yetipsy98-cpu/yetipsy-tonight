-- The public wrapper is SECURITY INVOKER, so its authenticated caller needs
-- EXECUTE on the private implementation. The function still validates Cashier/Owner.
revoke all on function private.yt_pos_custom_bind_member(uuid,uuid) from public,anon;
grant execute on function private.yt_pos_custom_bind_member(uuid,uuid) to authenticated;
