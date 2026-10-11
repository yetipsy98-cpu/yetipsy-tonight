-- PostgREST resolves RPC calls by argument name. The original public wrappers
-- only declared argument types, so supabase-js could not match p_* payloads.

drop function public.yt_store_box_rule_save(uuid,text,integer,integer,integer,text,uuid,boolean,boolean);
drop function public.yt_store_box_issue_quote(uuid);
drop function public.yt_store_box_issue(uuid,uuid,uuid,integer);
drop function public.yt_store_box_claim_cancel(uuid,text);
drop function public.yt_store_box_claim_preview(uuid);
drop function public.yt_store_box_claim(uuid);
drop function public.yt_store_box_request(uuid,integer,uuid,text);
drop function public.yt_store_box_request_cancel(uuid);
drop function public.yt_store_box_request_action(uuid,text,integer,text);
drop function public.yt_store_box_progress(uuid,text,integer);

create function public.yt_store_box_rule_save(
 p_product uuid,p_mode text,p_total_units integer,p_request_limit integer,p_expiry_days integer,
 p_unit_label text,p_completion_reward uuid,p_game_pass_enabled boolean,p_active boolean
) returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_store_box_rule_save(p_product,p_mode,p_total_units,p_request_limit,p_expiry_days,p_unit_label,p_completion_reward,p_game_pass_enabled,p_active)
$$;

create function public.yt_store_box_issue_quote(p_order uuid) returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_store_box_issue_quote(p_order)
$$;

create function public.yt_store_box_issue(p_order_item uuid,p_token uuid,p_request uuid,p_minutes integer) returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_store_box_issue(p_order_item,p_token,p_request,p_minutes)
$$;

create function public.yt_store_box_claim_cancel(p_claim uuid,p_reason text) returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_store_box_claim_cancel(p_claim,p_reason)
$$;

create function public.yt_store_box_claim_preview(p_token uuid) returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_store_box_claim_preview(p_token)
$$;

create function public.yt_store_box_claim(p_token uuid) returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_store_box_claim(p_token)
$$;

create function public.yt_store_box_request(p_box uuid,p_quantity integer,p_request uuid,p_table_label text) returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_store_box_request(p_box,p_quantity,p_request,p_table_label)
$$;

create function public.yt_store_box_request_cancel(p_request uuid) returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_store_box_request_cancel(p_request)
$$;

create function public.yt_store_box_request_action(p_request uuid,p_action text,p_completed_delta integer,p_reason text) returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_store_box_request_action(p_request,p_action,p_completed_delta,p_reason)
$$;

create function public.yt_store_box_progress(p_box uuid,p_action text,p_completed_delta integer) returns jsonb language sql security invoker set search_path='' as $$
 select private.yt_store_box_progress(p_box,p_action,p_completed_delta)
$$;

revoke all on function
 public.yt_store_box_rule_save(uuid,text,integer,integer,integer,text,uuid,boolean,boolean),
 public.yt_store_box_issue_quote(uuid),public.yt_store_box_issue(uuid,uuid,uuid,integer),
 public.yt_store_box_claim_cancel(uuid,text),public.yt_store_box_claim_preview(uuid),public.yt_store_box_claim(uuid),
 public.yt_store_box_request(uuid,integer,uuid,text),public.yt_store_box_request_cancel(uuid),
 public.yt_store_box_request_action(uuid,text,integer,text),public.yt_store_box_progress(uuid,text,integer)
from public,anon;

grant execute on function
 public.yt_store_box_rule_save(uuid,text,integer,integer,integer,text,uuid,boolean,boolean),
 public.yt_store_box_issue_quote(uuid),public.yt_store_box_issue(uuid,uuid,uuid,integer),
 public.yt_store_box_claim_cancel(uuid,text),public.yt_store_box_claim_preview(uuid),public.yt_store_box_claim(uuid),
 public.yt_store_box_request(uuid,integer,uuid,text),public.yt_store_box_request_cancel(uuid),
 public.yt_store_box_request_action(uuid,text,integer,text),public.yt_store_box_progress(uuid,text,integer)
to authenticated;

notify pgrst,'reload schema';
