-- Keep issued Moon codes and redemption history when reward configuration is reset.
-- The nullable binding can be assigned again through the existing owner workflow.
ALTER TABLE public.yt_moon_guest_codes
 DROP CONSTRAINT yt_moon_guest_codes_reward_id_fkey;
ALTER TABLE public.yt_moon_guest_codes
 ADD CONSTRAINT yt_moon_guest_codes_reward_id_fkey
 FOREIGN KEY (reward_id) REFERENCES public.rewards(id) ON DELETE SET NULL;
