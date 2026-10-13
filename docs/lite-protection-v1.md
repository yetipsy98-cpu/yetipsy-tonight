# Yetipsy Lite Protection V1 — development notes

Status: **observation-only groundwork**. Do not treat this branch as deployed or production-ready.

## Agreed behavior
- No phone OTP or WhatsApp verification.
- No automatic bans based on IP or shared Wi-Fi.
- Record multiple accounts on one browser device; 3 accounts triggers an owner-visible observation.
- At 5 accounts on a device, hold **new-user promotional rewards only**, never regular checkout or existing entitlements. This enforcement is **not implemented** by the migration.
- Prevent repeated reward grants and concurrent redemptions through backend transaction/idempotency checks, not browser UI.
- Referral reward only after first eligible paid order, with refund handling.

## Implementation boundaries
The additive SQL migration `sql/074_lite_protection_observation.sql` creates two server-only tables and an owner summary RPC. It does not collect device IDs, track IPs, suspend rewards, or change existing code paths. It is not safe to claim abuse protection is active after applying it.

Before implementing the backend writer:
1. Confirm which API actually owns signup, referral grants, Lucky Box and reward claims.
2. Use a server-side secret keyed digest (HMAC-SHA256) of a random browser-local identifier. Do not send raw identifiers to the database, expose secrets in GitHub Pages, or accept arbitrary browser-provided digests as trustworthy.
3. Verify authenticated account server-side; implement backend request throttling with trusted IP handling. Treat IP as a weak signal only.
4. Add atomic reward eligibility checks, unique idempotency keys and concurrent redemption tests in the real reward transaction path.
5. Add an owner-only review/release API with an audit trail, plus a compact Owner UI.
6. Set data retention, privacy notice, migration rollback and feature flag; deploy in observation mode first.

## Acceptance tests
- Two users sharing one device can register and buy normally.
- Third account creates observation only; fifth holds only eligible new-user promotional rewards.
- Ten users sharing one Wi-Fi are not blocked for sharing an IP.
- Duplicate reward requests, concurrent claims and retry-after-timeout do not double grant.
- Refund/cancellation reconciles referral rewards.
- Non-owner cannot query or mutate risk records.
- Existing POS, KDS, cashier, Moon, Lucky Box and reward flows remain functional.
- Risk subsystem failure does not block ordinary orders; costly rewards can be queued for later verification.

No database migration has been applied and no live deployment is part of this branch.
