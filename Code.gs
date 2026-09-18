/*
=========================================================
YETIPSY · 今晚有局
Backend V2.4
=========================================================

核心：
- Lobby：同桌先全部进来，再开桌
- 每一题所有人先看题
- FIRST READY = 本题 Lead Phone
- 只有 Lead Phone 播放 READY / 3 / 2 / 1 / POINT
- 其他手机只显示游戏进行中
- 初始 3 题后进入 Tonight Lobby / Break
- 之后交替：跨桌 Social Event -> Late Table Round -> Social Event...
- Match 有共同 Mission、双向验证码、取消、完成、历史去重
- 旧桌局 8 小时后自动视为新一晚

第一次覆盖后：
1. 保存
2. 运行 setup()
3. 管理部署 -> 编辑 -> 新版本 -> 部署
=========================================================
*/

const PROP_SHEET_ID = "YETIPSY_SHEET_ID";
const ONLINE_MS = 7 * 60 * 1000;
const STALE_SESSION_MS = 8 * 60 * 60 * 1000;
const LEAD_STALE_MS = 15 * 1000;
const LEAD_TAKEOVER_MS = 60 * 1000;
const FIRST_BREAK_MS = 12 * 60 * 1000;
const NORMAL_BREAK_MS = 15 * 60 * 1000;
const MISSION_COUNT = 12;
const WARM_COUNT = 16;
const LATE_COUNT = 8;

const PLAYER_HEADERS = [
  "device_id", "nick", "table_id", "mode", "status",
  "joined_at", "last_seen", "current_match", "history"
];

const MATCH_HEADERS = [
  "match_id", "a_device", "b_device", "a_code", "b_code",
  "a_verified", "b_verified", "status", "created_at", "completed_at",
  "mission_index", "a_completed", "b_completed"
];

/* 保留 V2.3 前 5 栏顺序，避免旧数据错位 */
const TABLE_HEADERS = [
  "table_id", "round", "question_index", "countdown_at", "updated_at",
  "status", "lead_device", "lead_nick", "round_started_at", "next_event_at",
  "event_index", "session_started_at", "session_id", "question_pool"
];


/* =====================================================
   SETUP / DB
===================================================== */

function setup() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  if (!ss) throw new Error("请从绑定的 Google Sheet → 扩展程序 → Apps Script 打开脚本。");

  PropertiesService.getScriptProperties().setProperty(PROP_SHEET_ID, ss.getId());
  ensureSheet_(ss, "PLAYERS", PLAYER_HEADERS);
  ensureSheet_(ss, "MATCHES", MATCH_HEADERS);
  ensureSheet_(ss, "TABLES", TABLE_HEADERS);
  SpreadsheetApp.flush();

  Logger.log("YETIPSY V2.4 SETUP SUCCESS: " + ss.getName());
  return { ok: true, version: "2.4", spreadsheet: ss.getName() };
}

function getDB_() {
  const id = PropertiesService.getScriptProperties().getProperty(PROP_SHEET_ID);
  if (!id) throw new Error("尚未初始化，请先运行 setup()。");
  return SpreadsheetApp.openById(id);
}

function ensureSheet_(ss, name, headers) {
  let sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name);

  if (sh.getMaxColumns() < headers.length) {
    sh.insertColumnsAfter(sh.getMaxColumns(), headers.length - sh.getMaxColumns());
  }

  sh.getRange(1, 1, 1, headers.length).setValues([headers]);
  sh.setFrozenRows(1);
  return sh;
}


/* =====================================================
   WEB APP
===================================================== */

function doGet() {
  try {
    const ss = getDB_();
    return json_({
      ok: true,
      service: "YETIPSY Tonight",
      version: "2.4",
      database: ss.getName(),
      connected: true
    });
  } catch (err) {
    return json_({
      ok: false,
      service: "YETIPSY Tonight",
      version: "2.4",
      connected: false,
      error: String(err.message || err)
    });
  }
}

