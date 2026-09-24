/*
YÉ TIPSY · 月满杯盈 — 独立活动后台
=========================================================
重点：
- 不修改「今晚有局」长期 Code.gs
- 不新建临时数据库
- 直接使用你现有 MINIGAME Google Sheet
- 员工密码放在 MINIGAME Sheet 的 MOON_CONFIG，可直接改，立即生效
- 每一局必须员工密码解锁
- 每个 unlock token 只能成功领取一次
- 活动可在 MOON_CONFIG 直接 ON / OFF

第一次：
1. 从现有 MINIGAME Google Sheet → 扩展程序 → Apps Script 打开
2. 把本文件作为独立的 MoonGame.gs 加进去
3. 运行 setupMoonGame() 一次
4. 在 MOON_CONFIG 修改 STAFF_PASSWORD
5. 部署 Web App，并把 /exec URL 填进 moon-game.html
=========================================================
*/

const TOKEN_TTL_MS = 5 * 60 * 1000;

const CLAIM_SHEET = "MOON_GAME";
const SESSION_SHEET = "MOON_SESSIONS";
const CONFIG_SHEET = "MOON_CONFIG";

const CLAIM_HEADERS = [
  "recovery_code","created_at","country","whatsapp","dice","ones","reward",
  "community_opt_in","whatsapp_status","sent_at","redeemed","redeemed_at"
];
const SESSION_HEADERS = [
  "unlock_token","created_at","expires_at","used_at","status"
];
const CONFIG_HEADERS = ["key","value","note"];

function setupMoonGame() {
  const ss = db_();
  ensure_(ss, CLAIM_SHEET, CLAIM_HEADERS);
  ensure_(ss, SESSION_SHEET, SESSION_HEADERS);
  const cfg = ensure_(ss, CONFIG_SHEET, CONFIG_HEADERS);

  setDefaultConfig_(cfg, "ACTIVITY_ENABLED", "TRUE", "TRUE=开放；FALSE=关闭活动");
  setDefaultConfig_(cfg, "STAFF_PASSWORD", "CHANGE-ME", "员工解锁密码；直接改这里，立即生效，无需重新部署");
  setDefaultConfig_(cfg, "TOKEN_TTL_MINUTES", "5", "一次性员工授权有效分钟数");
  setDefaultConfig_(cfg, "WHATSAPP_SEND_DAYS", "3", "奖励承诺发送工作日，仅作后台配置记录");

  SpreadsheetApp.flush();
  return {
    ok: true,
    spreadsheet: ss.getName(),
    sheets: [CLAIM_SHEET, SESSION_SHEET, CONFIG_SHEET]
  };
}

function db_() {
  // 此 Apps Script 必须从目标 MINIGAME Google Sheet：
  // 扩展程序 → Apps Script 打开，因此直接使用绑定的 Spreadsheet。
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  if (!ss) {
    throw new Error("此脚本必须绑定在 MINIGAME Google Sheet 内执行");
  }
  return ss;
}

function ensure_(ss, name, headers) {
  let sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name);
  if (sh.getMaxColumns() < headers.length) {
    sh.insertColumnsAfter(sh.getMaxColumns(), headers.length - sh.getMaxColumns());
  }
  sh.getRange(1, 1, 1, headers.length).setValues([headers]);
  sh.setFrozenRows(1);
  return sh;
}

function setDefaultConfig_(sh, key, value, note) {
  const row = configRow_(sh, key);
  if (!row) sh.appendRow([key, value, note]);
}

function configRow_(sh, key) {
  if (sh.getLastRow() < 2) return null;
  const values = sh.getRange(2, 1, sh.getLastRow() - 1, 3).getValues();
  for (let i = 0; i < values.length; i++) {
    if (String(values[i][0] || "").trim().toUpperCase() === String(key).trim().toUpperCase()) {
      return { row: i + 2, value: values[i][1], note: values[i][2] };
    }
  }
  return null;
}

function config_(key, fallback) {
  const sh = db_().getSheetByName(CONFIG_SHEET);
  if (!sh) return fallback;
  const r = configRow_(sh, key);
  return r ? r.value : fallback;
}

function activityEnabled_() {
  return String(config_("ACTIVITY_ENABLED", "TRUE")).trim().toUpperCase() === "TRUE";
}

function tokenTtlMs_() {
  const mins = Number(config_("TOKEN_TTL_MINUTES", "5"));
  return Math.max(1, Math.min(30, isFinite(mins) ? mins : 5)) * 60 * 1000;
}

function doGet() {
  try {
    const ss = db_();
    return json_({
      ok: true,
      service: "YETIPSY Moon Game",
      connected: true,
      database: ss.getName(),
      enabled: activityEnabled_()
    });
  } catch (e) {
    return json_({ ok: false, connected: false, error: String(e.message || e) });
  }
}

