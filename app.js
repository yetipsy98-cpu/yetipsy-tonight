const app = document.getElementById("app");
const C = YT_CONTENT;
const A = YTAudio;
const B = YTBackend;

const VERSION = "2.4.3";
const STORAGE_KEY = "yt_v24_state";

const oldState = JSON.parse(localStorage.getItem("yt_v2_state") || "{}");
let state = JSON.parse(localStorage.getItem(STORAGE_KEY) || "null") || {
  deviceId: oldState.deviceId,
  nick: oldState.nick,
  table: oldState.table,
  mode: oldState.mode
};

if (!state.deviceId) {
  state.deviceId = crypto.randomUUID
    ? crypto.randomUUID()
    : "d-" + Date.now() + "-" + Math.random().toString(36).slice(2);
}

state.stats = state.stats || { tableRounds: 0, verified: 0, peopleMet: 0, events: 0 };
state.eventRoutes = state.eventRoutes || {};
state.eventPrompts = state.eventPrompts || {};
save();

let heartbeatTimer = null;
let tablePoll = null;
let matchPoll = null;
let clockTimer = null;
let reminderTimer = null;
let latencyUiTimer = null;
let countdownRunning = false;
let lastTableSignature = "";
let tablePollGeneration = 0;


/* =====================================================
   BASIC HELPERS
===================================================== */

function save() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
}

function esc(s) {
  return String(s || "").replace(/[<>&"']/g, c => ({
    "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;", "'": "&#39;"
  }[c]));
}

function pick(a) {
  return a[Math.floor(Math.random() * a.length)];
}

function tap() {
  A.ensure();
  A.tap();
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function toast(text, ms = 2200) {
  const t = document.createElement("div");
  t.className = "toast";
  t.textContent = text;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), ms);
}

function clearViewTimers() {
  tablePollGeneration++;
  clearTimeout(tablePoll);
  clearInterval(clockTimer);
  tablePoll = null;
  clockTimer = null;
}

function shell(body, progress = 0, top = false) {
  app.innerHTML = `
    <div class="shell">
      <div class="top">
        <div class="logo">YETIPSY</div>
        <div class="topActions">
          ${state.table ? `<button class="iconBtn tableTopBtn" id="tableMenuBtn">TABLE ${esc(state.table)}</button>` : ""}
          <button class="iconBtn" id="audioBtn">SOUND</button>
          <span class="latencyBadge" id="latencyBadge" title="Apps Script round-trip latency">-- ms</span>
        </div>
      </div>
      <div class="progress"><i style="width:${progress}%"></i></div>
      <main class="scene ${top ? "topScene" : ""}">${body}</main>
    </div>
  `;

  const audio = document.getElementById("audioBtn");
  if (audio) audio.onclick = audioPanel;

  const tableBtn = document.getElementById("tableMenuBtn");
  if (tableBtn) tableBtn.onclick = tablePanel;

  clearInterval(latencyUiTimer);
  updateLatencyBadge();
  latencyUiTimer = setInterval(updateLatencyBadge, 1000);
}

function updateLatencyBadge() {
  const el = document.getElementById("latencyBadge");
  if (!el) return;

  const ms = B.getLatency ? B.getLatency() : null;

  if (ms == null) {
    el.textContent = "-- ms";
    el.dataset.level = "idle";
    return;
  }

  el.textContent = `${ms} ms`;
  el.dataset.level = ms < 700 ? "good" : ms < 1600 ? "mid" : "slow";
}

function setButtonLoading(button, loading, text = "LOADING…") {
  if (!button) return;
  if (loading) {
    button.dataset.oldText = button.dataset.oldText || button.textContent;
    button.disabled = true;
    button.textContent = text;
  } else {
    button.disabled = false;
    if (button.dataset.oldText) button.textContent = button.dataset.oldText;
  }
}

