# Yetipsy Ambassador System — V1.3

## Core flow
1. Ambassador creates a pass with Date + Pax.
2. Ambassador shares the generated invitation image (QR + Date + Ref).
3. Staff scans QR and pass information opens immediately. Ref search is backup only.
4. Staff enters Male + Female; Pax is automatic.
5. **Check-in is also payment**: clicking `Confirm Check-in & Payment` immediately records Sales and credits Commission to the Ambassador Wallet. There is no separate Checkout step.
6. Group pass supports partial check-in while the accumulated actual pax is below reserved pax.
7. When accumulated actual pax reaches or exceeds the Ambassador's reserved pax, the pass automatically becomes `CLOSED`.

## Pricing
- Normal Day = Sunday–Thursday
- Weekend = Friday–Saturday
- Male and Female have separate prices
- Special Date Override can set separate Male / Female prices and has highest priority

## Ambassador price display
Ambassador dashboard shows:
- Today's Male / Female price
- A compact 7-day price table

## Installation
1. Google Sheet → Extensions → Apps Script
2. Paste `Code.gs`
3. Run `setupSheets()` once
4. Run `seedDemoUsers()` for demo users if needed
5. Deploy as Web App (Execute as Me, access Anyone)
6. Put the Web App URL in `config.js`
7. Upload all frontend files and `assets/` to GitHub Pages

## Demo users
- Admin: `owner / ChangeMe123!`
- Staff: `staff1 / ChangeMe123!`

Change demo passwords before production use.

## V1.4 Owner additions
- Owner can record **actual Ambassador commission payout amount**.
- Payout creates a negative `PAYOUT` Wallet transaction, so Ambassador `Available Wallet` decreases without deleting commission history.
- New `Payouts` sheet keeps payout reference, amount, method, note, who paid, and time.
- Owner dashboard shows Ambassador **Earned / Paid / Available** separately.
- Owner can change their own password using current password verification.
- Owner can reset passwords for Admin / Staff / Ambassador accounts.
- New passwords require at least 8 characters.


## V1.4.1 password fix
- Password changes are now verified by re-reading the Users sheet after write.
- Changing the Owner password invalidates all Owner sessions and forces re-login.
- Resetting another user's password invalidates all sessions for that user.
- Login detects duplicate username+role rows instead of silently using the wrong row.
- New password cannot equal the current password for Owner self-change.

After replacing `Code.gs`, you MUST create a new Apps Script deployment version (or edit the existing deployment to point to the new version).


## V1.4.2 invitation update
- Invitation QR style changed to **black background + gold modules**
- Date and Ref moved upward to sit closer to the QR frame
- Raw black/white QR is still available as fallback preview


## V1.5 Owner Super Mode
- Owner/Admin can switch between **Owner Dashboard / Staff Mode / Ambassador Mode** without logging in again.
- Owner can generate and edit its own Guest Passes.
- Owner in Staff Mode can override **Male Price / Female Price for that single check-in only**.
- Ordinary Staff cannot see or submit custom pricing.
- Custom check-in price does not change Normal Day / Weekend / Special Date settings.
- After replacing `Code.gs`, deploy a **new Apps Script Web App version**.
