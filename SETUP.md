# YETIPSY Tonight V2 — Setup

## 1. Upload the guest site
Upload these files to the root of `yetipsy-tonight`:
- index.html
- styles.css
- content.js
- audio.js
- backend.js
- app.js

Enable GitHub Pages from `main` / root.

## 2. Create the matching backend
1. Create a blank Google Sheet.
2. Copy the Sheet ID from its URL.
3. Open Extensions → Apps Script.
4. Paste the complete `Code.gs`.
5. Replace `PASTE_GOOGLE_SHEET_ID_HERE`.
6. Deploy → New deployment → Web app.
7. Execute as: Me.
8. Who has access: Anyone.
9. Copy the `/exec` Web App URL.
10. Open `backend.js` and replace `PASTE_YOUR_APPS_SCRIPT_WEB_APP_URL_HERE`.

The backend automatically creates:
- PLAYERS
- MATCHES

## 3. Matching rules in this build
- One browser/device gets one persistent device ID.
- A player must enter nickname + table number.
- Same-table players are excluded from each other's match pool.
- A player cannot be in two active matches.
- Verified partners are added to history and should not be matched again.
- Candidate selection is randomized to reduce one-table-to-one-person pileups.
- Each side receives its own 4-digit code.
- Player A must enter Player B's displayed code; Player B must enter Player A's.
- The backend records each side's verification separately.

## Important
GitHub Pages alone cannot do real multi-phone matching. The Google Apps Script URL must be configured for real matching. If it is not configured, the UI clearly labels matches as PREVIEW/DEMO and does not pretend another real guest exists.

## Voice
The READY / THREE / TWO / ONE / POINT voice uses the phone/browser's built-in speech synthesis. Voice quality differs by iPhone/Android/browser. SFX and vibration are separate toggles.
