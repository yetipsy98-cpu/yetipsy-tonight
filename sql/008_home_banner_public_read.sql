-- Applied through Supabase MCP: home_banner_public_read_policy_v5.
-- Public ad metadata has a read policy; Owner edits still use checked RPCs.
ALTER TABLE private.yt_home_banners SET SCHEMA public;
GRANT SELECT(id,title,image_path,sort_order,enabled) ON public.yt_home_banners TO anon,authenticated;
CREATE POLICY yt_home_banner_visible ON public.yt_home_banners FOR SELECT TO anon,authenticated USING(enabled);
CREATE OR REPLACE FUNCTION public.yt_home_banner_list()
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'image_path',image_path,'sort_order',sort_order) ORDER BY sort_order,id),'[]'::jsonb)
 FROM public.yt_home_banners WHERE enabled;
$$;
REVOKE ALL ON FUNCTION private.yt_home_banner_list() FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION private.yt_owner_banner_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT private.yt_banner_owner() THEN RAISE EXCEPTION 'owner_only';END IF;
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'title',title,'image_path',image_path,'sort_order',sort_order,'enabled',enabled) ORDER BY sort_order,id) FROM public.yt_home_banners),'[]'::jsonb);
END;$$;
CREATE OR REPLACE FUNCTION private.yt_owner_banner_save(p_id uuid,p_title text,p_image_path text,p_sort integer,p_enabled boolean)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid;
BEGIN
 IF NOT private.yt_banner_owner() THEN RAISE EXCEPTION 'owner_only';END IF;
 IF p_title IS NULL OR length(btrim(p_title)) NOT BETWEEN 1 AND 80 OR p_sort IS NULL OR p_sort NOT BETWEEN 0 AND 999
 OR p_enabled IS NULL OR p_image_path IS NULL OR p_image_path!~'^ads/[0-9a-f-]{36}\.(jpg|png|webp)$'
 THEN RAISE EXCEPTION 'invalid_banner';END IF;
 IF NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='yetipsy-home-banners' AND name=p_image_path)
 THEN RAISE EXCEPTION 'banner_image_not_uploaded';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('yetipsy-home-banners',0));
 IF p_id IS NULL THEN
  IF (SELECT count(*) FROM public.yt_home_banners)>=20 THEN RAISE EXCEPTION 'too_many_banners';END IF;
  INSERT INTO public.yt_home_banners(title,image_path,sort_order,enabled,updated_by)
  VALUES(btrim(p_title),p_image_path,p_sort,p_enabled,auth.uid()) RETURNING id INTO v_id;
 ELSE
  UPDATE public.yt_home_banners SET title=btrim(p_title),image_path=p_image_path,sort_order=p_sort,enabled=p_enabled,
  updated_by=auth.uid(),updated_at=clock_timestamp() WHERE id=p_id RETURNING id INTO v_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'banner_not_found';END IF;
 END IF;
 RETURN v_id;
END;$$;
NOTIFY pgrst,'reload schema';
