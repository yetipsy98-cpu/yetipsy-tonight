/*
YÉ TIPSY · 月满杯盈 — MoonGame.gs
与现有 Tonight Code.gs 放在同一个、绑定 MINIGAME Sheet 的 Apps Script Project。
不需要 Sheet URL / Sheet ID。
本文件没有 doGet/doPost；由现有 Code.gs 路由进入。
*/
const MOON_CLAIMS = "MOON_GAME";
const MOON_SESSIONS = "MOON_SESSIONS";
const MOON_CONFIG = "MOON_CONFIG";
const MOON_REWARDS = "MOON_REWARDS";

const CLAIM_HEADERS = [
  "recovery_code","created_at","country","whatsapp","dice","ones",
  "reward_id","reward_name","community_opt_in","whatsapp_status",
  "sent_at","redeemed","redeemed_at"
];
const SESSION_HEADERS = [
  "unlock_token","created_at","expires_at","used_at","status",
  "reward_id","dice"
];
const CONFIG_HEADERS = ["key","value","note"];
const REWARD_HEADERS = [
  "reward_id","reward_name","display_ones","probability","enabled","sort_order"
];

function setupMoonGame() {
  const ss = getDB_();
  moon_ensureSheet_(ss, MOON_CLAIMS, CLAIM_HEADERS);
  moon_ensureSheet_(ss, MOON_SESSIONS, SESSION_HEADERS);
  const cfg = moon_ensureSheet_(ss, MOON_CONFIG, CONFIG_HEADERS);
  const rewards = moon_ensureSheet_(ss, MOON_REWARDS, REWARD_HEADERS);

  moon_defaultConfig_(cfg, "ACTIVITY_ENABLED", "TRUE", "TRUE=开放 / FALSE=关闭");
  moon_defaultConfig_(cfg, "STAFF_PASSWORD", "CHANGE-ME", "员工每局解锁密码");
  moon_defaultConfig_(cfg, "ADMIN_PASSWORD", "CHANGE-ADMIN", "Admin 页面密码");
  moon_defaultConfig_(cfg, "TOKEN_TTL_MINUTES", "5", "员工一次授权有效分钟");
  moon_defaultConfig_(cfg, "WHATSAPP_SEND_DAYS", "3", "奖励承诺发送工作日");

  if (rewards.getLastRow() < 2) {
    rewards.getRange(2,1,4,6).setValues([
      ["R5","断片指南系列 · 任一杯",5,0.5,"TRUE",1],
      ["R4","微醺特调系列 · 任一杯",4,2.0,"TRUE",2],
      ["R3","彩虹 Shot × 1",3,12.5,"TRUE",3],
      ["R0","RM5 Voucher",0,85.0,"TRUE",4]
    ]);
  }
  SpreadsheetApp.flush();
  return {ok:true, spreadsheet:ss.getName()};
}

function moonApi_(ss, d) {
  switch (String(d.subaction || "")) {
    case "unlock": return moon_unlock_(ss,d);
    case "roll": return moon_roll_(ss,d);
    case "claim": return moon_claim_(ss,d);
    case "adminLogin": return moon_adminLogin_(ss,d);
    case "adminState": return moon_adminState_(ss,d);
    case "adminSaveConfig": return moon_adminSaveConfig_(ss,d);
    case "adminSaveRewards": return moon_adminSaveRewards_(ss,d);
    case "adminUpdateClaim": return moon_adminUpdateClaim_(ss,d);
    default: return {ok:false,error:"unknown_moon_action",subaction:d.subaction||""};
  }
}

/* =====================================================
   SHEETS / CONFIG
===================================================== */

function moon_ensureSheet_(ss, name, headers) {
  let sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name);

  if (sh.getMaxColumns() < headers.length) {
    sh.insertColumnsAfter(
      sh.getMaxColumns(),
      headers.length - sh.getMaxColumns()
    );
  }

  sh.getRange(1,1,1,headers.length).setValues([headers]);
  sh.setFrozenRows(1);
  return sh;
}

function moon_defaultConfig_(sh, key, value, note) {
  if (!moon_configRow_(sh, key)) sh.appendRow([key,value,note]);
}

function moon_configRow_(sh, key) {
  if (!sh || sh.getLastRow() < 2) return null;

  const values = sh.getRange(
    2,1,sh.getLastRow()-1,3
  ).getValues();

  const target = String(key).toUpperCase();

  for (let i=0; i<values.length; i++) {
    if (String(values[i][0]).toUpperCase() === target) {
      return {
        row: i+2,
        value: values[i][1],
        note: values[i][2]
      };
    }
  }

  return null;
}