function doPost(e) {
  try {
    const ss = getDB_();
    let data = {};
    if (e && e.postData && e.postData.contents) {
      data = JSON.parse(e.postData.contents);
    }

    switch (String(data.action || "")) {
      case "join": return json_(join_(ss, data));
      case "heartbeat": return json_(heartbeat_(ss, data));
      case "tableState": return json_(tableState_(ss, data));
      case "startTable": return json_(startTable_(ss, data));
      case "claimLead": return json_(claimLead_(ss, data));
      case "finishCountdown": return json_(finishCountdown_(ss, data));
      case "nextTableRound": return json_(nextTableRound_(ss, data));
      case "startEvent": return json_(startEvent_(ss, data));
      case "completeEvent": return json_(completeEvent_(ss, data));
      case "queue": return json_(queue_(ss, data));
      case "matchStatus": return json_(matchStatus_(ss, data));
      case "verify": return json_(verify_(ss, data));
      case "cancelMatch": return json_(cancelMatch_(ss, data));
      case "completeMatch": return json_(completeMatch_(ss, data));
      default: return json_({ ok: false, error: "unknown_action", action: data.action || "" });
    }
  } catch (err) {
    console.error(err);
    return json_({ ok: false, error: String(err.message || err) });
  }
}


/* =====================================================
   PLAYERS
===================================================== */

function join_(ss, d) {
  const sh = ss.getSheetByName("PLAYERS");
  const deviceId = clean_(d.deviceId, 100);
  const nick = clean_(d.nick, 30);
  const table = clean_(d.table, 20).toUpperCase();
  const mode = clean_(d.mode, 20);

  if (!deviceId || !nick || !table || !mode) {
    return { ok: false, error: "missing_player_data" };
  }

  const now = new Date();
  const player = playerRow_(sh, deviceId);

  if (player) {
    const safeStatus = player.data[7] ? (player.data[4] || "matched") : "active";
    sh.getRange(player.row, 2, 1, 6).setValues([[
      nick, table, mode, safeStatus,
      player.data[5] || now, now
    ]]);
  } else {
    sh.appendRow([deviceId, nick, table, mode, "active", now, now, "", ""]);
  }

  ensureTable_(ss, table);
  SpreadsheetApp.flush();
  return { ok: true, deviceId: deviceId, nick: nick, table: table, mode: mode };
}

function heartbeat_(ss, d) {
  const sh = ss.getSheetByName("PLAYERS");
  const p = playerRow_(sh, d.deviceId);
  if (p) sh.getRange(p.row, 7).setValue(new Date());
  return { ok: true };
}

function onlinePlayers_(ss, tableId) {
  const sh = ss.getSheetByName("PLAYERS");
  if (sh.getLastRow() < 2) return [];

  const values = sh.getRange(2, 1, sh.getLastRow() - 1, 9).getValues();
  const cutoff = Date.now() - ONLINE_MS;
  const table = String(tableId || "").toUpperCase();
  const out = [];

  values.forEach(r => {
    if (String(r[2] || "").toUpperCase() !== table) return;
    const seen = new Date(r[6]).getTime();
    if (!seen || seen < cutoff) return;
    out.push({
      deviceId: String(r[0] || ""),
      nick: String(r[1] || "PLAYER"),
      mode: String(r[3] || "chill")
    });
  });

  return out;
}


/* =====================================================
   TABLE SESSION
===================================================== */

function ensureTable_(ss, tableId) {
  const sh = ss.getSheetByName("TABLES");
  const table = clean_(tableId, 20).toUpperCase();
  let row = tableRow_(sh, table);
  const now = new Date();

  if (!row) {
    sh.appendRow([
      table, 1, randomIndex_(WARM_COUNT), "", now,
      "lobby", "", "", "", "", 0, "", Utilities.getUuid(), "warm"
    ]);
    SpreadsheetApp.flush();
    return tableRow_(sh, table);
  }

  const updatedAt = new Date(row.data[4]).getTime();
  const sessionId = String(row.data[12] || "");

  if (!sessionId || (updatedAt && updatedAt < Date.now() - STALE_SESSION_MS)) {
    resetTableRow_(sh, row.row, table);
    SpreadsheetApp.flush();
    row = tableRow_(sh, table);
  }

  return row;
}

function resetTableRow_(sh, rowNum, table) {
  const now = new Date();
  sh.getRange(rowNum, 1, 1, TABLE_HEADERS.length).setValues([[
    table, 1, randomIndex_(WARM_COUNT), "", now,
    "lobby", "", "", "", "", 0, "", Utilities.getUuid(), "warm"
  ]]);
}

