# YETIPSY Tonight — Final Setup

## 1. Frontend
Upload `index.html`, `styles.css`, `questions.js`, `audio.js`, `backend.js`, `app.js`, `admin.html` to the GitHub Pages repository root.

## 2. Google Sheet
Create one blank Google Sheet. Copy its ID from the URL between `/d/` and `/edit`.

## 3. Apps Script
From that Sheet: Extensions → Apps Script. Paste `Code.gs`.
- Replace `PASTE_GOOGLE_SHEET_ID_HERE`.
- Replace `CHANGE_THIS_TO_A_LONG_RANDOM_SECRET` with a long random owner secret.
- Deploy → New deployment → Web app.
- Execute as: Me.
- Who has access: Anyone.
- Copy the `/exec` URL.

The script automatically creates `SESSIONS`, `WALL`, and `EVENTS` tabs on first request.

## 4. Connect frontend
Open `backend.js` and paste the `/exec` URL into `API_URL`.
Commit again.

## 5. Anonymous wall moderation
New wall messages are `pending` by default and are NOT shown publicly until approved. In the Sheet, change WALL `status` to `approved` or `rejected`. This is deliberately manual and safe for the first real event.

## 6. Owner LIVE
Open `/admin.html`, paste the Apps Script URL and the same Admin Key, enter event text and duration, then GO LIVE.

## 7. Important
Do not put the Admin Key in `backend.js` or any public frontend file. `admin.html` asks for it at runtime and stores the API URL only.

GitHub Pages is public. This package is designed for a public guest experience, not private deployment.