function doPost(e) {
  try {
    const d = JSON.parse((e && e.postData && e.postData.contents) || "{}");

    if (!activityEnabled_()) {
      return json_({ ok: false, error: "activity_closed" });
    }

    if (d.action === "unlock") return json_(unlock_(d));
    if (d.action === "claim") return json_(claim_(d));

    return json_({ ok: false, error: "unknown_action" });
  } catch (e) {
    return json_({ ok: false, error: String(e.message || e) });
  }
}

function unlock_(d) {
  // 每次都从 Sheet 实时读取密码，所以改 MOON_CONFIG 后立即生效。
  const expected = String(config_("STAFF_PASSWORD", "") || "");
  if (!expected || expected === "CHANGE-ME") {
    return { ok: false, error: "password_not_configured" };
  }

  if (String(d.password || "") !== expected) {
    return { ok: false, error: "wrong_password" };
  }

  const sh = db_().getSheetByName(SESSION_SHEET);
  const token = Utilities.getUuid();
  const now = new Date();
  const expires = new Date(now.getTime() + tokenTtlMs_());

  sh.appendRow([token, now, expires, "", "UNLOCKED"]);
  SpreadsheetApp.flush();

  return {
    ok: true,
    unlockToken: token,
    expiresAt: expires.toISOString()
  };
}

function session_(sh, token) {
  if (sh.getLastRow() < 2) return null;
  const values = sh.getRange(2, 1, sh.getLastRow() - 1, SESSION_HEADERS.length).getValues();

  for (let i = 0; i < values.length; i++) {
    if (String(values[i][0] || "") === String(token || "")) {
      return { row: i + 2, data: values[i] };
    }
  }
  return null;
}

function claim_(d) {
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);

  try {
    const ss = db_();
    const sessions = ss.getSheetByName(SESSION_SHEET);
    const s = session_(sessions, d.unlockToken);

    if (!s) return { ok: false, error: "invalid_unlock" };
    if (String(s.data[4] || "") !== "UNLOCKED" || s.data[3]) {
      return { ok: false, error: "unlock_used" };
    }

    const expiresAt = new Date(s.data[2]).getTime();
    if (!expiresAt || Date.now() > expiresAt) {
      sessions.getRange(s.row, 5).setValue("EXPIRED");
      return { ok: false, error: "unlock_expired" };
    }

    const cc = String(d.countryCode || "");
    const digits = String(d.phone || "").replace(/\D/g, "");
    const phone = cc + digits;

    if (cc === "+65" && !/^\+65\d{8}$/.test(phone)) {
      return { ok: false, error: "invalid_phone" };
    }
    if (cc === "+60" && !/^\+60\d{9,11}$/.test(phone)) {
      return { ok: false, error: "invalid_phone" };
    }
    if (!["+60", "+65"].includes(cc)) {
      return { ok: false, error: "invalid_country" };
    }

    const dice = Array.isArray(d.dice) ? d.dice.map(Number) : [];
    if (
      dice.length !== 5 ||
      dice.some(n => !Number.isInteger(n) || n < 1 || n > 6)
    ) {
      return { ok: false, error: "invalid_dice" };
    }

    const ones = dice.filter(n => n === 1).length;

    // 奖励只由后端计算，不接受浏览器自行指定奖励。
    const reward =
      ones === 5 ? "断片指南系列 · 任一杯" :
      ones === 4 ? "微醺特调系列 · 任一杯" :
      ones === 3 ? "彩虹 Shot × 1" :
      "RM5 Voucher";

    const claims = ss.getSheetByName(CLAIM_SHEET);
    const code = makeCode_(claims);
    const now = new Date();

    claims.appendRow([
      code,
      now,
      cc === "+65" ? "SG" : "MY",
      phone,
      dice.join(","),
      ones,
      reward,
      d.communityOptIn ? "YES" : "NO",
      "PENDING",
      "",
      "NO",
      ""
    ]);

    // 只有成功写入奖励后才消耗授权，避免网络/号码错误误吃掉本局。
    sessions.getRange(s.row, 4).setValue(now);
    sessions.getRange(s.row, 5).setValue("USED");

    SpreadsheetApp.flush();

    return {
      ok: true,
      recoveryCode: code,
      reward: reward,
      ones: ones,
      whatsapp: phone,
      status: "PENDING",
      sendWithinBusinessDays: Number(config_("WHATSAPP_SEND_DAYS", "3")) || 3
    };
  } finally {
    lock.releaseLock();
  }
}

function makeCode_(sh) {
  for (let i = 0; i < 20; i++) {
    const code =
      "YT-MOON-" +
      Utilities.getUuid().replace(/-/g, "").slice(0, 8).toUpperCase();

    if (sh.getLastRow() < 2) return code;

    const hit = sh
      .getRange(2, 1, sh.getLastRow() - 1, 1)
      .createTextFinder(code)
      .matchEntireCell(true)
      .findNext();

    if (!hit) return code;
  }
  throw new Error("code_generation_failed");
}

function json_(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