function tableState_(ss, d) {
  const table = clean_(d.table, 20).toUpperCase();
  if (!table) return { ok: false, error: "missing_table" };

  const sh = ss.getSheetByName("TABLES");
  let t = ensureTable_(ss, table);
  let data = sh.getRange(t.row, 1, 1, TABLE_HEADERS.length).getValues()[0];

  /* Lead 倒数手机消失也不会把整桌永远卡住 */
  if (String(data[5] || "") === "playing") {
    const started = new Date(data[8]).getTime();
    if (started && Date.now() - started > LEAD_STALE_MS) {
      sh.getRange(t.row, 6).setValue("discuss");
      sh.getRange(t.row, 5).setValue(new Date());
      SpreadsheetApp.flush();
      data = sh.getRange(t.row, 1, 1, TABLE_HEADERS.length).getValues()[0];
    }
  }

  return tablePayload_(ss, data);
}

function tablePayload_(ss, data) {
  const players = onlinePlayers_(ss, data[0]);
  const started = new Date(data[8]).getTime();
  const status = String(data[5] || "lobby");

  return {
    ok: true,
    table: String(data[0] || ""),
    round: Number(data[1]) || 1,
    questionIndex: Number(data[2]) || 0,
    status: status,
    leadDevice: String(data[6] || ""),
    leadNick: String(data[7] || ""),
    roundStartedAt: data[8] || null,
    nextEventAt: data[9] || null,
    eventIndex: Number(data[10]) || 0,
    sessionStartedAt: data[11] || null,
    sessionId: String(data[12] || ""),
    questionPool: String(data[13] || "warm"),
    onlineCount: players.length,
    players: players.map(p => p.nick),
    canTakeOver: status === "discuss" && !!started && Date.now() - started >= LEAD_TAKEOVER_MS
  };
}

function startTable_(ss, d) {
  const lock = LockService.getScriptLock();
  lock.waitLock(6000);

  try {
    const table = clean_(d.table, 20).toUpperCase();
    const players = onlinePlayers_(ss, table);
    if (players.length < 2) return { ok: false, error: "need_two_players", onlineCount: players.length };

    const sh = ss.getSheetByName("TABLES");
    const t = ensureTable_(ss, table);
    const current = sh.getRange(t.row, 1, 1, TABLE_HEADERS.length).getValues()[0];

    if (String(current[5] || "") !== "lobby") {
      return tablePayload_(ss, current);
    }

    const now = new Date();
    sh.getRange(t.row, 1, 1, TABLE_HEADERS.length).setValues([[
      table, 1, randomIndex_(WARM_COUNT), "", now,
      "question", "", "", "", "", 0, now, Utilities.getUuid(), "warm"
    ]]);
    SpreadsheetApp.flush();
    return tableState_(ss, { table: table });
  } finally {
    lock.releaseLock();
  }
}

function claimLead_(ss, d) {
  const lock = LockService.getScriptLock();
  lock.waitLock(6000);

  try {
    const table = clean_(d.table, 20).toUpperCase();
    const deviceId = clean_(d.deviceId, 100);
    const sh = ss.getSheetByName("TABLES");
    const t = ensureTable_(ss, table);
    const data = sh.getRange(t.row, 1, 1, TABLE_HEADERS.length).getValues()[0];

    if (Number(d.currentRound || 0) !== (Number(data[1]) || 1)) {
      return Object.assign(tablePayload_(ss, data), { isLead: String(data[6] || "") === deviceId });
    }

    const status = String(data[5] || "");
    if (status !== "question" && status !== "playing") {
      return Object.assign(tablePayload_(ss, data), { isLead: false });
    }

    if (String(data[6] || "")) {
      return Object.assign(tablePayload_(ss, data), { isLead: String(data[6]) === deviceId });
    }

    const players = ss.getSheetByName("PLAYERS");
    const p = playerRow_(players, deviceId);
    const nick = p ? String(p.data[1] || "PLAYER") : clean_(d.nick, 30) || "PLAYER";
    const now = new Date();

    sh.getRange(t.row, 6, 1, 4).setValues([[
      "playing", deviceId, nick, now
    ]]);
    sh.getRange(t.row, 5).setValue(now);
    SpreadsheetApp.flush();

    const updated = sh.getRange(t.row, 1, 1, TABLE_HEADERS.length).getValues()[0];
    return Object.assign(tablePayload_(ss, updated), { isLead: true });
  } finally {
    lock.releaseLock();
  }
}

