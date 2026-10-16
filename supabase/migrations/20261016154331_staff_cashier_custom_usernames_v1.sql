ALTER TABLE public.work_accounts
  DROP CONSTRAINT IF EXISTS work_username_format;

ALTER TABLE public.work_accounts
  ADD CONSTRAINT work_username_format
  CHECK (
    char_length(username) BETWEEN 1 AND 40
    AND username = lower(btrim(username))
    AND username !~ '[[:cntrl:]]'
  );