function moon_config_(ss, key, fallback) {
  const sh = ss.getSheetByName(MOON_CONFIG);
  const r = moon_configRow_(sh, key);
  return r ? r.value : fallback;
}

function moon_setConfig_(ss, key, value) {
  const sh = ss.getSheetByName(MOON_CONFIG);
  const r = moon_configRow_(sh, key);

  if (r) sh.getRange(r.row,2).setValue(value);
  else sh.appendRow([key,value,""]);
}

function moon_enabled_(ss) {
  return String(
    moon_config_(ss,"ACTIVITY_ENABLED","TRUE")
  ).toUpperCase() === "TRUE";
}

function moon_tokenTtl_(ss) {
  const n = Number(moon_config_(ss,"TOKEN_TTL_MINUTES","5"));
  return Math.max(
    1,
    Math.min(30, isFinite(n) ? n : 5)
  ) * 60000;
}


/* =====================================================
   CACHED CONFIGURABLE REWARD DRAW
   概率只在员工授权时读取；顾客按摇月亮时不访问后台。
===================================================== */
function moon_cachedRewards_(ss) {
  const cache = CacheService.getScriptCache();
  const key = "MOON_REWARD_CONFIG_V1";
  const hit = cache.get(key);
  if (hit) {
    try { return JSON.parse(hit); } catch(e) {}
  }

  const rewards = moon_rewards_(ss).filter(x => x.enabled);
  cache.put(key, JSON.stringify(rewards), 300); // 5分钟缓存
  return rewards;
}

function moon_clearRewardCache_() {
  CacheService.getScriptCache().remove("MOON_REWARD_CONFIG_V1");
}

function moon_preparedResult_(ss) {
  const rewards = moon_cachedRewards_(ss);
  if (!rewards.length) throw new Error("no_enabled_rewards");

  const total = rewards.reduce((sum,r)=>sum + Number(r.probability || 0),0);
  if (Math.abs(total - 100) > 0.001) throw new Error("probability_total_must_be_100");

  let x = Math.random() * 100;
  let chosen = rewards[rewards.length - 1];
  for (const r of rewards) {
    x -= Number(r.probability || 0);
    if (x < 0) { chosen = r; break; }
  }

  // 视觉骰子只负责对应中奖等级；中奖机会来自后台配置。
  let ones = Number(chosen.displayOnes || 0);
  if (chosen.id === "R0") ones = Math.floor(Math.random() * 3); // 0–2个1
  ones = Math.max(0, Math.min(5, ones));

  const dice = [];
  for (let i=0;i<ones;i++) dice.push(1);
  while (dice.length < 5) dice.push(2 + Math.floor(Math.random()*5));

  // 洗牌，避免「1」总在前面。
  for (let i=dice.length-1;i>0;i--) {
    const j=Math.floor(Math.random()*(i+1));
    const t=dice[i]; dice[i]=dice[j]; dice[j]=t;
  }

  return {
    rewardId: chosen.id,
    reward: chosen.name,
    displayOnes: ones,
    dice: dice
  };
}

/* =====================================================
   STAFF UNLOCK
===================================================== */

function moon_unlock_(ss, d) {
  if (!moon_enabled_(ss)) return {ok:false,error:"activity_closed"};

  const expected = String(moon_config_(ss,"STAFF_PASSWORD",""));
  if (!expected || expected === "CHANGE-ME") {
    return {ok:false,error:"staff_password_not_configured"};
  }
  if (String(d.password || "") !== expected) {
    return {ok:false,error:"wrong_password"};
  }

  const sh = ss.getSheetByName(MOON_SESSIONS);
  const token = Utilities.getUuid();
  const now = new Date();
  const expires = new Date(now.getTime() + moon_tokenTtl_(ss));

  // 员工授权时一次性生成真实 5 骰结果。
  // 顾客按“摇月亮”时不再请求服务器，所以揭晓无需等待网络。
  const result = moon_preparedResult_(ss);

  sh.appendRow([
    token,
    now,
    expires,
    "",
    "UNLOCKED",
    result.rewardId,
    result.dice.join(",")
  ]);

  return {
    ok:true,
    unlockToken:token,
    expiresAt:expires.toISOString(),
    rollResult:result
  };
}