function finishCountdown_(ss, d) {
  const lock = LockService.getScriptLock();
  lock.waitLock(5000);

  try {
    const table = clean_(d.table, 20).toUpperCase();
    const deviceId = clean_(d.deviceId, 100);
    const sh = ss.getSheetByName("TABLES");
    const t = ensureTable_(ss, table);
    const data = sh.getRange(t.row, 1, 1, TABLE_HEADERS.length).getValues()[0];

    if (String(data[5] || "") === "playing" && String(data[6] || "") === deviceId) {
      sh.getRange(t.row, 6).setValue("discuss");
      sh.getRange(t.row, 5).setValue(new Date());
      SpreadsheetApp.flush();
    }

    return tableState_(ss, { table: table });
  } finally {
    lock.releaseLock();
  }
}

function nextTableRound_(ss, d) {
  const lock = LockService.getScriptLock();
  lock.waitLock(6000);

  try {
    const table = clean_(d.table, 20).toUpperCase();
    const deviceId = clean_(d.deviceId, 100);
    const sh = ss.getSheetByName("TABLES");
    const t = ensureTable_(ss, table);
    const data = sh.getRange(t.row, 1, 1, TABLE_HEADERS.length).getValues()[0];

    const serverRound = Number(data[1]) || 1;
    if (Number(d.currentRound || serverRound) !== serverRound) {
      return tablePayload_(ss, data);
    }

    if (String(data[5] || "") !== "discuss") {
      return { ok: false, error: "round_not_finished" };
    }

    const started = new Date(data[8]).getTime();
    const isLead = String(data[6] || "") === deviceId;
    const takeoverAllowed = !!started && Date.now() - started >= LEAD_TAKEOVER_MS;

    if (!isLead && !takeoverAllowed) {
      return { ok: false, error: "not_round_lead", leadNick: String(data[7] || "") };
    }

    const pool = String(data[13] || "warm");
    const roundLimit = pool === "late" ? 2 : 3;

    if (serverRound < roundLimit) {
      const count = pool === "late" ? LATE_COUNT : WARM_COUNT;
      const oldQuestion = Number(data[2]) || 0;
      const nextQuestion = differentIndex_(count, oldQuestion);
      const now = new Date();

      sh.getRange(t.row, 2, 1, 8).setValues([[
        serverRound + 1, nextQuestion, "", now,
        "question", "", "", ""
      ]]);
      SpreadsheetApp.flush();
      return tableState_(ss, { table: table });
    }

    /* 这一组桌内题结束，回 Tonight Lobby */
    const now = new Date();
    let eventIndex = Number(data[10]) || 0;
    if (pool === "warm" && eventIndex === 0) eventIndex = 1;
    if (pool === "late") eventIndex += 1;

    const delay = pool === "warm" ? FIRST_BREAK_MS : NORMAL_BREAK_MS;
    const nextAt = new Date(Date.now() + delay);

    sh.getRange(t.row, 5, 1, 10).setValues([[
      now, "break", "", "", "", nextAt,
      eventIndex, data[11] || now, data[12] || Utilities.getUuid(), ""
    ]]);
    SpreadsheetApp.flush();
    return tableState_(ss, { table: table });
  } finally {
    lock.releaseLock();
  }
}

