# Lite Protection V1 — rollout and limitations

## Implemented
- SQL 074–079 deployed to Supabase project `cubmzdozyqswoyhshxgl`.
- `yt-pin-auth` Edge Function v13 deployed with registration-time device association.
- Browser stores a random installation token; Edge Function converts it to a keyed HMAC digest.
- Third account on the same browser-install digest is reviewable. Fifth account with the same digest holds only `welcome` and `friend` promotional rewards at the existing `private.yt_award_promo` entry point.
- Owner release replays held grants through the original idempotent promo award function.
- No OTP, fingerprinting, IP bans, or blocking of registration, POS/KDS, earned points or ordinary reward redemption.

## Operational limitations
- Browser-install association is a **weak signal**. Clearing storage, private mode, using another browser/device, or omitting the token can evade detection. It is not a reliable identity verification mechanism.
- The signup flow intentionally permits registration if browser storage is unavailable; without a token no device hold applies.
- Historical accounts cannot be retroactively linked.
- The client UI is on the feature branch until merged; Supabase backend is deployed independently.
- Static contract tests and GitHub CI are not substitutes for a real test signup and Owner review in production.
- Never use raw IPs or hardware fingerprints to strengthen this mechanism without privacy review.

## Deployment order
1. SQL 074–079 (already applied).
2. Edge Function `yt-pin-auth` v13 (already deployed).
3. Merge client branch only after CI and Owner validation.
4. Verify a test sequence of 5 registrations on one browser, no duplicated promo grant, and Owner release.
