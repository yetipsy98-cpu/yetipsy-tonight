-- Delete one selected advertisement. Uploaded images remain available for reuse.
create function private.yt_owner_banner_delete(p_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if auth.uid() is null or not coalesce(private.yt_banner_owner(),false) then raise exception 'owner_only';end if;
 if p_id is null then raise exception 'invalid_banner';end if;
 perform pg_advisory_xact_lock(hashtextextended('yetipsy-home-banners',0));
 delete from public.yt_home_banners where id=p_id returning id into v_id;
 -- A retry after a lost response must not report a failed deletion.
 return jsonb_build_object('id',p_id,'deleted',true,'already_deleted',v_id is null);
end$$;
create function public.yt_owner_banner_delete(p_id uuid) returns jsonb
language sql security invoker set search_path='' as $$select private.yt_owner_banner_delete(p_id)$$;
revoke all on function private.yt_owner_banner_delete(uuid),public.yt_owner_banner_delete(uuid) from public,anon,authenticated;
grant execute on function private.yt_owner_banner_delete(uuid),public.yt_owner_banner_delete(uuid) to authenticated;