function startEvent_(ss, d) {
  const lock = LockService.getScriptLock();
  lock.waitLock(6000);

  try {
    const table = clean_(d.table, 20).toUpperCase();
    const sh = ss.getSheetByName("TABLES");
    const t = ensureTable_(ss, table);
    const data = sh.getRange(t.row, 1, 1, TABLE_HEADERS.length).getValues()[0];

    if (String(data[5] || "") !== "break") return tablePayload_(ss, data);

    const nextAt = new Date(data[9]).getTime();
    const due = !nextAt || Date.now() >= nextAt;
    if (!due && !d.force) {
      return Object.assign(tablePayload_(ss, data), { locked: true });
    }

    const eventIndex = Math.max(1, Number(data[10]) || 1);
    const now = new Date();

    /* 偶数事件 = 全桌同步 After Dark；奇数 = 个人/跨桌 Social Event */
    if (eventIndex % 2 === 0) {
      sh.getRange(t.row, 2, 1, 9).setValues([[
        1, randomIndex_(LATE_COUNT), "", now,
        "question", "", "", "", ""
      ]]);
      sh.getRange(t.row, 14).setValue("late");
    } else {
      sh.getRange(t.row, 5).setValue(now);
      sh.getRange(t.row, 6).setValue("event");
      sh.getRange(t.row, 10).setValue("");
      sh.getRange(t.row, 14).setValue("");
    }

    SpreadsheetApp.flush();
    return tableState_(ss, { table: table });
  } finally {
    lock.releaseLock();
  }
}

function completeEvent_(ss, d) {
  const lock = LockService.getScriptLock();
  lock.waitLock(5000);

  try {
    const table = clean_(d.table, 20).toUpperCase();
    const sh = ss.getSheetByName("TABLES");
    const t = ensureTable_(ss, table);
    const data = sh.getRange(t.row, 1, 1, TABLE_HEADERS.length).getValues()[0];

    /* 第一位完成的人安排下一次；后完成的人不会把时间往后推 */
    if (String(data[5] || "") === "event") {
      const now = new Date();
      const nextAt = new Date(Date.now() + NORMAL_BREAK_MS);
      const eventIndex = Math.max(1, Number(data[10]) || 1) + 1;

      sh.getRange(t.row, 5).setValue(now);
      sh.getRange(t.row, 6).setValue("break");
      sh.getRange(t.row, 7, 1, 3).clearContent();
      sh.getRange(t.row, 10).setValue(nextAt);
      sh.getRange(t.row, 11).setValue(eventIndex);
      sh.getRange(t.row, 14).setValue("");
      SpreadsheetApp.flush();
    }

    return tableState_(ss, { table: table });
  } finally {
    lock.releaseLock();
  }
}


/* =====================================================
   MATCHING
===================================================== */

function queue_(ss, d) {
  const lock = LockService.getScriptLock();
  lock.waitLock(8000);

  try {
    const players = ss.getSheetByName("PLAYERS");
    let me = playerRow_(players, d.deviceId);
    if (!me) return { ok: false, error: "not_joined" };

    if (me.data[7]) return matchStatus_(ss, d);

    players.getRange(me.row, 5).setValue("queued");
    players.getRange(me.row, 7).setValue(new Date());
    SpreadsheetApp.flush();
    me = playerRow_(players, d.deviceId);

    const values = players.getDataRange().getValues();
    const myTable = String(me.data[2] || "").toUpperCase();
    const myHistory = parseHistory_(me.data[8]);
    const cutoff = Date.now() - 15 * 60 * 1000;
    const candidates = [];

    for (let i = 1; i < values.length; i++) {
      const r = values[i];
      const candidateId = String(r[0] || "");
      if (!candidateId || candidateId === String(d.deviceId)) continue;
      if (String(r[2] || "").toUpperCase() === myTable) continue;
      if (String(r[4] || "") !== "queued") continue;
      if (r[7]) continue;
      if (myHistory.includes(candidateId)) continue;
      const lastSeen = new Date(r[6]).getTime();
      if (!lastSeen || lastSeen < cutoff) continue;
      candidates.push({ row: i + 1, data: r });
    }

    if (!candidates.length) return { ok: true, waiting: true, match: null };

    const other = candidates[Math.floor(Math.random() * candidates.length)];
    const matchId = Utilities.getUuid();
    const aCode = randomCode_();
    let bCode = randomCode_();
    while (bCode === aCode) bCode = randomCode_();
    const eventIndex = Number(d.eventIndex || 0);
    const socialCycle = eventIndex > 0 ? Math.floor((eventIndex - 1) / 2) % 3 : -1;
    const tableVsTableMissions = [5, 6, 7];
    const missionIndex = socialCycle === 2
      ? tableVsTableMissions[randomIndex_(tableVsTableMissions.length)]
      : randomIndex_(MISSION_COUNT);

    const matches = ss.getSheetByName("MATCHES");
    matches.appendRow([
      matchId, String(d.deviceId), String(other.data[0]), aCode, bCode,
      false, false, "active", new Date(), "", missionIndex, false, false
    ]);

    players.getRange(me.row, 5).setValue("matched");
    players.getRange(me.row, 8).setValue(matchId);
    players.getRange(other.row, 5).setValue("matched");
    players.getRange(other.row, 8).setValue(matchId);
    SpreadsheetApp.flush();

    return matchStatus_(ss, d);
  } finally {
    lock.releaseLock();
  }
}