function moon_session_(sh, token) {
  if (sh.getLastRow() < 2) return null;

  const values = sh.getRange(
    2,1,sh.getLastRow()-1,SESSION_HEADERS.length
  ).getValues();

  for (let i=0; i<values.length; i++) {
    if (String(values[i][0]) === String(token || "")) {
      return {row:i+2,data:values[i]};
    }
  }

  return null;
}

function moon_validSession_(ss, token) {
  const sh = ss.getSheetByName(MOON_SESSIONS);
  const s = moon_session_(sh, token);

  if (!s) return {ok:false,error:"invalid_unlock"};

  if (
    String(s.data[4]) !== "UNLOCKED" ||
    s.data[3]
  ) {
    return {ok:false,error:"unlock_used"};
  }

  const expires = new Date(s.data[2]).getTime();

  if (!expires || Date.now() > expires) {
    sh.getRange(s.row,5).setValue("EXPIRED");
    return {ok:false,error:"unlock_expired"};
  }

  return {
    ok:true,
    sheet:sh,
    session:s
  };
}

/* =====================================================
   REWARDS / ROLL
===================================================== */

function moon_rewards_(ss) {
  const sh = ss.getSheetByName(MOON_REWARDS);

  if (!sh || sh.getLastRow() < 2) return [];

  return sh.getRange(
    2,1,sh.getLastRow()-1,6
  ).getValues().map(r => ({
    id:String(r[0]),
    name:String(r[1]),
    displayOnes:Number(r[2]),
    probability:Number(r[3]), // legacy/display only; game ignores this field
    enabled:String(r[4]).toUpperCase()==="TRUE",
    sort:Number(r[5])
  })).sort((a,b)=>a.sort-b.sort);
}

function moon_pickReward_(ss) {
  const rows = moon_rewards_(ss).filter(
    x => x.enabled && x.probability > 0
  );

  if (!rows.length) {
    throw new Error("no_active_rewards");
  }

  const total = rows.reduce(
    (s,x)=>s+x.probability,0
  );

  if (Math.abs(total-100) > 0.001) {
    throw new Error(
      "reward_probability_must_equal_100"
    );
  }

  let r = Math.random() * 100;

  for (const x of rows) {
    r -= x.probability;
    if (r < 0) return x;
  }

  return rows[rows.length-1];
}

function moon_diceForOnes_(ones) {
  ones = Math.max(
    0,
    Math.min(5, Number(ones)||0)
  );

  const dice = [];

  for (let i=0; i<ones; i++) {
    dice.push(1);
  }

  while (dice.length < 5) {
    dice.push(
      2 + Math.floor(Math.random()*5)
    );
  }

  for (let i=dice.length-1; i>0; i--) {
    const j = Math.floor(
      Math.random()*(i+1)
    );
    const tmp=dice[i];
    dice[i]=dice[j];
    dice[j]=tmp;
  }

  return dice;
}

/*
Roll 后就把 reward + dice 锁在 SESSION。
这样 Claim 时不相信浏览器传回来的 reward。
*/
function moon_roll_(ss, d) {
  if (!moon_enabled_(ss)) return {ok:false,error:"activity_closed"};
  const check = moon_validSession_(ss,d.unlockToken);
  if (!check.ok) return check;

  const rewardId = String(check.session.data[5] || "");
  const diceText = String(check.session.data[6] || "");
  if (!rewardId || !diceText) return {ok:false,error:"roll_required"};

  const rw = moon_rewards_(ss).find(x=>x.id===rewardId);
  if (!rw) return {ok:false,error:"reward_not_found"};

  const dice = diceText.split(",").map(Number);
  return {
    ok:true,
    rewardId:rewardId,
    reward:rw.name,
    displayOnes:dice.filter(x=>x===1).length,
    dice:dice
  };
}

/* =====================================================
   CLAIM
===================================================== */