function formatRemaining(ms) {
  if (ms <= 0) return "READY NOW";
  const total = Math.ceil(ms / 1000);
  const min = Math.floor(total / 60);
  const sec = total % 60;
  return `${String(min).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
}

function tableSignature(r) {
  return [
    r.status, r.round, r.questionIndex, r.leadDevice, r.nextEventAt,
    r.eventIndex, r.questionPool, r.canTakeOver, r.onlineCount,
    r.readyCount, r.readyTotal, r.allReady,
    (r.players || []).join(","),
    (r.readyPlayers || []).join(",")
  ].join("|");
}

function questionFor(r) {
  const pool = r.questionPool === "late" ? C.late : C.warm;
  return pool[(Number(r.questionIndex) || 0) % pool.length];
}

function roundLimit(r) {
  return r.questionPool === "late" ? 2 : 3;
}

function eventName(index) {
  if (Number(index) % 2 === 0) return "AFTER DARK";
  const names = ["SOCIAL CALL", "STRANGER MISSION", "TABLE VS TABLE"];
  return names[Math.floor((Number(index) - 1) / 2) % names.length];
}


/* =====================================================
   AUDIO PANEL
===================================================== */

function audioPanel() {
  const s = A.get();
  const d = document.createElement("div");
  d.className = "soundPanel";
  d.innerHTML = `
    <div class="kicker">AUDIO & HAPTICS</div>
    ${toggleRow("VOICE", "voice", s.voice)}
    ${toggleRow("SFX", "sfx", s.sfx)}
    ${toggleRow("VIBRATION", "vibration", s.vibration)}
    <button class="btn secondary" id="closeAudio">DONE</button>
  `;
  document.body.appendChild(d);

  d.querySelectorAll("[data-toggle]").forEach(x => {
    x.onclick = () => {
      const k = x.dataset.toggle;
      const v = !A.get()[k];
      A.set(k, v);
      x.classList.toggle("on", v);
      if (k === "voice" && v) A.countWord("READY");
    };
  });

  d.querySelector("#closeAudio").onclick = () => d.remove();
}

function toggleRow(label, key, on) {
  return `
    <div class="toggleRow">
      <b>${label}</b>
      <div class="toggle ${on ? "on" : ""}" data-toggle="${key}"><i></i></div>
    </div>
  `;
}


/* =====================================================
   TABLE MENU / MOVE / LEAVE
===================================================== */

function tablePanel() {
  if (!state.table) return;

  const d = document.createElement("div");
  d.className = "soundPanel tablePanel";
  d.innerHTML = `
    <div class="kicker">TABLE CONTROL</div>
    <h3 style="margin:0 0 6px">TABLE ${esc(state.table)}</h3>
    <p class="small" style="margin-top:0">换桌会先退出当前桌，再加入新桌。未完成的 Match 会被取消。</p>

    <label class="small">MOVE TO TABLE</label>
    <input class="field" id="moveTableInput" maxlength="12" placeholder="例如：B2">
    <button class="btn primary" id="moveTableBtn">CHANGE TABLE</button>
    <button class="btn secondary" id="leaveTableBtn">LEAVE THIS TABLE</button>
    <button class="btn tertiary" id="closeTablePanel">CLOSE</button>
  `;
  document.body.appendChild(d);

  d.querySelector("#closeTablePanel").onclick = () => d.remove();

  d.querySelector("#moveTableBtn").onclick = async e => {
    const nextTable = d.querySelector("#moveTableInput").value.trim().toUpperCase();
    if (!nextTable) return toast("先输入新桌号");
    if (nextTable === state.table) return toast("你已经在这桌");

    const btn = e.currentTarget;
    setButtonLoading(btn, true, "MOVING…");
    const oldTable = state.table;
    const left = await B.leaveTable({ deviceId: state.deviceId });

    if (!left.ok) {
      setButtonLoading(btn, false);
      return toast(left.error === "finish_match_first" ? "先完成当前 Match 再换桌" : "暂时无法离桌");
    }

    state.table = nextTable;
    delete state.match;
    save();

    const joined = await joinBackend();
    if (!joined.ok) {
      state.table = oldTable;
      save();
      await joinBackend();
      setButtonLoading(btn, false);
      return toast("新桌加入失败，已经回到原桌");
    }

    d.remove();
    A.impact();
    loadTableState();
  };

  d.querySelector("#leaveTableBtn").onclick = async e => {
    const btn = e.currentTarget;
    setButtonLoading(btn, true, "LEAVING…");
    const left = await B.leaveTable({ deviceId: state.deviceId });

    if (!left.ok) {
      setButtonLoading(btn, false);
      return toast(left.error === "finish_match_first" ? "先完成当前 Match 再离桌" : "离桌失败，请再试一次");
    }

    clearViewTimers();
    clearInterval(matchPoll);
    clearInterval(heartbeatTimer);
    delete state.match;
    state.table = "";
    save();
    d.remove();
    toast("已离开这桌");
    profile();
  };
}


/* =====================================================
   HOME / PROFILE
===================================================== */

function home() {
  clearViewTimers();
  clearInterval(matchPoll);

  const canResume = state.nick && state.table && state.mode;

  shell(`
    <div class="kicker">TONIGHT · ${VERSION}</div>
    <h1 class="display">今晚<br>有局。</h1>
    <p class="lead">
      不是 30 分钟通关。<br>
      <b style="color:var(--ink)">今晚会隔一阵子，再发生一点东西。</b>
    </p>

    <div class="card">
      <span class="pill">ONE PERSON · ONE PHONE</span>
      <p class="lead" style="margin:14px 0 0">
        同桌先一起开局。每一题看完后抢 READY，第一台 READY 的手机负责倒数。
      </p>
    </div>

    ${canResume ? `
      <button class="btn primary" id="resume">CONTINUE TONIGHT · TABLE ${esc(state.table)}</button>
      <button class="btn secondary" id="fresh">START A NEW PASS</button>
    ` : `
      <button class="btn primary" id="enter">ENTER TONIGHT</button>
    `}

    <div class="footer">
      仅限达到当地合法饮酒年龄的成年人参与 · 可随时跳过互动 · 理性饮酒
    </div>
  `, 3);

  if (canResume) {
    document.getElementById("resume").onclick = () => { tap(); resumeTonight(); };
    document.getElementById("fresh").onclick = () => {
      state.nick = "";
      state.table = "";
      state.mode = "";
      delete state.match;
      save();
      soundGate();
    };
  } else {
    document.getElementById("enter").onclick = () => { tap(); soundGate(); };
  }
}

function soundGate() {
  shell(`
    <div class="kicker">BEFORE WE START</div>
    <h2 class="title">只有抢到 READY 的那台手机，<br>会负责倒数。</h2>
    <p class="lead">READY · THREE · TWO · ONE · POINT。</p>
    <button class="btn primary" id="soundOn">ENTER WITH SOUND</button>
    <button class="btn secondary" id="quiet">KEEP IT QUIET</button>
  `, 7);

  document.getElementById("soundOn").onclick = () => {
    A.allOn(); A.ensure(); tap(); profile();
  };
  document.getElementById("quiet").onclick = () => {
    A.quiet(); profile();
  };
}

function profile() {
  shell(`
    <div class="kicker">01 · YOUR PASS</div>
    <h2 class="title">先拿你的今晚身份。</h2>
    <p class="lead">不用手机号，不用注册。</p>
    <div class="card">
      <label class="small">YOUR NAME / NICKNAME</label>
      <input class="field" id="nick" maxlength="18" placeholder="例如：Xiang" value="${esc(state.nick || "")}">
      <div style="height:12px"></div>
      <label class="small">你现在坐哪一桌？</label>
      <input class="field" id="table" maxlength="12" placeholder="例如：A3" value="${esc(state.table || "")}">
    </div>
    <button class="btn primary" id="next">CREATE MY PASS</button>
  `, 12);

  document.getElementById("next").onclick = () => {
    const nick = document.getElementById("nick").value.trim();
    const table = document.getElementById("table").value.trim().toUpperCase();
    if (!nick || !table) return toast("先填昵称和桌号");
    state.nick = nick;
    state.table = table;
    save(); tap(); mode();
  };
}

function mode() {
  shell(`
    <div class="kicker">02 · YOUR ROUTE</div>
    <h2 class="title">今晚想怎么玩？</h2>
    <div class="choices">
      <button class="choice" data-m="chill"><strong>CHILL</strong><span>主要跟自己朋友玩；跨桌事件可以留在本桌。</span></button>
      <button class="choice" data-m="open"><strong>OPEN</strong><span>愿意在事件时间认识其他桌的一个人。</span></button>
      <button class="choice" data-m="surprise"><strong>SURPRISE ME</strong><span>每次事件让系统决定你留桌还是出去。</span></button>
    </div>
  `, 18);

  document.querySelectorAll("[data-m]").forEach(button => {
    button.onclick = async () => {
      document.querySelectorAll("[data-m]").forEach(x => x.disabled = true);
      state.mode = button.dataset.m;
      save(); tap();
      button.querySelector("span").textContent = "CONNECTING…";

      const r = await joinBackend();
      if (!r.ok) {
        document.querySelectorAll("[data-m]").forEach(x => x.disabled = false);
        button.querySelector("span").textContent = "连接失败，请再试一次";
        return toast(r.error === "timeout" ? "后台响应较慢，请再按一次" : "无法连接 YETIPSY 后台");
      }

      startHeartbeat();
      loadTableState();
    };
  });
}

async function joinBackend() {
  return B.join({
    deviceId: state.deviceId,
    nick: state.nick,
    table: state.table,
    mode: state.mode
  });
}

function startHeartbeat() {
  clearInterval(heartbeatTimer);
  heartbeatTimer = setInterval(() => {
    B.heartbeat({ deviceId: state.deviceId });
  }, 60000);
}

async function resumeTonight() {
  shell(`
    <div class="kicker">RESTORING TONIGHT</div>
    <h2 class="title">正在找回你的今晚…</h2>
    <div class="waiting"></div>
  `, 20);

  const join = await joinBackend();
  if (!join.ok) {
    toast("暂时连不到后台");
    return home();
  }

  startHeartbeat();

  const ms = await B.matchStatus({ deviceId: state.deviceId });
  if (ms.ok && ms.match) {
    state.match = ms.match;
    save();
    if (ms.match.bothVerified) return verificationSuccess(true);
    if (ms.match.verified) return waitForPartnerVerification();
    return showMatch(ms.match);
  }

  loadTableState();
}


/* =====================================================
   TABLE STATE ROUTER
===================================================== */

async function loadTableState() {
  clearViewTimers();

  const r = await B.tableState({ deviceId: state.deviceId, table: state.table });
  if (!r.ok) {
    shell(`
      <div class="kicker">TABLE CONNECTION</div>
      <h2 class="title">暂时连不到桌子。</h2>
      <button class="btn primary" id="retry">RETRY</button>
    `, 20);
    document.getElementById("retry").onclick = loadTableState;
    return;
  }

  renderTableState(r);
}

function renderTableState(r) {
  clearViewTimers();
  lastTableSignature = tableSignature(r);

  switch (r.status) {
    case "lobby": return renderTableLobby(r);
    case "question": return renderQuestion(r);
    case "playing": return r.leadDevice === state.deviceId ? runLeadRound(r) : renderPlaying(r);
    case "discuss": return renderDiscuss(r);
    case "break": return renderBreak(r);
    case "event": return renderEventIntro(r);
    default: return renderTableLobby(r);
  }
}

function pollTable({ interval = 2500, lobbyLive = false } = {}) {
  tablePollGeneration++;
  const generation = tablePollGeneration;
  clearTimeout(tablePoll);

  const schedule = () => {
    if (generation !== tablePollGeneration) return;
    tablePoll = setTimeout(tick, interval);
  };

  const tick = async () => {
    if (generation !== tablePollGeneration) return;

    if (countdownRunning) {
      schedule();
      return;
    }

    const r = await B.tableState({
      deviceId: state.deviceId,
      table: state.table
    });

    if (generation !== tablePollGeneration) return;

    if (!r.ok) {
      schedule();
      return;
    }

    const sig = tableSignature(r);

    /*
      Lobby 不再整页重画。
      只更新人数、昵称和开桌按钮，避免 Apps Script 较慢时
      render -> clearInterval -> render 的循环把轮询弄断。
    */
    if (lobbyLive && r.status === "lobby") {
      updateLobbyView(r);
      lastTableSignature = sig;
      schedule();
      return;
    }

    if (sig !== lastTableSignature) {
      renderTableState(r);
      return;
    }

    const online = document.getElementById("onlineCount");
    if (online) online.textContent = r.onlineCount;

    schedule();
  };

  tablePoll = setTimeout(tick, interval);
}


/* =====================================================
   LOBBY / START TABLE
===================================================== */

function updateLobbyView(r) {
  const online = document.getElementById("onlineCount");
  const peopleList = document.getElementById("lobbyPeople");
  const startBtn = document.getElementById("startTable");

  if (online) online.textContent = Number(r.onlineCount) || 0;

  if (peopleList) {
    const people = (r.players || [])
      .map(name => `<span class="personChip">${esc(name)}</span>`)
      .join("");

    peopleList.innerHTML = people || `<span class="small">正在等其他人…</span>`;
  }

  if (startBtn && !startBtn.dataset.loading) {
    const canStart = Number(r.onlineCount) >= 2;
    startBtn.disabled = !canStart;
    startBtn.textContent = canStart
      ? "大家都进来了 · 开桌"
      : "WAITING FOR ONE MORE…";
  }
}

function renderTableLobby(r) {
  const people = (r.players || []).map(name => `<span class="personChip">${esc(name)}</span>`).join("");

  shell(`
    <div class="kicker">03 · TABLE LOBBY</div>
    <span class="pill">TABLE ${esc(state.table)}</span>
    <h2 class="title">先等大家都进来。</h2>
    <p class="lead">看到桌上的人都出现在这里后，再由任何一个人按开桌。</p>

    <div class="card">
      <div class="roundMeta">
        <span>PEOPLE HERE</span>
        <b id="onlineCount">${r.onlineCount}</b>
      </div>
      <div class="peopleList" id="lobbyPeople">${people || `<span class="small">正在等其他人…</span>`}</div>
    </div>

    <button class="btn primary" id="startTable" ${r.onlineCount < 2 ? "disabled" : ""}>
      ${r.onlineCount < 2 ? "WAITING FOR ONE MORE…" : "大家都进来了 · 开桌"}
    </button>
    <button class="btn secondary" id="refresh">SYNC NOW</button>

    <p class="small" style="text-align:center;margin-top:12px">
      人数会自动更新，不需要手动刷新。开桌后所有手机看到同一题，每题重新抢 READY。
    </p>
  `, 25);

  document.getElementById("refresh").onclick = loadTableState;
  document.getElementById("startTable").onclick = async e => {
    const btn = e.currentTarget;
    btn.dataset.loading = "1";
    setButtonLoading(btn, true, "OPENING TABLE…");

    const x = await B.startTable({
      deviceId: state.deviceId,
      table: state.table
    });

    if (!x.ok) {
      delete btn.dataset.loading;
      setButtonLoading(btn, false);
      return toast(x.error === "need_two_players" ? "至少两个人进入后再开桌" : "开桌失败，请再试一次");
    }

    A.impact();
    renderTableState(x);
  };

  updateLobbyView(r);
  pollTable({ interval: 2000, lobbyLive: true });
}


/* =====================================================
   FIRST READY = LEAD THIS ROUND
===================================================== */

function renderQuestion(r) {
  const q = questionFor(r);
  const isLate = r.questionPool === "late";
  const readyDevices = Array.isArray(r.readyDevices) ? r.readyDevices : [];
  const myReady = readyDevices.includes(state.deviceId);
  const readyCount = Number(r.readyCount) || 0;
  const readyTotal = Math.max(Number(r.readyTotal) || Number(r.onlineCount) || 0, 1);
  const readyNames = (r.readyPlayers || []).map(name => `<span class="personChip">${esc(name)} ✓</span>`).join("");

  shell(`
    <div class="kicker">${isLate ? "AFTER DARK" : "TABLE SYNC"} · ROUND ${r.round}/${roundLimit(r)}</div>
    <div class="roundStrip">
      <span class="pill">TABLE ${esc(state.table)}</span>
      <span class="small">${r.onlineCount} HERE</span>
    </div>

    <h2 class="title">先看问题。</h2>

    <div class="card questionCard">
      <div class="small">${isLate ? "LATE NIGHT QUESTION" : "3 · 2 · 1 · 一起指"}</div>
      <div class="question" style="margin-top:12px">${esc(q)}</div>
    </div>

    <div class="card" style="margin-top:12px">
      <div class="roundMeta">
        <span>READY</span>
        <b>${readyCount}/${readyTotal}</b>
      </div>
      <div class="peopleList">
        ${readyNames || `<span class="small">还没有人按 READY</span>`}
      </div>
      ${r.leadNick ? `<p class="small" style="margin:10px 0 0">本题 Lead：${esc(r.leadNick)} · 等大家都 READY 才会开始倒数。</p>` : ""}
    </div>

    ${myReady ? `
      <button class="btn secondary" disabled>✓ I'M READY</button>
      <p class="lead" style="text-align:center;margin-top:12px">
        你已经准备好了。<br>
        等其他人看完问题并按 READY。
      </p>
    ` : `
      <button class="btn primary readyBtn" id="ready">I'M READY</button>
      ${readyCount === 0 ? `<button class="btn secondary" id="reroll">这题不适合 · 换一题</button>` : ""}
      <div class="small" style="text-align:center">第一个 READY = 本题 Lead，但不会马上开始。有人 READY 后就锁题。</div>
    `}
  `, 32);

  const readyBtn = document.getElementById("ready");
  if (readyBtn) {
    readyBtn.onclick = async e => {
      if (countdownRunning) return;
      const btn = e.currentTarget;
      setButtonLoading(btn, true, "MARKING READY…");
      tap();

      const x = await B.claimLead({
        deviceId: state.deviceId,
        nick: state.nick,
        table: state.table,
        currentRound: r.round
      });

      if (!x.ok) {
        setButtonLoading(btn, false);
        return toast("READY 失败，请再试一次");
      }

      if (x.status === "playing") {
        return x.isLead ? runLeadRound(x) : renderPlaying(x);
      }

      renderQuestion(x);
    };
  }

  const rerollBtn = document.getElementById("reroll");
  if (rerollBtn) {
    rerollBtn.onclick = async e => {
      const btn = e.currentTarget;
      setButtonLoading(btn, true, "CHANGING…");
      const x = await B.rerollQuestion({
        deviceId: state.deviceId,
        table: state.table,
        currentRound: r.round
      });

      if (!x.ok) {
        setButtonLoading(btn, false);
        return toast(x.error === "already_ready" ? "已经有人 READY，这题已锁定" : "换题失败，请再试一次");
      }

      A.tap();
      renderQuestion(x);
    };
  }

  pollTable({ interval: 1500 });
}

async function runLeadRound(r) {
  if (countdownRunning) return;

  clearViewTimers();
  countdownRunning = true;
  const q = questionFor(r);

  shell(`
    <div class="kicker">ALL READY · YOU'RE LEADING</div>
    <h2 class="title">全员准备好了。<br>由你来倒数。</h2>
    <div class="card">
      <div class="question">${esc(q)}</div>
      <p class="small">只有你这台手机会播放 READY · 3 · 2 · 1 · POINT。把手机放大家都看得到的位置。</p>
    </div>
  `, 36);

  await sleep(500);
  await countdown();

  const x = await B.finishCountdown({ deviceId: state.deviceId, table: state.table });
  countdownRunning = false;

  if (!x.ok) return loadTableState();
  state.stats.tableRounds++;
  save();
  renderTableState(x);
}

function renderPlaying(r) {
  const q = questionFor(r);
  shell(`
    <div class="kicker">ROUND ${r.round} · ALL READY</div>
    <div class="leadBanner">${esc(r.leadNick || "另一台手机")} 正在带倒数</div>
    <h2 class="title">抬头。<br>跟着 Lead Phone。</h2>
    <div class="card">
      <div class="question">${esc(q)}</div>
    </div>
    <div class="waiting"></div>
    <p class="lead" style="text-align:center">全桌已经 READY。<br>不要跟自己的手机倒数，听 Lead Phone 的 READY · 3 · 2 · 1 · POINT。</p>
  `, 36);

  pollTable({ interval: 1000 });
}

async function countdown() {
  A.ensure();
  const steps = [
    { screen: "READY", voice: "READY", gap: 300, cls: "word" },
    { screen: "3", voice: "THREE", gap: 260, cls: "" },
    { screen: "2", voice: "TWO", gap: 260, cls: "" },
    { screen: "1", voice: "ONE", gap: 300, cls: "" },
    { screen: "POINT!", voice: "POINT", gap: 380, cls: "point" }
  ];

  const overlay = document.createElement("div");
  overlay.className = "countdown";
  document.body.appendChild(overlay);

  for (const x of steps) {
    overlay.innerHTML = `
      <div>
        <div class="readyText">${x.screen === "READY" ? "EVERYONE" : ""}</div>
        <div class="countNum ${x.cls}">${x.screen}</div>
      </div>
    `;

    if (x.voice === "POINT") A.impact();

    /*
      关键修正：等待这一句真的念完，才进入下一步。
      V2.4.2 用固定 850ms，下一句 speechSynthesis.cancel() 会把上一句切掉。
    */
    try {
      await A.countWord(x.voice);
    } catch (_) {}

    await sleep(x.gap);
  }

  overlay.remove();
}


/* =====================================================
   DISCUSS / NEXT ROUND
===================================================== */

function renderDiscuss(r) {
  const q = questionFor(r);
  const isLead = r.leadDevice === state.deviceId;
  const canAdvance = isLead || r.canTakeOver;
  const lastRound = Number(r.round) >= roundLimit(r);

  shell(`
    <div class="kicker">ROUND ${r.round} · TALK FIRST</div>
    <h2 class="title">手机先放一下。</h2>
    <div class="card">
      <div class="question">${esc(q)}</div>
      <p class="small">笑、解释、互呛都可以。不要急着按下一题。</p>
    </div>

    ${canAdvance ? `
      <button class="btn primary" id="nextRound">${lastRound ? "这组玩够了 · BACK TO TONIGHT" : "聊够了 · NEXT QUESTION"}</button>
    ` : `
      <div class="card" style="margin-top:12px;text-align:center">
        <div class="small">ROUND LEAD</div>
        <b>${esc(r.leadNick || "PLAYER")}</b>
        <p class="small" style="margin-bottom:0">等 Lead 开下一题。超过约 1 分钟没人动，其他手机可以接管。</p>
      </div>
    `}
  `, 40);

  if (canAdvance) {
    document.getElementById("nextRound").onclick = async e => {
      const btn = e.currentTarget;
      setButtonLoading(btn, true, "SYNCING…");
      const x = await B.nextTableRound({
        deviceId: state.deviceId,
        table: state.table,
        currentRound: r.round
      });
      if (!x.ok) {
        setButtonLoading(btn, false);
        return toast(x.error === "not_round_lead" ? `等 ${x.leadNick || "Lead"} 开下一题` : "同步失败，请再试一次");
      }
      renderTableState(x);
    };
  }

  pollTable({ interval: 2500 });
}


/* =====================================================
   TONIGHT LOBBY / TIMED RETURN
===================================================== */

function renderBreak(r) {
  clearViewTimers();
  const nextAt = r.nextEventAt ? new Date(r.nextEventAt).getTime() : Date.now();
  const due = !nextAt || Date.now() >= nextAt;
  const index = Math.max(1, Number(r.eventIndex) || 1);
  const name = eventName(index);

  shell(`
    <div class="kicker">TONIGHT LOBBY · EVENT ${index}</div>
    <h2 class="title">先喝一杯。<br>下一局晚点回来。</h2>

    <div class="card eventCard">
      <div class="small">NEXT UP</div>
      <div class="eventName">${esc(name)}</div>
      <div class="timer" id="eventTimer">${formatRemaining(nextAt - Date.now())}</div>
      <p class="small" id="timerCopy">${due ? "已经解锁。" : "时间到会在网页还开着时提醒你。"}</p>
    </div>

    <button class="btn primary" id="openEvent">${due ? "OPEN NEXT EVENT" : "PLAY NOW · 不想等"}</button>
    <button class="btn secondary" id="remind">REMIND ME</button>
    <button class="btn secondary" id="bartender">BARTENDER PICK</button>

    <div class="card" style="margin-top:12px">
      <div class="roundMeta"><span>TABLE ${esc(state.table)}</span><b id="onlineCount">${r.onlineCount}</b></div>
      <p class="small" style="margin-bottom:0">人还在喝酒、拿食物、聊天都没关系。重新打开网页会回到今晚当前进度。</p>
    </div>
  `, 55);

  const timerEl = document.getElementById("eventTimer");
  const copyEl = document.getElementById("timerCopy");
  const openBtn = document.getElementById("openEvent");

  function tick() {
    const remain = nextAt - Date.now();
    timerEl.textContent = formatRemaining(remain);
    if (remain <= 0) {
      openBtn.textContent = "OPEN NEXT EVENT";
      copyEl.textContent = "下一局已经解锁。";
      fireReturnReminder(nextAt, name);
    }
  }

  tick();
  clockTimer = setInterval(tick, 1000);

  openBtn.onclick = async e => {
    const btn = e.currentTarget;
    setButtonLoading(btn, true, "OPENING…");
    const force = Date.now() < nextAt;
    const x = await B.startEvent({ deviceId: state.deviceId, table: state.table, force: force });
    if (!x.ok) {
      setButtonLoading(btn, false);
      return toast("暂时开不了下一局");
    }
    A.impact();
    renderTableState(x);
  };

  document.getElementById("remind").onclick = () => enableReminder(nextAt, name);
  document.getElementById("bartender").onclick = () => bartenderDiscovery(r);

  scheduleLocalReminder(nextAt, name);
  pollTable({ interval: 5000 });
}

function scheduleLocalReminder(at, name) {
  clearTimeout(reminderTimer);
  const delay = Math.max(0, at - Date.now());
  reminderTimer = setTimeout(() => fireReturnReminder(at, name), delay);
}

async function enableReminder(at, name) {
  state.reminderAt = at;
  save();

  if (!("Notification" in window)) {
    toast("会用网页声音和震动提醒；这个浏览器不支持系统通知");
    return;
  }

  if (Notification.permission === "granted") {
    toast("提醒已开启");
    return;
  }

  if (Notification.permission === "denied") {
    toast("浏览器已关闭通知；网页开着时仍会提醒");
    return;
  }

  try {
    const result = await Notification.requestPermission();
    toast(result === "granted" ? "提醒已开启" : "网页开着时仍会提醒你");
  } catch {
    toast("网页开着时会用声音和震动提醒");
  }
}

function fireReturnReminder(at, name) {
  if (state.lastReminderAt === at) return;
  state.lastReminderAt = at;
  save();
  A.impact();
  toast("YETIPSY CALLING · 下一局来了", 4000);

  if ("Notification" in window && Notification.permission === "granted") {
    try {
      new Notification("YETIPSY · 下一局来了", {
        body: `${name} 已解锁。回来看看。`
      });
    } catch (_) {}
  }
}


document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && state.reminderAt && Date.now() >= state.reminderAt) {
    fireReturnReminder(state.reminderAt, "NEXT EVENT");
  }
});


/* =====================================================
   EVENT ROUTES
===================================================== */

function renderEventIntro(r) {
  const index = Math.max(1, Number(r.eventIndex) || 1);
  const name = eventName(index);
  state.activeEventIndex = index;
  save();

  let route = state.eventRoutes[index];
  if (!route) {
    if (state.mode === "open") route = "open";
    else if (state.mode === "chill") route = "chill";
    else route = Math.random() < 0.65 ? "open" : "chill";
    state.eventRoutes[index] = route;
    save();
  }

  shell(`
    <div class="kicker">TONIGHT EVENT ${index}</div>
    <div class="eventName bigEvent">${esc(name)}</div>
    <h2 class="title">今晚又发生一点东西。</h2>

    <div class="card">
      <span class="pill">${route === "open" ? "OTHER TABLE" : "YOUR TABLE"}</span>
      <p class="lead" style="margin:14px 0 0">
        ${route === "open"
          ? "这轮会把你送去认识另一桌的一位玩家。你们会拿到同一个 Mission。"
          : "这轮留在自己桌，不需要硬社交。"}
      </p>
    </div>

    <button class="btn primary" id="enterEvent">ENTER EVENT</button>
    ${route === "open" ? `<button class="btn secondary" id="stay">今晚这轮想留桌</button>` : ""}
  `, 62);

  document.getElementById("enterEvent").onclick = () => {
    tap();
    route === "open" ? queueForMatch(false) : chillEvent(r);
  };

  const stay = document.getElementById("stay");
  if (stay) stay.onclick = () => chillEvent(r);
}

function chillEvent(r) {
  const index = Math.max(1, Number(r.eventIndex) || state.activeEventIndex || 1);
  if (state.eventPrompts[index] == null) {
    state.eventPrompts[index] = Math.floor(Math.random() * C.chill.length);
    save();
  }
  const q = C.chill[state.eventPrompts[index] % C.chill.length];

  shell(`
    <div class="kicker">STAY AT YOUR TABLE</div>
    <h2 class="title">这轮不用出去。</h2>
    <div class="card">
      <span class="pill">TABLE MISSION</span>
      <div class="question" style="margin-top:14px">${esc(q)}</div>
    </div>
    <button class="btn primary" id="done">DONE · BACK TO TONIGHT</button>
  `, 68);

  document.getElementById("done").onclick = async e => {
    const btn = e.currentTarget;
    setButtonLoading(btn, true, "SAVING…");
    state.stats.events++;
    save();
    const x = await B.completeEvent({ deviceId: state.deviceId, table: state.table });
    if (!x.ok) return loadTableState();
    renderTableState(x);
  };
}


/* =====================================================
   CROSS-TABLE MATCH + SHARED MISSION
===================================================== */

async function queueForMatch(bonus = false) {
  clearInterval(matchPoll);
  shell(`
    <div class="kicker">${bonus ? "BONUS MATCH" : "CROSS-TABLE MATCH"}</div>
    <h2 class="title">正在找另一桌的人。</h2>
    <div class="waiting"></div>
    <p class="lead" style="text-align:center">只会匹配不同桌、最近在线、而且你今晚还没 Match 过的人。</p>
    <div class="small" id="matchStatus" style="text-align:center">CONNECTING…</div>
    <button class="btn secondary" id="cancel">CANCEL</button>
  `, 70);

  document.getElementById("cancel").onclick = async () => {
    clearInterval(matchPoll);
    await B.cancelMatch({ deviceId: state.deviceId });
    delete state.match;
    save();
    const r = await B.tableState({ deviceId: state.deviceId, table: state.table });
    if (r.ok && r.status === "event") chillEvent(r);
    else if (r.ok) renderTableState(r);
    else loadTableState();
  };

  const statusEl = document.getElementById("matchStatus");
  const r = await B.queue({
    deviceId: state.deviceId,
    nick: state.nick,
    table: state.table,
    mode: state.mode,
    eventIndex: state.activeEventIndex || 0
  });

  if (!r.ok) {
    statusEl.textContent = "连接失败";
    toast(r.error === "timeout" ? "后台比较慢，请再试一次" : "Match 后台连接失败");
    return;
  }

  if (r.match) return showMatch(r.match);
  statusEl.textContent = "WAITING FOR ANOTHER TABLE…";
  matchPoll = setInterval(checkMatch, 3000);
}

async function checkMatch() {
  const s = await B.matchStatus({ deviceId: state.deviceId });
  if (!s.ok) return;
  if (s.match) {
    clearInterval(matchPoll);
    showMatch(s.match);
  }
}

function showMatch(m) {
  clearInterval(matchPoll);
  state.match = m;
  save();
  A.impact();

  const mission = C.missions[(Number(m.missionIndex) || 0) % C.missions.length];

  shell(`
    <div class="kicker">MATCH FOUND</div>
    <h2 class="title">找到你的 Match。</h2>

    <div class="card matchCard">
      <span class="pill">YOUR MATCH</span>
      <div class="matchName">${esc(m.partnerNick)}</div>
      <div class="tableBadge">TABLE ${esc(m.partnerTable)}</div>
    </div>

    <div class="card" style="margin-top:12px">
      <div class="small">SHARED MISSION</div>
      <div class="missionTitle">${esc(mission.title)}</div>
      <p class="lead" style="margin:8px 0 0">${esc(mission.text)}</p>
    </div>

    <button class="btn primary" id="meet">I FOUND THEM</button>
    <button class="btn secondary" id="cant">找不到 · CANCEL MATCH</button>
  `, 74);

  document.getElementById("meet").onclick = () => { tap(); missionScreen(m); };
  document.getElementById("cant").onclick = async e => {
    const btn = e.currentTarget;
    setButtonLoading(btn, true, "CANCELING…");
    const x = await B.cancelMatch({ deviceId: state.deviceId });
    if (!x.ok && x.error === "already_verified") return verificationIntro();
    delete state.match;
    save();
    const tr = await B.tableState({ deviceId: state.deviceId, table: state.table });
    if (tr.ok && tr.status === "event") chillEvent(tr);
    else if (tr.ok) renderTableState(tr);
    else loadTableState();
  };
}

function missionScreen(m) {
  const mission = C.missions[(Number(m.missionIndex) || 0) % C.missions.length];
  shell(`
    <div class="kicker">MISSION · ${esc(mission.title)}</div>
    <h2 class="title">先完成任务。<br>再互换验证码。</h2>

    <div class="card">
      <div class="question">${esc(mission.text)}</div>
    </div>

    <div class="card" style="margin-top:12px;text-align:center">
      <div class="small">YOUR CODE · 等下给 ${esc(m.partnerNick)} 看</div>
      <div class="code miniCode">${esc(m.myCode || "----")}</div>
    </div>

    <button class="btn primary" id="missionDone">MISSION DONE · VERIFY</button>
    <button class="btn secondary" id="back">BACK</button>
  `, 78);

  document.getElementById("missionDone").onclick = verificationIntro;
  document.getElementById("back").onclick = () => showMatch(m);
}


/* =====================================================
   TWO-WAY VERIFICATION
===================================================== */

function verificationIntro() {
  const m = state.match;
  shell(`
    <div class="kicker">VERIFY THE CONNECTION</div>
    <h2 class="title">真的找到对方才算。</h2>
    <p class="lead">把你的码给对方，同时输入对方手机上的 4 位码。</p>

    <div class="card">
      <div class="small">SHOW THIS TO ${esc(m.partnerNick)}</div>
      <div class="code">${esc(m.myCode || "----")}</div>
    </div>

    <button class="btn primary" id="input">ENTER THEIR CODE</button>
    <button class="btn secondary" id="backMission">BACK TO MISSION</button>
  `, 82);

  document.getElementById("input").onclick = verifyCode;
  document.getElementById("backMission").onclick = () => missionScreen(m);
}

function verifyCode() {
  shell(`
    <div class="kicker">CONNECTION CHECK</div>
    <h2 class="title">输入对方的 4 位码。</h2>
    <div class="card">
      <input class="field" id="codeInput" inputmode="numeric" maxlength="4" placeholder="0000"
        style="text-align:center;font-size:34px;letter-spacing:.22em;font-weight:900">
    </div>
    <button class="btn primary" id="verify">VERIFY</button>
    <button class="btn secondary" id="showMine">返回看我的码</button>
  `, 84);

  document.getElementById("showMine").onclick = verificationIntro;
  document.getElementById("verify").onclick = async e => {
    const btn = e.currentTarget;
    const code = document.getElementById("codeInput").value.trim();
    if (!/^\d{4}$/.test(code)) return toast("需要 4 位数字");

    setButtonLoading(btn, true, "VERIFYING…");
    const m = state.match;
    const r = await B.verify({ deviceId: state.deviceId, matchId: m.matchId, partnerCode: code });

    if (!r.ok) {
      setButtonLoading(btn, false);
      return toast(r.error === "wrong_code" ? "码不对，看看对方手机" : "验证失败，请再试一次");
    }

    if (!r.bothVerified) return waitForPartnerVerification();
    verificationSuccess();
  };
}

function waitForPartnerVerification() {
  const m = state.match;
  shell(`
    <div class="kicker">YOU'RE VERIFIED</div>
    <h2 class="title">你这边完成了。<br>等对方确认你。</h2>

    <div class="card">
      <div class="small">YOUR CODE · 给 ${esc(m.partnerNick)} 看</div>
      <div class="code miniCode">${esc(m.myCode || "----")}</div>
      <div class="small">对方还需要在他的手机输入这个号码。</div>
    </div>

    <div class="waiting"></div>
    <p class="lead" style="text-align:center">✓ 你已确认 ${esc(m.partnerNick)}<br>WAITING FOR THEM…</p>
  `, 86);

  clearInterval(matchPoll);
  matchPoll = setInterval(async () => {
    const s = await B.matchStatus({ deviceId: state.deviceId });
    if (!s.ok || !s.match) return;
    state.match = s.match;
    save();
    if (s.match.bothVerified) {
      clearInterval(matchPoll);
      verificationSuccess();
    }
  }, 2500);
}

function verificationSuccess(restored = false) {
  clearInterval(matchPoll);
  const m = state.match;
  const deep = state.matchDeep || pick(C.deep);
  state.matchDeep = deep;
  if (!restored) {
    state.stats.verified++;
    state.stats.peopleMet++;
  }
  save();
  if (!restored) A.impact();

  shell(`
    <div class="successMark">✓</div>
    <div class="kicker">CONNECTION VERIFIED</div>
    <h2 class="title">你们真的找到彼此了。</h2>

    <div class="card">
      <span class="pill">ONE MORE QUESTION</span>
      <div class="question" style="margin-top:14px">${esc(deep)}</div>
      <p class="small">两个人都回答。聊起来就把手机收起来。</p>
    </div>

    <button class="btn primary" id="backTonight">DONE · BACK TO TONIGHT</button>
    <button class="btn secondary" id="oneMore">ONE MORE MATCH</button>
  `, 90);

  document.getElementById("backTonight").onclick = () => finishMatchedEvent(false);
  document.getElementById("oneMore").onclick = () => finishMatchedEvent(true);
}

async function finishMatchedEvent(oneMore) {
  const m = state.match;
  if (m && m.matchId) {
    await B.completeMatch({ deviceId: state.deviceId, matchId: m.matchId });
  }

  delete state.match;
  delete state.matchDeep;
  save();

  if (oneMore) return queueForMatch(true);

  state.stats.events++;
  save();
  const x = await B.completeEvent({ deviceId: state.deviceId, table: state.table });
  if (x.ok) renderTableState(x);
  else loadTableState();
}


/* =====================================================
   OPTIONAL BARTENDER DISCOVERY
===================================================== */

function bartenderDiscovery(returnState) {
  shell(`
    <div class="kicker">BARTENDER DISCOVERY</div>
    <h2 class="title">今晚想喝什么方向？</h2>
    <p class="lead">只是给 Bartender 一个方向，不是购买要求；也可以问无酒精版本。</p>

    <div class="grid2">
      <button class="choice taste" data-t="甜一点，但不要腻。"><strong>甜</strong><span>果香 / 顺口</span></button>
      <button class="choice taste" data-t="酸感明显一点。"><strong>酸</strong><span>明亮 / Sharp</span></button>
      <button class="choice taste" data-t="清爽、柑橘或气泡方向。"><strong>清爽</strong><span>Light / Fresh</span></button>
      <button class="choice taste" data-t="你先问我三个问题，再帮我选。"><strong>救我</strong><span>Bartender Choice</span></button>
    </div>

    <div id="rec"></div>
    <button class="btn secondary" id="backTonight">BACK TO TONIGHT</button>
  `, 58);

  document.querySelectorAll("[data-t]").forEach(button => {
    button.onclick = () => {
      tap();
      document.getElementById("rec").innerHTML = `
        <div class="card" style="margin-top:12px">
          <span class="pill">SHOW BARTENDER</span>
          <div class="question" style="margin-top:12px">“${esc(button.dataset.t)}”</div>
        </div>
      `;
    };
  });

  document.getElementById("backTonight").onclick = loadTableState;
}


/* =====================================================
   BOOT
===================================================== */

home();