function matchStatus_(ss, d) {
  const players = ss.getSheetByName("PLAYERS");
  const me = playerRow_(players, d.deviceId);
  if (!me) return { ok: false, error: "not_joined" };

  const matchId = String(me.data[7] || "");
  if (!matchId) {
    return { ok: true, waiting: String(me.data[4] || "") === "queued", match: null };
  }

  const matches = ss.getSheetByName("MATCHES");
  const m = matchRow_(matches, matchId);
  if (!m) return { ok: false, error: "match_not_found" };

  const r = m.data;
  const isA = String(r[1]) === String(d.deviceId);
  const isB = String(r[2]) === String(d.deviceId);
  if (!isA && !isB) return { ok: false, error: "not_member" };

  const partnerId = String(isA ? r[2] : r[1]);
  const partner = playerRow_(players, partnerId);
  const myVerified = isA ? toBool_(r[5]) : toBool_(r[6]);
  const partnerVerified = isA ? toBool_(r[6]) : toBool_(r[5]);

  return {
    ok: true,
    waiting: false,
    match: {
      matchId: matchId,
      partnerNick: partner ? String(partner.data[1] || "PLAYER") : "PLAYER",
      partnerTable: partner ? String(partner.data[2] || "?") : "?",
      partnerId: partnerId,
      myCode: String(isA ? r[3] : r[4]),
      missionIndex: Number(r[10]) || 0,
      verified: myVerified,
      partnerVerified: partnerVerified,
      bothVerified: myVerified && partnerVerified,
      status: String(r[7] || "active")
    }
  };
}

function verify_(ss, d) {
  const lock = LockService.getScriptLock();
  lock.waitLock(5000);

  try {
    const matches = ss.getSheetByName("MATCHES");
    const m = matchRow_(matches, d.matchId);
    if (!m) return { ok: false, error: "match_not_found" };

    const r = m.data;
    const isA = String(r[1]) === String(d.deviceId);
    const isB = String(r[2]) === String(d.deviceId);
    if (!isA && !isB) return { ok: false, error: "not_member" };
    if (["canceled", "complete"].includes(String(r[7] || ""))) {
      return { ok: false, error: "match_closed" };
    }

    const expected = String(isA ? r[4] : r[3]);
    const input = String(d.partnerCode || "").trim();
    if (input !== expected) return { ok: false, verified: false, error: "wrong_code" };

    matches.getRange(m.row, isA ? 6 : 7).setValue(true);
    SpreadsheetApp.flush();

    const updated = matches.getRange(m.row, 1, 1, MATCH_HEADERS.length).getValues()[0];
    const both = toBool_(updated[5]) && toBool_(updated[6]);

    if (both) {
      matches.getRange(m.row, 8).setValue("verified");
      if (!updated[9]) matches.getRange(m.row, 10).setValue(new Date());
      SpreadsheetApp.flush();
    }

    return { ok: true, verified: true, bothVerified: both };
  } finally {
    lock.releaseLock();
  }
}

function cancelMatch_(ss, d) {
  const lock = LockService.getScriptLock();
  lock.waitLock(5000);

  try {
    const players = ss.getSheetByName("PLAYERS");
    const me = playerRow_(players, d.deviceId);
    if (!me) return { ok: false, error: "not_joined" };

    const matchId = String(me.data[7] || "");
    if (!matchId) {
      players.getRange(me.row, 5).setValue("active");
      return { ok: true };
    }

    const matches = ss.getSheetByName("MATCHES");
    const m = matchRow_(matches, matchId);
    if (!m) {
      players.getRange(me.row, 5).setValue("active");
      players.getRange(me.row, 8).setValue("");
      return { ok: true };
    }

    if (toBool_(m.data[5]) && toBool_(m.data[6])) {
      return { ok: false, error: "already_verified" };
    }

    matches.getRange(m.row, 8).setValue("canceled");
    [String(m.data[1]), String(m.data[2])].forEach(id => {
      const p = playerRow_(players, id);
      if (p && String(p.data[7] || "") === matchId) {
        players.getRange(p.row, 5).setValue("active");
        players.getRange(p.row, 8).setValue("");
      }
    });
    SpreadsheetApp.flush();
    return { ok: true };
  } finally {
    lock.releaseLock();
  }
}