function moon_claim_(ss, d) {
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);

  try {
    const check = moon_validSession_(
      ss,d.unlockToken
    );

    if (!check.ok) return check;

    const rewardId =
      String(check.session.data[5] || "");

    const diceText =
      String(check.session.data[6] || "");

    if (!rewardId || !diceText) {
      return {ok:false,error:"roll_required"};
    }

    const rw = moon_rewards_(ss).find(
      x=>x.id===rewardId
    );

    if (!rw) {
      return {ok:false,error:"reward_not_found"};
    }

    const dice = diceText
      .split(",")
      .map(Number);

    const cc = String(
      d.countryCode || ""
    );

    const digits = String(
      d.phone || ""
    ).replace(/\D/g,"");

    const phone = cc + digits;

    if (
      cc === "+65" &&
      !/^\+65\d{8}$/.test(phone)
    ) {
      return {ok:false,error:"invalid_phone"};
    }

    if (
      cc === "+60" &&
      !/^\+60\d{9,11}$/.test(phone)
    ) {
      return {ok:false,error:"invalid_phone"};
    }

    if (!["+60","+65"].includes(cc)) {
      return {ok:false,error:"invalid_country"};
    }

    const claims =
      ss.getSheetByName(MOON_CLAIMS);

    const code =
      moon_recoveryCode_(claims);

    const now = new Date();

    claims.appendRow([
      code,
      now,
      cc==="+65" ? "SG" : "MY",
      phone,
      dice.join(","),
      rw.displayOnes,
      rw.id,
      rw.name,
      d.communityOptIn ? "YES" : "NO",
      "PENDING",
      "",
      "NO",
      ""
    ]);

    check.sheet.getRange(
      check.session.row,4
    ).setValue(now);

    check.sheet.getRange(
      check.session.row,5
    ).setValue("USED");

    SpreadsheetApp.flush();

    return {
      ok:true,
      recoveryCode:code,
      reward:rw.name,
      ones:rw.displayOnes,
      whatsapp:phone,
      status:"PENDING",
      sendWithinBusinessDays:
        Number(
          moon_config_(
            ss,
            "WHATSAPP_SEND_DAYS",
            "3"
          )
        ) || 3
    };

  } finally {
    lock.releaseLock();
  }
}

function moon_recoveryCode_(sh) {
  for (let i=0; i<30; i++) {
    const code =
      "YT-MOON-" +
      Utilities.getUuid()
        .replace(/-/g,"")
        .slice(0,8)
        .toUpperCase();

    if (sh.getLastRow() < 2) {
      return code;
    }

    const found =
      sh.getRange(
        2,1,sh.getLastRow()-1,1
      )
      .createTextFinder(code)
      .matchEntireCell(true)
      .findNext();

    if (!found) return code;
  }

  throw new Error(
    "recovery_code_generation_failed"
  );
}

/* =====================================================
   ADMIN
===================================================== */

function moon_adminLogin_(ss, d) {
  const expected = String(
    moon_config_(ss,"ADMIN_PASSWORD","")
  );

  if (
    !expected ||
    expected === "CHANGE-ADMIN"
  ) {
    /*
    默认密码仍然允许第一次登录，
    方便安装后直接进 Admin 修改。
    */
  }

  if (
    String(d.password || "") !== expected
  ) {
    return {
      ok:false,
      error:"wrong_admin_password"
    };
  }

  const token =
    Utilities.getUuid();

  CacheService
    .getScriptCache()
    .put(
      "moon_admin_"+token,
      "1",
      21600
    );

  return {
    ok:true,
    adminToken:token
  };
}

function moon_adminAuth_(d) {
  return !!CacheService
    .getScriptCache()
    .get(
      "moon_admin_" +
      String(d.adminToken || "")
    );
}

function moon_adminState_(ss, d) {
  if (!moon_adminAuth_(d)) {
    return {ok:false,error:"admin_auth"};
  }

  const claims = [];
  const sh = ss.getSheetByName(
    MOON_CLAIMS
  );

  if (sh && sh.getLastRow() >= 2) {
    const count = Math.min(
      100,
      sh.getLastRow()-1
    );

    const start =
      sh.getLastRow()-count+1;

    const rows =
      sh.getRange(
        start,
        1,
        count,
        CLAIM_HEADERS.length
      ).getValues();

    rows.reverse().forEach(r=>{
      claims.push({
        code:r[0],
        created:r[1],
        country:r[2],
        phone:r[3],
        dice:r[4],
        ones:r[5],
        rewardId:r[6],
        reward:r[7],
        community:r[8],
        status:r[9],
        sentAt:r[10],
        redeemed:r[11],
        redeemedAt:r[12]
      });
    });
  }

  return {
    ok:true,
    config:{
      activityEnabled:
        moon_enabled_(ss),
      tokenTtl:
        Number(
          moon_config_(
            ss,
            "TOKEN_TTL_MINUTES",
            "5"
          )
        ),
      sendDays:
        Number(
          moon_config_(
            ss,
            "WHATSAPP_SEND_DAYS",
            "3"
          )
        )
    },
    rewards:moon_rewards_(ss),
    claims:claims
  };
}

