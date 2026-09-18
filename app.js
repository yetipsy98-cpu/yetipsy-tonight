const app = document.getElementById("app");
const C = YT_CONTENT;
const A = YTAudio;
const B = YTBackend;

const VERSION = "2.3";

let state =
  JSON.parse(
    localStorage.getItem("yt_v2_state") || "{}"
  );

if (!state.deviceId) {
  state.deviceId =
    crypto.randomUUID
      ? crypto.randomUUID()
      : "d-" +
        Date.now() +
        "-" +
        Math.random().toString(36).slice(2);
}

state.stats =
  state.stats || {
    warm: 0,
    accepted: 0,
    completed: 0,
    verified: 0,
    skips: 0,
    peopleMet: 0
  };

save();

let heartbeatTimer = null;
let tablePoll = null;
let matchPoll = null;
let countdownRunning = false;


/* =====================================================
   HELPERS
===================================================== */

function save() {
  localStorage.setItem(
    "yt_v2_state",
    JSON.stringify(state)
  );
}

function esc(s) {
  return String(s || "").replace(
    /[<>&"']/g,
    c =>
      ({
        "<": "&lt;",
        ">": "&gt;",
        "&": "&amp;",
        '"': "&quot;",
        "'": "&#39;"
      }[c])
  );
}

function pick(a) {
  return a[Math.floor(Math.random() * a.length)];
}

function tap() {
  A.ensure();
  A.tap();
}

function toast(text, ms = 2200) {
  const t = document.createElement("div");
  t.className = "toast";
  t.textContent = text;

  document.body.appendChild(t);

  setTimeout(() => t.remove(), ms);
}

function shell(body, progress = 0, top = false) {

  app.innerHTML = `
    <div class="shell">

      <div class="top">
        <div class="logo">YETIPSY</div>
        <button class="iconBtn" id="audioBtn">
          SOUND
        </button>
      </div>

      <div class="progress">
        <i style="width:${progress}%"></i>
      </div>

      <main class="scene ${top ? "topScene" : ""}">
        ${body}
      </main>

    </div>
  `;

  const audio =
    document.getElementById("audioBtn");

  if (audio) audio.onclick = audioPanel;
}

function setButtonLoading(
  button,
  loading,
  text = "LOADING…"
) {

  if (!button) return;

  if (loading) {

    if (!button.dataset.oldText) {
      button.dataset.oldText =
        button.textContent;
    }

    button.disabled = true;
    button.textContent = text;

  } else {

    button.disabled = false;

    if (button.dataset.oldText) {
      button.textContent =
        button.dataset.oldText;
    }
  }
}


/* =====================================================
   AUDIO
===================================================== */

function audioPanel() {

  const s = A.get();

  const d =
    document.createElement("div");

  d.className = "soundPanel";

  d.innerHTML = `
    <div class="kicker">
      AUDIO & HAPTICS
    </div>

    ${toggleRow("VOICE", "voice", s.voice)}
    ${toggleRow("SFX", "sfx", s.sfx)}
    ${toggleRow(
      "VIBRATION",
      "vibration",
      s.vibration
    )}

    <button
      class="btn secondary"
      id="closeAudio">
      DONE
    </button>
  `;

  document.body.appendChild(d);

  d.querySelectorAll("[data-toggle]")
    .forEach(x => {

      x.onclick = () => {

        const k = x.dataset.toggle;
        const v = !A.get()[k];

        A.set(k, v);

        x.classList.toggle(
          "on",
          v
        );

        if (k === "voice" && v) {
          A.countWord("READY");
        }
      };
    });

  d.querySelector("#closeAudio").onclick =
    () => d.remove();
}

function toggleRow(label, key, on) {

  return `
    <div class="toggleRow">

      <b>${label}</b>

      <div
        class="toggle ${on ? "on" : ""}"
        data-toggle="${key}">

        <i></i>

      </div>

    </div>
  `;
}


/* =====================================================
   HOME
===================================================== */

function home() {

  shell(`
    <div class="kicker">
      TONIGHT · ${VERSION}
    </div>

    <h1 class="display">
      今晚<br>有局。
    </h1>

    <p class="lead">
      一个人，一台手机。<br>
      <b style="color:var(--ink)">
        每个人，都有自己的今晚。
      </b>
    </p>

    <div class="card">

      <span class="pill">
        ONE PERSON · ONE PHONE
      </span>

      <p
        class="lead"
        style="margin:14px 0 0">

        同桌一起玩，
        但每个人都有自己的身份和路线。

      </p>

    </div>

    <button
      class="btn primary"
      id="enter">
      ENTER TONIGHT
    </button>

    <div class="footer">
      仅限达到当地合法饮酒年龄的成年人参与
      · 可随时跳过互动
      · 理性饮酒
    </div>
  `, 3);

  document.getElementById("enter").onclick =
    () => {
      tap();
      soundGate();
    };
}


/* =====================================================
   SOUND
===================================================== */

function soundGate() {

  shell(`
    <div class="kicker">
      BEFORE WE START
    </div>

    <h2 class="title">
      今晚有些东西，<br>
      要听才好玩。
    </h2>

    <p class="lead">
      倒数会真正念出
      READY · THREE · TWO · ONE · POINT。
    </p>

    <button
      class="btn primary"
      id="soundOn">
      ENTER WITH SOUND
    </button>

    <button
      class="btn secondary"
      id="quiet">
      KEEP IT QUIET
    </button>
  `, 7);

  document.getElementById("soundOn").onclick =
    () => {
      A.allOn();
      A.ensure();
      tap();
      profile();
    };

  document.getElementById("quiet").onclick =
    () => {
      A.quiet();
      profile();
    };
}


/* =====================================================
   PROFILE
===================================================== */

function profile() {

  shell(`
    <div class="kicker">
      01 · YOUR PASS
    </div>

    <h2 class="title">
      先拿你的今晚身份。
    </h2>

    <p class="lead">
      不用手机号，不用注册。
    </p>

    <div class="card">

      <label class="small">
        YOUR NAME / NICKNAME
      </label>

      <input
        class="field"
        id="nick"
        maxlength="18"
        placeholder="例如：Xiang"
        value="${esc(state.nick || "")}">

      <div style="height:12px"></div>

      <label class="small">
        你现在坐哪一桌？
      </label>

      <input
        class="field"
        id="table"
        maxlength="12"
        placeholder="例如：A3"
        value="${esc(state.table || "")}">

    </div>

    <button
      class="btn primary"
      id="next">
      CREATE MY PASS
    </button>
  `, 12);

  document.getElementById("next").onclick =
    () => {

      const nick =
        document
          .getElementById("nick")
          .value
          .trim();

      const table =
        document
          .getElementById("table")
          .value
          .trim()
          .toUpperCase();

      if (!nick || !table) {
        return toast(
          "先填昵称和桌号"
        );
      }

      state.nick = nick;
      state.table = table;

      save();
      tap();

      mode();
    };
}


/* =====================================================
   MODE
===================================================== */

function mode() {

  shell(`
    <div class="kicker">
      02 · YOUR ROUTE
    </div>

    <h2 class="title">
      今晚想怎么玩？
    </h2>

    <div class="choices">

      <button
        class="choice"
        data-m="chill">

        <strong>CHILL</strong>

        <span>
          主要跟自己朋友玩。
        </span>

      </button>

      <button
        class="choice"
        data-m="open">

        <strong>OPEN</strong>

        <span>
          愿意认识其他桌的一个人。
        </span>

      </button>

      <button
        class="choice"
        data-m="surprise">

        <strong>SURPRISE ME</strong>

        <span>
          把路线交给系统。
        </span>

      </button>

    </div>
  `, 18);

  document
    .querySelectorAll("[data-m]")
    .forEach(button => {

      button.onclick = async () => {

        /*
        点击马上给反馈，
        不再出现“按了没反应”
        */

        document
          .querySelectorAll("[data-m]")
          .forEach(x => {
            x.disabled = true;
          });

        state.mode =
          button.dataset.m;

        save();
        tap();

        button.querySelector("span").textContent =
          "CONNECTING…";

        const result =
          await B.join({
            deviceId:
              state.deviceId,

            nick:
              state.nick,

            table:
              state.table,

            mode:
              state.mode
          });

        if (!result.ok) {

          document
            .querySelectorAll("[data-m]")
            .forEach(x => {
              x.disabled = false;
            });

          button.querySelector("span").textContent =
            "连接失败，请再试一次";

          return toast(
            result.error === "timeout"
              ? "后台响应较慢，请再按一次"
              : "无法连接 YETIPSY 后台"
          );
        }

        startHeartbeat();

        personalWarm();
      };
    });
}


/* =====================================================
   HEARTBEAT
===================================================== */

function startHeartbeat() {

  clearInterval(
    heartbeatTimer
  );

  /*
  90 秒一次即可。
  不需要频繁写 Google Sheet。
  */

  heartbeatTimer =
    setInterval(() => {

      B.heartbeat({
        deviceId:
          state.deviceId
      });

    }, 90000);
}


/* =====================================================
   TABLE SYNC
===================================================== */

async function personalWarm() {

  clearInterval(tablePoll);

  shell(`
    <div class="kicker">
      03 · TABLE SYNC
    </div>

    <h2 class="title">
      正在同步你的桌子…
    </h2>

    <div class="waiting"></div>
  `, 25);

  const r =
    await B.tableState({
      deviceId:
        state.deviceId,

      table:
        state.table
    });

  if (!r.ok) {

    shell(`
      <div class="kicker">
        TABLE CONNECTION
      </div>

      <h2 class="title">
        暂时连不到桌子。
      </h2>

      <p class="lead">
        不会进入 Demo。
        请重新连接后台。
      </p>

      <button
        class="btn primary"
        id="retry">
        RETRY
      </button>
    `, 25);

    document
      .getElementById("retry")
      .onclick =
      personalWarm;

    return;
  }

  state.tableRound =
    Number(r.round) || 1;

  state.currentWarm =
    C.warm[
      (Number(r.questionIndex) || 0)
      % C.warm.length
    ];

  save();

  renderTableWarm(r);
}


function renderTableWarm(r) {

  clearInterval(tablePoll);

  state.tableRound =
    Number(r.round) || 1;

  state.currentWarm =
    C.warm[
      (Number(r.questionIndex) || 0)
      % C.warm.length
    ];

  save();

  shell(`
    <div class="kicker">
      03 · TABLE SYNC · ROUND
      ${state.tableRound}
    </div>

    <span class="pill">
      TABLE ${esc(state.table)}
    </span>

    <div
      class="card"
      style="margin-top:14px">

      <div class="question">
        ${esc(state.currentWarm)}
      </div>

      <p class="small">
        同桌所有手机看到同一题。
        任何一个人按开始，
        全桌一起倒数。
      </p>

    </div>

    <button
      class="btn primary"
      id="count">

      ${
        r.countdownAt
          ? "GET READY…"
          : "START FOR THE TABLE"
      }

    </button>

    <button
      class="btn secondary"
      id="refresh">
      SYNC NOW
    </button>
  `, 28);

  const count =
    document.getElementById("count");

  document
    .getElementById("refresh")
    .onclick =
    personalWarm;

  count.onclick =
    async () => {

      if (countdownRunning) {
        return;
      }

      tap();

      setButtonLoading(
        count,
        true,
        "STARTING…"
      );

      const x =
        await B.startCountdown({
          deviceId:
            state.deviceId,

          table:
            state.table
        });

      if (!x.ok) {

        setButtonLoading(
          count,
          false
        );

        return toast(
          "开始失败，请再试一次"
        );
      }

      watchTableCountdown(
        x.countdownAt
      );
    };

  if (r.countdownAt) {

    watchTableCountdown(
      r.countdownAt
    );

    return;
  }

  /*
  Apps Script + Sheet 不适合 900ms 一次。
  改成 2 秒。
  */

  tablePoll =
    setInterval(
      pollTable,
      2000
    );
}


async function pollTable() {

  if (countdownRunning) {
    return;
  }

  const x =
    await B.tableState({
      deviceId:
        state.deviceId,

      table:
        state.table
    });

  if (!x.ok) {
    return;
  }

  if (x.countdownAt) {

    clearInterval(
      tablePoll
    );

    watchTableCountdown(
      x.countdownAt
    );

    return;
  }

  /*
  另一台手机已经推进下一轮
  */

  if (
    Number(x.round) !==
    Number(state.tableRound)
  ) {

    clearInterval(
      tablePoll
    );

    renderTableWarm(x);
  }
}


function watchTableCountdown(iso) {

  if (countdownRunning) {
    return;
  }

  clearInterval(tablePoll);

  const target =
    new Date(iso).getTime();

  if (!target) {
    return;
  }

  countdownRunning = true;

  const wait =
    Math.max(
      0,
      target - Date.now()
    );

  setTimeout(
    () => {

      countdown(
        () => {
          countdownRunning = false;
          finishTableRound();
        }
      );

    },
    wait
  );
}


async function finishTableRound() {

  state.stats.warm++;
  save();

  /*
  两轮 Table Warm Up
  */

  if (state.stats.warm < 2) {

    const oldRound =
      Number(state.tableRound) || 1;

    shell(`
      <div class="kicker">
        TABLE SYNC
      </div>

      <h2 class="title">
        下一题准备中…
      </h2>

      <div class="waiting"></div>
    `, 32);

    const r =
      await B.nextTableRound({
        deviceId:
          state.deviceId,

        table:
          state.table,

        currentRound:
          oldRound
      });

    if (!r.ok) {

      toast(
        "同步下一题失败，正在重试"
      );

      setTimeout(
        personalWarm,
        1500
      );

      return;
    }

    /*
    后端是唯一真相。
    不在手机本地随机下一题。
    */

    renderTableWarm(r);

    return;
  }

  branchHub();
}


/* =====================================================
   COUNTDOWN
===================================================== */

async function countdown(done) {

  A.ensure();

  const steps = [

    {
      screen: "READY",
      voice: "READY",
      ms: 900,
      cls: "word"
    },

    {
      screen: "3",
      voice: "THREE",
      ms: 850,
      cls: ""
    },

    {
      screen: "2",
      voice: "TWO",
      ms: 850,
      cls: ""
    },

    {
      screen: "1",
      voice: "ONE",
      ms: 850,
      cls: ""
    },

    {
      screen: "POINT!",
      voice: "POINT",
      ms: 800,
      cls: "point"
    }
  ];

  const overlay =
    document.createElement("div");

  overlay.className =
    "countdown";

  document.body.appendChild(
    overlay
  );

  for (const x of steps) {

    overlay.innerHTML = `
      <div>

        <div class="readyText">
          ${
            x.screen === "READY"
              ? "EVERYONE"
              : ""
          }
        </div>

        <div
          class="countNum ${x.cls}">

          ${x.screen}

        </div>

      </div>
    `;

    if (x.voice === "POINT") {
      A.impact();
    }

    A.countWord(x.voice);

    await new Promise(
      resolve =>
        setTimeout(
          resolve,
          x.ms
        )
    );
  }

  overlay.remove();

  done();
}


/* =====================================================
   ROUTE
===================================================== */

function branchHub() {

  if (state.mode === "chill") {
    return chillRoute();
  }

  if (state.mode === "open") {
    return openRoute();
  }

  return Math.random() < 0.58
    ? openRoute(true)
    : chillRoute(true);
}


function chillRoute(
  surprise = false
) {

  const q = pick(C.chill);

  shell(`
    <div class="kicker">
      ${
        surprise
          ? "SURPRISE ROUTE"
          : "CHILL ROUTE"
      }
    </div>

    <h2 class="title">
      ${
        surprise
          ? "今晚先不把你送出去。"
          : "留在自己桌，也可以很好玩。"
      }
    </h2>

    <div class="card">

      <span class="pill">
        YOUR SOLO PROMPT
      </span>

      <div
        class="question"
        style="margin-top:14px">

        ${esc(q)}

      </div>

    </div>

    <button
      class="btn primary"
      id="done">
      DONE
    </button>

    <button
      class="btn secondary"
      id="match">
      我改变主意，想 Match
    </button>
  `, 43);

  document.getElementById("done").onclick =
    () => {

      state.stats.completed++;
      save();
      tap();

      chillDecision();
    };

  document.getElementById("match").onclick =
    () => {

      tap();

      openRoute(true);
    };
}


function chillDecision() {

  shell(`
    <div class="kicker">
      YOUR CHOICE MATTERS
    </div>

    <h2 class="title">
      接下来你决定。
    </h2>

    <div class="choices">

      <button
        class="choice"
        id="stay">

        <strong>
          STAY CHILL
        </strong>

        <span>
          继续朋友桌路线。
        </span>

      </button>

      <button
        class="choice"
        id="risk">

        <strong>
          ONE MATCH
        </strong>

        <span>
          只认识一个人。
        </span>

      </button>

    </div>
  `, 52);

  document.getElementById("stay").onclick =
    () => {

      state.routeFinal =
        "chill";

      save();
      tap();

      deepSolo();
    };

  document.getElementById("risk").onclick =
    () => {

      state.routeFinal =
        "hybrid";

      save();
      tap();

      openRoute(true);
    };
}


/* =====================================================
   OPEN / MATCH
===================================================== */

function openRoute(
  fromBranch = false
) {

  shell(`
    <div class="kicker">
      ${
        fromBranch
          ? "ONE MATCH"
          : "OPEN ROUTE"
      }
    </div>

    <h2 class="title">
      一人一手机。<br>
      一人一个 Match。
    </h2>

    <p class="lead">
      系统只会从其他桌寻找
      一个独立玩家给你。
    </p>

    <div class="card">

      <div class="identity">

        <div class="avatar">
          ${esc(
            state.nick
              .slice(0, 1)
              .toUpperCase()
          )}
        </div>

        <div>

          <b>
            ${esc(state.nick)}
          </b>

          <span>
            TABLE
            ${esc(state.table)}
          </span>

        </div>

      </div>

    </div>

    <button
      class="btn primary"
      id="queue">
      FIND MY MATCH
    </button>

    <button
      class="btn secondary"
      id="back">
      NOT NOW
    </button>
  `, 48);

  document.getElementById("back").onclick =
    () => {

      state.stats.skips++;

      state.routeFinal =
        "observer";

      save();
      tap();

      deepSolo();
    };

  document.getElementById("queue").onclick =
    () => {

      tap();
      queueForMatch();
    };
}


async function queueForMatch() {

  clearInterval(matchPoll);

  shell(`
    <div class="kicker">
      MATCHING
    </div>

    <h2 class="title">
      正在找另一个人。
    </h2>

    <div class="waiting"></div>

    <p
      class="lead"
      style="text-align:center">

      只匹配其他桌的玩家。<br>
      如果暂时没有其他人，
      系统会继续等待。

    </p>

    <div
      class="small"
      id="matchStatus"
      style="text-align:center">

      CONNECTING…

    </div>

    <button
      class="btn secondary"
      id="cancel">
      CANCEL
    </button>
  `, 55);

  document.getElementById("cancel").onclick =
    () => {

      clearInterval(matchPoll);

      state.stats.skips++;

      save();

      deepSolo();
    };

  const statusEl =
    document.getElementById(
      "matchStatus"
    );

  const r =
    await B.queue({
      deviceId:
        state.deviceId,

      nick:
        state.nick,

      table:
        state.table,

      mode:
        state.mode
    });

  if (!r.ok) {

    statusEl.textContent =
      "连接失败";

    toast(
      r.error === "timeout"
        ? "后台响应较慢，请重新尝试"
        : "Match 后台连接失败"
    );

    setTimeout(
      openRoute,
      1200
    );

    return;
  }

  if (r.match) {

    return showMatch(
      r.match
    );
  }

  statusEl.textContent =
    "WAITING FOR ANOTHER TABLE…";

  /*
  不再有 DEMO。
  只有真人 Match。
  */

  matchPoll =
    setInterval(
      checkMatch,
      3000
    );
}


async function checkMatch() {

  const s =
    await B.matchStatus({
      deviceId:
        state.deviceId
    });

  if (!s.ok) {
    return;
  }

  if (s.match) {

    clearInterval(
      matchPoll
    );

    showMatch(
      s.match
    );
  }
}


function showMatch(m) {

  clearInterval(matchPoll);

  state.match = m;
  state.stats.accepted++;

  save();

  A.impact();

  shell(`
    <div class="kicker">
      MATCH FOUND
    </div>

    <h2 class="title">
      找到你的 Match。
    </h2>

    <div class="card matchCard">

      <span class="pill">
        YOUR MATCH
      </span>

      <div class="matchName">
        ${esc(m.partnerNick)}
      </div>

      <div class="tableBadge">
        TABLE
        ${esc(m.partnerTable)}
      </div>

      <p
        class="lead"
        style="margin-top:18px">

        去找到这个人。
        对方手机也会显示你的昵称和桌号。

      </p>

    </div>

    <button
      class="btn primary"
      id="meet">
      I FOUND THEM
    </button>

    <button
      class="btn secondary"
      id="cant">
      找不到
    </button>
  `, 63);

  document.getElementById("cant").onclick =
    () => {

      /*
      当前 Code.gs 尚无 cancelMatch。
      不直接重新 queue，
      避免重复返回同一个 active match。
      */

      state.stats.skips++;
      save();

      toast(
        "这个 Match 目前仍为你保留"
      );
    };

  document.getElementById("meet").onclick =
    () => {

      tap();

      verificationIntro();
    };
}


/* =====================================================
   VERIFY
===================================================== */

function verificationIntro() {

  const m =
    state.match;

  shell(`
    <div class="kicker">
      VERIFY THE CONNECTION
    </div>

    <h2 class="title">
      真的找到对方才算。
    </h2>

    <p class="lead">
      把你的 4 位码给对方，
      同时输入对方手机上的 4 位码。
    </p>

    <div class="card">

      <div class="small">
        SHOW THIS TO
        ${esc(m.partnerNick)}
      </div>

      <div class="code">
        ${esc(m.myCode || "----")}
      </div>

    </div>

    <button
      class="btn primary"
      id="input">
      ENTER THEIR CODE
    </button>

    <button
      class="btn secondary"
      id="notfound">
      返回
    </button>
  `, 70);

  document.getElementById("notfound").onclick =
    () => showMatch(m);

  document.getElementById("input").onclick =
    verifyCode;
}


function verifyCode() {

  shell(`
    <div class="kicker">
      CONNECTION CHECK
    </div>

    <h2 class="title">
      输入对方的 4 位码。
    </h2>

    <div class="card">

      <input
        class="field"
        id="codeInput"
        inputmode="numeric"
        maxlength="4"
        placeholder="0000"
        style="
          text-align:center;
          font-size:34px;
          letter-spacing:.22em;
          font-weight:900;
        ">

    </div>

    <button
      class="btn primary"
      id="verify">
      VERIFY
    </button>

    <button
      class="btn secondary"
      id="showMine">
      返回看我的码
    </button>
  `, 74);

  document.getElementById("showMine").onclick =
    verificationIntro;

  document.getElementById("verify").onclick =
    async () => {

      const button =
        document.getElementById(
          "verify"
        );

      const code =
        document
          .getElementById(
            "codeInput"
          )
          .value
          .trim();

      if (!/^\d{4}$/.test(code)) {

        return toast(
          "需要 4 位数字"
        );
      }

      setButtonLoading(
        button,
        true,
        "VERIFYING…"
      );

      const m =
        state.match;

      const r =
        await B.verify({
          deviceId:
            state.deviceId,

          matchId:
            m.matchId,

          partnerCode:
            code
        });

      if (!r.ok) {

        setButtonLoading(
          button,
          false
        );

        return toast(
          r.error === "wrong_code"
            ? "码不对，看看对方手机"
            : "验证失败，请再试一次"
        );
      }

      /*
      自己验证成功，但对方还没验证。
      不提前宣布双方成功。
      */

      if (!r.bothVerified) {

        waitForPartnerVerification();

        return;
      }

      verificationSuccess();
    };
}


function waitForPartnerVerification() {

  shell(`
    <div class="kicker">
      YOUR CODE IS VERIFIED
    </div>

    <h2 class="title">
      等对方确认你。
    </h2>

    <div class="waiting"></div>

    <p class="lead">
      你的验证码正确。<br>
      对方也输入你的码后，
      会自动继续。
    </p>
  `, 77);

  clearInterval(matchPoll);

  matchPoll =
    setInterval(
      async () => {

        const s =
          await B.matchStatus({
            deviceId:
              state.deviceId
          });

        /*
        后端双方验证完成后会清掉 current_match。
        */

        if (
          s.ok &&
          (
            (
              s.match &&
              s.match.bothVerified
            ) ||
            !s.match
          )
        ) {

          clearInterval(
            matchPoll
          );

          verificationSuccess();
        }

      },
      2500
    );
}


function verificationSuccess() {

  clearInterval(matchPoll);

  state.stats.verified++;
  state.stats.peopleMet++;
  state.stats.completed++;

  save();

  A.impact();

  shell(`
    <div class="successMark">
      ✓
    </div>

    <div class="kicker">
      CONNECTION VERIFIED
    </div>

    <h2 class="title">
      你们真的找到彼此了。
    </h2>

    <div class="card">

      <span class="pill">
        UNLOCKED
      </span>

      <div
        class="question"
        style="margin-top:14px">

        ${esc(pick(C.deep))}

      </div>

      <p class="small">
        两个人都回答。
        聊起来就把手机收起来。
      </p>

    </div>

    <button
      class="btn primary"
      id="continue">
      DONE
    </button>
  `, 80);

  document.getElementById("continue").onclick =
    () => {

      tap();

      afterMatchChoice();
    };
}


/* =====================================================
   AFTER MATCH
===================================================== */

function afterMatchChoice() {

  shell(`
    <div class="kicker">
      AFTER THE MATCH
    </div>

    <h2 class="title">
      接下来你决定。
    </h2>

    <div class="choices">

      <button
        class="choice"
        id="rest">

        <strong>
          BACK TO MY TABLE
        </strong>

        <span>
          回朋友桌。
        </span>

      </button>

      <button
        class="choice"
        id="another">

        <strong>
          ONE MORE MATCH
        </strong>

        <span>
          再认识一个人。
        </span>

      </button>

    </div>
  `, 84);

  document.getElementById("rest").onclick =
    () => {

      state.routeFinal =
        "connector";

      delete state.match;

      save();
      tap();

      deepSolo();
    };

  document.getElementById("another").onclick =
    () => {

      state.routeFinal =
        "connector";

      delete state.match;

      save();
      tap();

      openRoute();
    };
}


/* =====================================================
   FINAL QUESTION
===================================================== */

function deepSolo() {

  const q =
    pick(C.deep);

  shell(`
    <div class="kicker">
      ONE LAST CARD
    </div>

    <h2 class="title">
      留一个问题给今晚。
    </h2>

    <div class="card">

      <div class="question">
        ${esc(q)}
      </div>

      <p class="small">
        可以问朋友、
        刚认识的人，
        也可以自己回答。
      </p>

    </div>

    <button
      class="btn primary"
      id="done">
      I'M DONE
    </button>

    <button
      class="btn secondary"
      id="swap">
      换一个
    </button>
  `, 89);

  document.getElementById("swap").onclick =
    () => {

      state.stats.skips++;
      save();

      deepSolo();
    };

  document.getElementById("done").onclick =
    () => {

      state.stats.completed++;

      save();
      tap();

      taste();
    };
}


/* =====================================================
   TASTE
===================================================== */

function taste() {

  shell(`
    <div class="kicker">
      BARTENDER DISCOVERY
    </div>

    <h2 class="title">
      今晚想喝什么方向？
    </h2>

    <p class="lead">
      这是推荐，不是购买要求；
      也可以选择无酒精版本。
    </p>

    <div class="grid2">

      <button
        class="choice taste"
        data-t="sweet">

        <strong>甜</strong>
        <span>果香 / 顺口</span>

      </button>

      <button
        class="choice taste"
        data-t="sour">

        <strong>酸</strong>
        <span>明亮 / 清醒</span>

      </button>

      <button
        class="choice taste"
        data-t="fresh">

        <strong>清爽</strong>
        <span>柑橘 / 气泡</span>

      </button>

      <button
        class="choice taste"
        data-t="help">

        <strong>救我</strong>
        <span>让 Bartender 问我</span>

      </button>

    </div>

    <div id="rec"></div>

    <button
      class="btn secondary"
      id="end">
      SEE MY NIGHT
    </button>
  `, 94);

  const map = {

    sweet: [
      "FRUITY / SMOOTH",
      "甜一点，但不要腻。"
    ],

    sour: [
      "BRIGHT / SHARP",
      "酸感明显一点。"
    ],

    fresh: [
      "LIGHT / FRESH",
      "清爽、柑橘或气泡方向。"
    ],

    help: [
      "BARTENDER CHOICE",
      "你先问我三个问题，再帮我选。"
    ]
  };

  document
    .querySelectorAll("[data-t]")
    .forEach(button => {

      button.onclick = () => {

        state.taste =
          button.dataset.t;

        save();
        tap();

        const r =
          map[button.dataset.t];

        document.getElementById(
          "rec"
        ).innerHTML = `
          <div
            class="card"
            style="margin-top:12px">

            <span class="pill">
              ${r[0]}
            </span>

            <div
              class="question"
              style="margin-top:12px">

              “${r[1]}”

            </div>

            <p class="small">
              把这句话给 Bartender 看即可。
            </p>

          </div>
        `;
      };
    });

  document.getElementById("end").onclick =
    () => {

      tap();

      ending();
    };
}


/* =====================================================
   ENDING
===================================================== */

function ending() {

  const s =
    state.stats;

  let type;
  let title;
  let copy;

  if (s.verified >= 2) {

    type =
      "THE CONNECTOR";

    title =
      "你今晚真的把人连起来了。";

    copy =
      `${s.peopleMet} 个 verified connections。`;

  } else if (s.verified === 1) {

    type =
      "ONE GOOD MATCH";

    title =
      "认识一个，就够了。";

    copy =
      "至少今晚结束前，有一个人不再完全是陌生人。";

  } else if (
    state.mode === "chill" &&
    s.skips < 3
  ) {

    type =
      "THE HOME TABLE";

    title =
      "你没有到处跑。";

    copy =
      "但你自己的朋友已经够你玩了。";

  } else if (
    s.skips >= 3 ||
    state.routeFinal === "observer"
  ) {

    type =
      "PROFESSIONAL OBSERVER";

    title =
      "你成功避开了大部分社交任务。";

    copy =
      "看戏也是今晚的一种玩法。";

  } else if (
    state.mode === "surprise"
  ) {

    type =
      "CHAOS ENJOYER";

    title =
      "你把路线交给系统了。";

    copy =
      "今晚走了一条随机路线。";

  } else {

    type =
      "YOUR OWN NIGHT";

    title =
      "没有标准答案。";

    copy =
      "你走的是自己的路线。";
  }

  shell(`
    <div class="resultTag">
      TONIGHT TYPE
    </div>

    <div class="endingType">
      ${type}
    </div>

    <h2 class="title">
      ${title}
    </h2>

    <p class="lead">
      ${copy}
    </p>

    <div class="grid2">

      <div class="stat">
        <b>${s.warm}</b>
        <span>WARM UPS</span>
      </div>

      <div class="stat">
        <b>${s.verified}</b>
        <span>VERIFIED</span>
      </div>

      <div class="stat">
        <b>${s.peopleMet}</b>
        <span>PEOPLE MET</span>
      </div>

      <div class="stat">
        <b>${s.skips}</b>
        <span>SKIPS</span>
      </div>

    </div>

    <button
      class="btn primary"
      id="again">
      BACK TO TONIGHT
    </button>

    <button
      class="btn tertiary"
      id="reset">
      RESET MY NIGHT
    </button>

    <div class="footer">
      YETIPSY · 今晚有局<br>
      ONE PERSON · ONE PHONE
    </div>
  `, 100);

  document.getElementById("again").onclick =
    () => {

      tap();

      afterMatchChoice();
    };

  document.getElementById("reset").onclick =
    () => {

      localStorage.removeItem(
        "yt_v2_state"
      );

      location.reload();
    };
}


/* =====================================================
   START
===================================================== */

home();
