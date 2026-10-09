-- Applied through Supabase MCP: home_banner_owner_uploads_v5.
-- Only this public advertising bucket is enabled; existing storage is unchanged.
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('yetipsy-home-banners','yetipsy-home-banners',true,5242880,ARRAY['image/jpeg','image/png','image/webp']);

CREATE TABLE private.yt_home_banners (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 title text NOT NULL CHECK(length(title) BETWEEN 1 AND 80),
 image_path text NOT NULL CHECK(image_path ~ '^ads/[0-9a-f-]{36}\.(jpg|png|webp)$'),
 sort_order integer NOT NULL DEFAULT 0 CHECK(sort_order BETWEEN 0 AND 999),
 enabled boolean NOT NULL DEFAULT true,
 updated_by uuid NOT NULL REFERENCES auth.users(id),
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX yt_home_banners_display ON private.yt_home_banners(sort_order,id) WHERE enabled;
ALTER TABLE private.yt_home_banners ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.yt_home_banners FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.yt_banner_owner()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT auth.uid() IS NOT NULL AND (private.yt_has_role('owner') OR EXISTS(
 SELECT 1 FROM public.work_accounts WHERE auth_user_id=auth.uid() AND active AND role='owner'));
$$;
REVOKE ALL ON FUNCTION private.yt_banner_owner() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_banner_owner() TO authenticated;
CREATE POLICY yt_banner_owner_insert ON storage.objects FOR INSERT TO authenticated
WITH CHECK(bucket_id='yetipsy-home-banners' AND name ~ '^ads/[0-9a-f-]{36}\.(jpg|png|webp)$' AND (SELECT private.yt_banner_owner()));
CREATE POLICY yt_banner_owner_select ON storage.objects FOR SELECT TO authenticated
USING(bucket_id='yetipsy-home-banners' AND (SELECT private.yt_banner_owner()));
-- Upload replacements use new immutable paths (upsert=false), so clients cannot
-- overwrite images already used by the published carousel.

CREATE FUNCTION private.yt_home_banner_list()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'image_path',image_path,'sort_order',sort_order) ORDER BY sort_order,id),'[]'::jsonb)
 FROM private.yt_home_banners WHERE enabled;
$$;
CREATE FUNCTION public.yt_home_banner_list()
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT private.yt_home_banner_list();$$;
REVOKE ALL ON FUNCTION private.yt_home_banner_list(),public.yt_home_banner_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.yt_home_banner_list(),public.yt_home_banner_list() TO anon,authenticated;

CREATE FUNCTION private.yt_owner_banner_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT private.yt_banner_owner() THEN RAISE EXCEPTION 'owner_only';END IF;
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'title',title,'image_path',image_path,'sort_order',sort_order,'enabled',enabled) ORDER BY sort_order,id) FROM private.yt_home_banners),'[]'::jsonb);
END;$$;
CREATE FUNCTION public.yt_owner_banner_list()
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT private.yt_owner_banner_list();$$;
REVOKE ALL ON FUNCTION private.yt_owner_banner_list(),public.yt_owner_banner_list() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_owner_banner_list(),public.yt_owner_banner_list() TO authenticated;

CREATE FUNCTION private.yt_owner_banner_save(p_id uuid,p_title text,p_image_path text,p_sort integer,p_enabled boolean)
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
  IF (SELECT count(*) FROM private.yt_home_banners)>=20 THEN RAISE EXCEPTION 'too_many_banners';END IF;
  INSERT INTO private.yt_home_banners(title,image_path,sort_order,enabled,updated_by)
  VALUES(btrim(p_title),p_image_path,p_sort,p_enabled,auth.uid()) RETURNING id INTO v_id;
 ELSE
  UPDATE private.yt_home_banners SET title=btrim(p_title),image_path=p_image_path,sort_order=p_sort,enabled=p_enabled,
  updated_by=auth.uid(),updated_at=clock_timestamp() WHERE id=p_id RETURNING id INTO v_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'banner_not_found';END IF;
 END IF;
 RETURN v_id;
END;$$;
CREATE FUNCTION public.yt_owner_banner_save(p_id uuid,p_title text,p_image_path text,p_sort integer,p_enabled boolean)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.yt_owner_banner_save(p_id,p_title,p_image_path,p_sort,p_enabled);$$;
REVOKE ALL ON FUNCTION private.yt_owner_banner_save(uuid,text,text,integer,boolean),public.yt_owner_banner_save(uuid,text,text,integer,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.yt_owner_banner_save(uuid,text,text,integer,boolean),public.yt_owner_banner_save(uuid,text,text,integer,boolean) TO authenticated;
NOTIFY pgrst,'reload schema';
