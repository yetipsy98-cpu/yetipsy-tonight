-- Allow authenticated owner sessions to reach the level rule saver via its public RPC.
-- The function still enforces private.yt_work_owner() before writing.
grant execute on function private.yt_store_box_rule_save_levels(uuid,text,integer,text,jsonb,boolean) to authenticated;