function completeMatch_(ss, d) {
  const lock = LockService.getScriptLock();
  lock.waitLock(5000);

  try {
    const players = ss.getSheetByName("PLAYERS");
    const matches = ss.getSheetByName("MATCHES");
    const m = matchRow_(matches, d.matchId);
    if (!m) return { ok: false, error: "match_not_found" };

    const r = m.data;
    const isA = String(r[1]) === String(d.deviceId);
    const isB = String(r[2]) === String(d.deviceId);
    if (!isA && !isB) return { ok: false, error: "not_member" };
    if (!(toBool_(r[5]) && toBool_(r[6]))) return { ok: false, error: "not_verified" };

    const partnerId = String(isA ? r[2] : r[1]);
    const me = playerRow_(players, d.deviceId);
    if (me) {
      const history = parseHistory_(me.data[8]);
      if (!history.includes(partnerId)) history.push(partnerId);
      players.getRange(me.row, 5).setValue("active");
      players.getRange(me.row, 8).setValue("");
      players.getRange(me.row, 9).setValue(history.slice(-30).join(","));
    }

    matches.getRange(m.row, isA ? 12 : 13).setValue(true);
    SpreadsheetApp.flush();

    const updated = matches.getRange(m.row, 1, 1, MATCH_HEADERS.length).getValues()[0];
    if (toBool_(updated[11]) && toBool_(updated[12])) {
      matches.getRange(m.row, 8).setValue("complete");
    }

    SpreadsheetApp.flush();
    return { ok: true };
  } finally {
    lock.releaseLock();
  }
}


/* =====================================================
   HELPERS
===================================================== */

function playerRow_(sh, deviceId) {
  if (sh.getLastRow() < 2) return null;
  const values = sh.getRange(2, 1, sh.getLastRow() - 1, 9).getValues();
  const target = String(deviceId || "");
  for (let i = 0; i < values.length; i++) {
    if (String(values[i][0]) === target) return { row: i + 2, data: values[i] };
  }
  return null;
}

function tableRow_(sh, tableId) {
  if (sh.getLastRow() < 2) return null;
  const values = sh.getRange(2, 1, sh.getLastRow() - 1, TABLE_HEADERS.length).getValues();
  const target = String(tableId || "").toUpperCase();
  for (let i = 0; i < values.length; i++) {
    if (String(values[i][0] || "").toUpperCase() === target) {
      return { row: i + 2, data: values[i] };
    }
  }
  return null;
}

function matchRow_(sh, matchId) {
  if (sh.getLastRow() < 2) return null;
  const values = sh.getRange(2, 1, sh.getLastRow() - 1, MATCH_HEADERS.length).getValues();
  const target = String(matchId || "");
  for (let i = 0; i < values.length; i++) {
    if (String(values[i][0]) === target) return { row: i + 2, data: values[i] };
  }
  return null;
}

function parseHistory_(value) {
  return String(value || "").split(",").map(x => x.trim()).filter(Boolean);
}

function randomCode_() {
  return String(Math.floor(1000 + Math.random() * 9000));
}

function randomIndex_(count) {
  return Math.floor(Math.random() * Math.max(1, count));
}

function differentIndex_(count, oldIndex) {
  let x = randomIndex_(count);
  let tries = 0;
  while (x === Number(oldIndex) && tries < 12) {
    x = randomIndex_(count);
    tries++;
  }
  return x;
}

function toBool_(value) {
  return value === true || String(value).toLowerCase() === "true";
}

function clean_(value, maxLength) {
  return String(value || "").replace(/[<>]/g, "").trim().slice(0, maxLength || 100);
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
