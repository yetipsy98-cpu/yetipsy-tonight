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
- TABLES

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


## V2.1 同桌同步
- 同一个 `table` 的所有手机读取同一个 TABLES 状态。
- 同桌看到相同 Warm-up 问题。
- 任意一人按 START FOR THE TABLE，后台写入未来约 1.8 秒的共享时间戳。
- 同桌手机轮询到时间戳后，在同一时间开始 READY / THREE / TWO / ONE / POINT。
- 网络延迟会造成几十到几百毫秒差异，这是 Google Apps Script 架构的正常范围。

## Match 测试注意
Match **不会匹配同一桌**。要测试真人 Match：
1. 手机 A：桌号 A1，选择 OPEN，进入 Find My Match。
2. 手机 B：桌号 B1，选择 OPEN，进入 Find My Match。
3. 两台都必须使用已经配置 `/exec` URL 的最新版 `backend.js`。
4. 如果只用 A1/A1 两台手机测试，它们会一直等待，这是正确行为。
5. 修改 `Code.gs` 后必须重新 Deploy 新版本；只保存 Apps Script 不会自动更新已部署 Web App。