function moon_adminSaveConfig_(ss, d) {
  if (!moon_adminAuth_(d)) {
    return {ok:false,error:"admin_auth"};
  }

  if (
    typeof d.activityEnabled !==
    "undefined"
  ) {
    moon_setConfig_(
      ss,
      "ACTIVITY_ENABLED",
      d.activityEnabled
        ? "TRUE"
        : "FALSE"
    );
  }

  if (
    String(d.staffPassword || "")
      .trim()
  ) {
    moon_setConfig_(
      ss,
      "STAFF_PASSWORD",
      String(d.staffPassword).trim()
    );
  }

  if (
    String(d.adminPassword || "")
      .trim()
  ) {
    moon_setConfig_(
      ss,
      "ADMIN_PASSWORD",
      String(d.adminPassword).trim()
    );
  }

  if (d.tokenTtl) {
    const ttl = Math.max(
      1,
      Math.min(
        30,
        Number(d.tokenTtl)||5
      )
    );

    moon_setConfig_(
      ss,
      "TOKEN_TTL_MINUTES",
      String(ttl)
    );
  }

  SpreadsheetApp.flush();
  return {ok:true};
}

function moon_adminSaveRewards_(ss, d) {
  if (!moon_adminAuth_(d)) {
    return {ok:false,error:"admin_auth"};
  }

  const rows =
    Array.isArray(d.rewards)
      ? d.rewards
      : [];

  if (!rows.length) {
    return {ok:false,error:"no_rewards"};
  }

  const normalized =
    rows.map((x,i)=>({
      id:String(x.id || "").trim(),
      name:String(x.name || "").trim(),
      displayOnes:
        Math.max(
          0,
          Math.min(
            5,
            Number(x.displayOnes)||0
          )
        ),
      probability:
        Number(x.probability)||0,
      enabled:!!x.enabled,
      sort:i+1
    }));

  if (
    normalized.some(
      x=>!x.id || !x.name
    )
  ) {
    return {
      ok:false,
      error:"invalid_reward"
    };
  }

  const total =
    normalized
      .filter(x=>x.enabled)
      .reduce(
        (s,x)=>s+x.probability,
        0
      );

  if (Math.abs(total-100) > 0.001) {
    return {
      ok:false,
      error:"probability_total",
      total:total
    };
  }

  const sh =
    ss.getSheetByName(
      MOON_REWARDS
    );

  if (sh.getLastRow() > 1) {
    sh.getRange(
      2,
      1,
      sh.getLastRow()-1,
      6
    ).clearContent();
  }

  sh.getRange(
    2,
    1,
    normalized.length,
    6
  ).setValues(
    normalized.map(x=>[
      x.id,
      x.name,
      x.displayOnes,
      x.probability,
      x.enabled ? "TRUE" : "FALSE",
      x.sort
    ])
  );

  SpreadsheetApp.flush();

  moon_clearRewardCache_();
  return {ok:true};
}

function moon_adminUpdateClaim_(ss, d) {
  if (!moon_adminAuth_(d)) {
    return {ok:false,error:"admin_auth"};
  }

  const sh =
    ss.getSheetByName(
      MOON_CLAIMS
    );

  if (!sh || sh.getLastRow()<2) {
    return {ok:false,error:"not_found"};
  }

  const found =
    sh.getRange(
      2,
      1,
      sh.getLastRow()-1,
      1
    )
    .createTextFinder(
      String(d.code || "")
    )
    .matchEntireCell(true)
    .findNext();

  if (!found) {
    return {ok:false,error:"not_found"};
  }

  const row =
    found.getRow();

  const now =
    new Date();

  if (d.status === "SENT") {
    sh.getRange(row,10)
      .setValue("SENT");

    sh.getRange(row,11)
      .setValue(now);
  }

  if (d.status === "PENDING") {
    sh.getRange(row,10)
      .setValue("PENDING");

    sh.getRange(row,11)
      .setValue("");
  }

  if (d.status === "REDEEMED") {
    sh.getRange(row,12)
      .setValue("YES");

    sh.getRange(row,13)
      .setValue(now);
  }

  SpreadsheetApp.flush();

  return {ok:true};
}

/* =====================================================
   RESPONSE
===================================================== */

function moon_json_(obj) {
  return ContentService
    .createTextOutput(
      JSON.stringify(obj)
    )
    .setMimeType(
      ContentService.MimeType.JSON
    );
}
