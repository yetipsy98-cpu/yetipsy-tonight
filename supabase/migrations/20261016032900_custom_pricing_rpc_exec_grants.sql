-- Public custom-pricing RPC wrappers run as the caller and delegate to these
-- SECURITY DEFINER functions. Grant authenticated execution so the wrappers
-- can reach them; each function enforces its own Owner/Cashier/staff check.
grant execute on function private.yt_pos_custom_settings() to authenticated;
grant execute on function private.yt_pos_custom_settings_save(numeric,numeric) to authenticated;
grant execute on function private.yt_pos_custom_material_save_v2(uuid,text,numeric,boolean) to authenticated;
grant execute on function private.yt_pos_custom_create(text,jsonb,numeric) to authenticated;
grant execute on function private.yt_pos_custom_reprice(uuid,numeric) to authenticated;
