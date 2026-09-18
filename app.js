const app=document.getElementById("app"),C=YT_CONTENT,A=YTAudio,B=YTBackend;
const VERSION="2.0";
let state=JSON.parse(localStorage.getItem("yt_v2_state")||"{}");
if(!state.deviceId)state.deviceId=crypto.randomUUID?crypto.randomUUID():"d-"+Date.now()+"-"+Math.random().toString(36).slice(2);
state.stats=state.stats||{warm:0,accepted:0,completed:0,verified:0,skips:0,peopleMet:0};
save();
let heartbeatTimer=null,matchPoll=null;

function save(){localStorage.setItem("yt_v2_state",JSON.stringify(state))}
function esc(s){return String(s||"").replace(/[<>&"']/g,c=>({"<":"&lt;",">":"&gt;","&":"&amp;",'"':"&quot;","'":"&#39;"}[c]))}
function pick(a){return a[Math.floor(Math.random()*a.length)]}
function shell(body,p=0,top=false){
 app.innerHTML=`<div class="shell"><div class="top"><div class="logo">YETIPSY</div><button class="iconBtn" id="audioBtn">SOUND</button></div><div class="progress"><i style="width:${p}%"></i></div><main class="scene ${top?"topScene":""}">${body}</main></div>`;
 document.getElementById("audioBtn").onclick=audioPanel;
}
function tap(){A.ensure();A.tap()}
function toast(s){let t=document.createElement("div");t.className="toast";t.textContent=s;document.body.appendChild(t);setTimeout(()=>t.remove(),1800)}
function audioPanel(){
 const s=A.get(),d=document.createElement("div");d.className="soundPanel";d.innerHTML=`<div class="kicker">AUDIO & HAPTICS</div>
 ${toggleRow("VOICE","voice",s.voice)}${toggleRow("SFX","sfx",s.sfx)}${toggleRow("VIBRATION","vibration",s.vibration)}
 <button class="btn secondary" id="closeAudio">DONE</button>`;
 document.body.appendChild(d);
 d.querySelectorAll("[data-toggle]").forEach(x=>x.onclick=()=>{let k=x.dataset.toggle,v=!A.get()[k];A.set(k,v);x.classList.toggle("on",v);if(k==="voice"&&v)A.countWord("READY")});
 d.querySelector("#closeAudio").onclick=()=>d.remove();
}
function toggleRow(label,key,on){return `<div class="toggleRow"><b>${label}</b><div class="toggle ${on?"on":""}" data-toggle="${key}"><i></i></div></div>`}

function home(){
 shell(`<div class="kicker">TONIGHT · ${VERSION}</div><h1 class="display">今晚<br>有局。</h1><p class="lead">这次不是一台手机带全桌。<br><b style="color:var(--ink)">每个人，都有自己的今晚。</b></p>
 <div class="card"><span class="pill">ONE PERSON · ONE PHONE</span><p class="lead" style="margin:14px 0 0">系统会给每个人独立身份、独立任务和独立 Match。朋友可以坐同一桌，但不会拿到完全一样的路线。</p></div>
 <button class="btn primary" id="enter">ENTER TONIGHT</button>
 <div class="footer">仅限达到当地合法饮酒年龄的成年人参与 · 可随时跳过互动 · 理性饮酒</div>`,3);
 document.getElementById("enter").onclick=()=>{tap();soundGate()};
}

function soundGate(){
 shell(`<div class="kicker">BEFORE WE START</div><h2 class="title">今晚有些东西，<br>要听才好玩。</h2><p class="lead">倒数会真正念出 READY · THREE · TWO · ONE。你随时可以在右上角分别关闭 Voice、SFX 或震动。</p>
 <button class="btn primary" id="soundOn">ENTER WITH SOUND</button><button class="btn secondary" id="quiet">KEEP IT QUIET</button>`,7);
 document.getElementById("soundOn").onclick=()=>{A.allOn();A.ensure();tap();profile()};
 document.getElementById("quiet").onclick=()=>{A.quiet();profile()};
}

function profile(){
 shell(`<div class="kicker">01 · YOUR PASS</div><h2 class="title">先拿你的今晚身份。</h2><p class="lead">不用手机号，不用注册。昵称只用于今晚的 Match。</p>
 <div class="card"><label class="small">YOUR NAME / NICKNAME</label><input class="field" id="nick" maxlength="18" placeholder="例如：Xiang" value="${esc(state.nick||"")}">
 <div style="height:12px"></div><label class="small">你现在坐哪一桌？</label><input class="field" id="table" maxlength="12" placeholder="例如：A3 / 12 / OUTDOOR" value="${esc(state.table||"")}"></div>
 <button class="btn primary" id="next">CREATE MY PASS</button>`,12);
 document.getElementById("next").onclick=async()=>{
   let nick=document.getElementById("nick").value.trim(),table=document.getElementById("table").value.trim().toUpperCase();
   if(!nick||!table)return toast("先填昵称和桌号");
   state.nick=nick;state.table=table;save();tap();mode();
 };
}

function mode(){
 shell(`<div class="kicker">02 · YOUR ROUTE</div><h2 class="title">今晚想怎么玩？</h2><p class="lead">这是第一处分支。之后系统会根据你的选择继续改变路线。</p>
 <div class="choices">
 <button class="choice" data-m="chill"><strong>CHILL</strong><span>主要跟自己朋友玩；不会强迫你找陌生人。</span></button>
 <button class="choice" data-m="open"><strong>OPEN</strong><span>愿意被系统 Match 到其他桌的一个人。</span></button>
 <button class="choice" data-m="surprise"><strong>SURPRISE ME</strong><span>系统替你决定，可能突然把你送去 Match。</span></button>
 </div>`,18);
 document.querySelectorAll("[data-m]").forEach(b=>b.onclick=async()=>{
  state.mode=b.dataset.m;save();tap();
  await B.join({deviceId:state.deviceId,nick:state.nick,table:state.table,mode:state.mode});
  startHeartbeat();personalWarm();
 });
}

function startHeartbeat(){
 clearInterval(heartbeatTimer);
 heartbeatTimer=setInterval(()=>B.heartbeat({deviceId:state.deviceId}),45000);
}

let tablePoll=null;
async function personalWarm(){
 // Real backend: one shared round/question per table. Offline: local fallback.
 if(B.configured()){
   const r=await B.tableState({deviceId:state.deviceId,table:state.table});
   if(r.ok){
     state.tableRound=r.round||1; state.currentWarm=C.warm[(r.questionIndex||0)%C.warm.length]; save();
     return renderTableWarm(r);
   }
 }
 state.currentWarm=state.currentWarm||pick(C.warm);save();
 renderTableWarm({round:state.stats.warm+1,questionIndex:C.warm.indexOf(state.currentWarm),countdownAt:null,offline:true});
}
function renderTableWarm(r){
 clearInterval(tablePoll);
 shell(`<div class="kicker">03 · TABLE SYNC · ROUND ${r.round||1}</div><span class="pill">TABLE ${esc(state.table)}</span>
 <div class="card" style="margin-top:14px"><div class="question">${esc(state.currentWarm)}</div>
 <p class="small">${r.offline?"未连接后台：目前只能本机同步预览。":"同一桌所有手机会看到同一题；任何一个人开始后，全桌一起倒数。"}</p></div>
 <button class="btn primary" id="count">${r.countdownAt?"SYNCING…":"START FOR THE TABLE"}</button>
 <button class="btn secondary" id="refresh">SYNC NOW</button>`,28);
 document.getElementById("refresh").onclick=()=>personalWarm();
 document.getElementById("count").onclick=async()=>{
   tap();
   if(!B.configured()) return countdown(()=>finishTableRound(true));
   let x=await B.startCountdown({deviceId:state.deviceId,table:state.table});
   if(x.ok) watchTableCountdown(x.countdownAt);
   else toast("无法开始，请检查后台");
 };
 if(r.countdownAt)watchTableCountdown(r.countdownAt);
 else if(B.configured()){
   tablePoll=setInterval(async()=>{
     let x=await B.tableState({deviceId:state.deviceId,table:state.table});
     if(x.ok&&x.countdownAt){clearInterval(tablePoll);watchTableCountdown(x.countdownAt)}
     else if(x.ok && (x.questionIndex||0)!==r.questionIndex){clearInterval(tablePoll);personalWarm()}
   },900);
 }
}
function watchTableCountdown(iso){
 clearInterval(tablePoll);
 const target=new Date(iso).getTime();
 const wait=Math.max(0,target-Date.now());
 setTimeout(()=>countdown(()=>finishTableRound(false)),wait);
}
async function finishTableRound(offline){
 state.stats.warm++;save();
 if(state.stats.warm<2){
   if(!offline&&B.configured()){
     let r=await B.nextTableRound({deviceId:state.deviceId,table:state.table});
     if(r.ok){state.currentWarm=C.warm[(r.questionIndex||0)%C.warm.length];save();return renderTableWarm(r)}
   }
   state.currentWarm=pick(C.warm);save();return personalWarm();
 }
 branchHub();
}
async function countdown(done){
 A.ensure();
 const steps=[
  {screen:"READY",voice:"READY",ms:900,cls:"word"},
  {screen:"3",voice:"THREE",ms:850,cls:""},
  {screen:"2",voice:"TWO",ms:850,cls:""},
  {screen:"1",voice:"ONE",ms:850,cls:""},
  {screen:"POINT!",voice:"POINT",ms:800,cls:"point"}
 ];
 let overlay=document.createElement("div");overlay.className="countdown";document.body.appendChild(overlay);
 for(const x of steps){
   overlay.innerHTML=`<div><div class="readyText">${x.screen==="READY"?"EVERYONE":""}</div><div class="countNum ${x.cls}">${x.screen}</div></div>`;
   if(x.voice==="POINT")A.impact();
   await Promise.all([A.countWord(x.voice),new Promise(r=>setTimeout(r,x.ms))]);
 }
 overlay.remove();done();
}
function branchHub(){
 if(state.mode==="chill")return chillRoute();
 if(state.mode==="open")return openRoute();
 // Surprise genuinely branches.
 return Math.random()<.58?openRoute(true):chillRoute(true);
}

function chillRoute(surprise=false){
 let q=pick(C.chill);
 shell(`<div class="kicker">${surprise?"SURPRISE ROUTE":"CHILL ROUTE"}</div><h2 class="title">${surprise?"今晚先不把你送出去。":"留在自己桌，也可以很好玩。"}</h2>
 <div class="card"><span class="pill">YOUR SOLO PROMPT</span><div class="question" style="margin-top:14px">${esc(q)}</div><p class="small">每个人自己手机会抽到不同 Prompt。你可以把自己的题带给整桌。</p></div>
 <button class="btn primary" id="done">DONE</button><button class="btn secondary" id="match">我改变主意，想 Match</button>`,43);
 document.getElementById("done").onclick=()=>{state.stats.completed++;save();tap();chillDecision()};
 document.getElementById("match").onclick=()=>{tap();openRoute(true)};
}

function chillDecision(){
 shell(`<div class="kicker">YOUR CHOICE MATTERS</div><h2 class="title">接下来你决定。</h2><div class="choices">
 <button class="choice" id="stay"><strong>STAY CHILL</strong><span>继续朋友桌路线，最后会得到 CHILL 类型结局。</span></button>
 <button class="choice" id="risk"><strong>ONE MATCH</strong><span>只认识一个人。系统不会一直把你送出去。</span></button></div>`,52);
 document.getElementById("stay").onclick=()=>{state.routeFinal="chill";save();tap();deepSolo()};
 document.getElementById("risk").onclick=()=>{state.routeFinal="hybrid";save();tap();openRoute(true)};
}

function openRoute(fromBranch=false){
 shell(`<div class="kicker">${fromBranch?"ONE MATCH":"OPEN ROUTE"}</div><h2 class="title">一人一手机。<br>一人一个 Match。</h2><p class="lead">系统不会把“整桌 A”直接配给“整桌 B”。它会从其他桌挑一个独立玩家给你，而且尽量避免同桌重复配到同一个人。</p>
 <div class="card"><div class="identity"><div class="avatar">${esc(state.nick.slice(0,1).toUpperCase())}</div><div><b>${esc(state.nick)}</b><span>TABLE ${esc(state.table)} · ${esc(state.deviceId.slice(-6).toUpperCase())}</span></div></div>
 <p class="small">进入 Match Pool 后，只有其他桌、未被你匹配过的玩家才会进入候选。</p></div>
 <button class="btn primary" id="queue">FIND MY MATCH</button><button class="btn secondary" id="back">NOT NOW</button>`,48);
 document.getElementById("back").onclick=()=>{state.stats.skips++;state.routeFinal="observer";save();tap();deepSolo()};
 document.getElementById("queue").onclick=()=>{tap();queueForMatch()};
}

async function queueForMatch(){
 shell(`<div class="kicker">MATCHING</div><h2 class="title">正在找另一个人。</h2><div class="waiting"></div><p class="lead" style="text-align:center">系统只会匹配<strong style="color:var(--ink)">其他桌</strong>的独立玩家。<br>如果现场只有你这一桌进入 Match Pool，就会继续等待。</p><button class="btn secondary" id="cancel">CANCEL</button>`,55);
 document.getElementById("cancel").onclick=()=>{clearInterval(matchPoll);state.stats.skips++;save();deepSolo()};
 let r=await B.queue({deviceId:state.deviceId,nick:state.nick,table:state.table,mode:state.mode});
 if(r.ok&&r.match)return showMatch(r.match);
 if(!B.configured()){
   setTimeout(()=>demoMatch(),1300);return;
 }
 clearInterval(matchPoll);
 matchPoll=setInterval(async()=>{
   let s=await B.matchStatus({deviceId:state.deviceId});
   if(s.ok&&s.match){clearInterval(matchPoll);showMatch(s.match)}
 },2500);
}

function demoMatch(){
 // Offline preview deliberately creates a unique-looking demo partner, not a real person.
 const demo={matchId:"DEMO-"+Math.random().toString(36).slice(2,7),partnerNick:"DEMO PLAYER",partnerTable:"B"+(Math.floor(Math.random()*8)+1),myCode:String(Math.floor(1000+Math.random()*9000)),demo:true};
 showMatch(demo);
}

function showMatch(m){
 state.match=m;state.stats.accepted++;save();A.impact();
 shell(`<div class="kicker">${m.demo?"PREVIEW MATCH":"MATCH FOUND"}</div><h2 class="title">找到你的 Match。</h2>
 <div class="card matchCard"><span class="pill">YOUR MATCH</span><div class="matchName">${esc(m.partnerNick)}</div><div class="tableBadge">TABLE ${esc(m.partnerTable)}</div>
 <p class="lead" style="margin-top:18px">你只需要找到这个人。对方手机也会显示你的昵称和桌号。</p></div>
 <button class="btn primary" id="meet">I FOUND THEM</button><button class="btn secondary" id="cant">找不到 / 换人</button>`,63);
 document.getElementById("cant").onclick=()=>{state.stats.skips++;delete state.match;save();tap();queueForMatch()};
 document.getElementById("meet").onclick=()=>{tap();verificationIntro()};
}

function verificationIntro(){
 let m=state.match;
 shell(`<div class="kicker">VERIFY THE CONNECTION</div><h2 class="title">不是按“完成”就算。</h2><p class="lead">见到对方后，把你手机上的 4 位码给对方。你也输入对方手机显示的码。</p>
 <div class="card"><div class="small">SHOW THIS TO ${esc(m.partnerNick)}</div><div class="code">${esc(m.myCode||"----")}</div></div>
 <button class="btn primary" id="input">ENTER THEIR CODE</button><button class="btn secondary" id="notfound">其实没找到</button>`,70);
 document.getElementById("notfound").onclick=()=>{state.stats.skips++;save();queueForMatch()};
 document.getElementById("input").onclick=()=>verifyCode();
}

function verifyCode(){
 shell(`<div class="kicker">CONNECTION CHECK</div><h2 class="title">输入对方的 4 位码。</h2>
 <div class="card"><input class="field" id="codeInput" inputmode="numeric" maxlength="4" placeholder="0000" style="text-align:center;font-size:34px;letter-spacing:.22em;font-weight:900"></div>
 <button class="btn primary" id="verify">VERIFY</button><button class="btn secondary" id="showMine">返回看我的码</button>`,74);
 document.getElementById("showMine").onclick=verificationIntro;
 document.getElementById("verify").onclick=async()=>{
   let code=document.getElementById("codeInput").value.trim();
   if(!/^\d{4}$/.test(code))return toast("需要 4 位数字");
   let m=state.match;
   if(m.demo){return verificationSuccess(true)}
   let r=await B.verify({deviceId:state.deviceId,matchId:m.matchId,partnerCode:code});
   if(r.ok&&r.verified)verificationSuccess(false);else toast("码不对，看看对方手机");
 };
}

function verificationSuccess(demo){
 state.stats.verified++;state.stats.peopleMet++;state.stats.completed++;save();A.impact();
 shell(`<div class="successMark">✓</div><div class="kicker">${demo?"PREVIEW VERIFIED":"CONNECTION VERIFIED"}</div><h2 class="title">你们真的找到彼此了。</h2>
 <div class="card"><span class="pill">UNLOCKED</span><div class="question" style="margin-top:14px">${esc(pick(C.deep))}</div><p class="small">两个人都回答。聊起来就把手机收起来。</p></div>
 <button class="btn primary" id="continue">DONE</button>`,80);
 document.getElementById("continue").onclick=()=>{tap();afterMatchChoice()};
}

function afterMatchChoice(){
 shell(`<div class="kicker">AFTER THE MATCH</div><h2 class="title">现在不一定要继续社交。</h2><div class="choices">
 <button class="choice" id="rest"><strong>BACK TO MY TABLE</strong><span>回去朋友桌，进入今晚收尾。</span></button>
 <button class="choice" id="another"><strong>ONE MORE MATCH</strong><span>再匹配一次，但不会匹配刚才的人。</span></button></div>`,84);
 document.getElementById("rest").onclick=()=>{state.routeFinal="connector";save();tap();deepSolo()};
 document.getElementById("another").onclick=()=>{state.routeFinal="connector";delete state.match;save();tap();openRoute()};
}

function deepSolo(){
 let q=pick(C.deep);
 shell(`<div class="kicker">ONE LAST CARD</div><h2 class="title">留一个问题给今晚。</h2><div class="card"><div class="question">${esc(q)}</div><p class="small">可以问朋友、刚认识的人，也可以自己回答。</p></div>
 <button class="btn primary" id="done">I'M DONE</button><button class="btn secondary" id="swap">换一个</button>`,89);
 document.getElementById("swap").onclick=()=>{state.stats.skips++;save();deepSolo()};
 document.getElementById("done").onclick=()=>{state.stats.completed++;save();tap();taste()};
}

function taste(){
 shell(`<div class="kicker">BARTENDER DISCOVERY</div><h2 class="title">今晚想喝什么方向？</h2><p class="lead">这是推荐，不是购买要求；也可以选择无酒精版本。</p>
 <div class="grid2"><button class="choice taste" data-t="sweet"><strong>甜</strong><span>果香 / 顺口</span></button><button class="choice taste" data-t="sour"><strong>酸</strong><span>明亮 / 清醒</span></button><button class="choice taste" data-t="fresh"><strong>清爽</strong><span>柑橘 / 气泡</span></button><button class="choice taste" data-t="help"><strong>救我</strong><span>让 Bartender 问我</span></button></div><div id="rec"></div>
 <button class="btn secondary" id="end">SEE MY NIGHT</button>`,94);
 const map={sweet:["FRUITY / SMOOTH","甜一点，但不要腻。"],sour:["BRIGHT / SHARP","酸感明显一点。"],fresh:["LIGHT / FRESH","清爽、柑橘或气泡方向。"],help:["BARTENDER CHOICE","你先问我三个问题，再帮我选。"]};
 document.querySelectorAll("[data-t]").forEach(b=>b.onclick=()=>{state.taste=b.dataset.t;save();tap();let r=map[b.dataset.t];document.getElementById("rec").innerHTML=`<div class="card" style="margin-top:12px"><span class="pill">${r[0]}</span><div class="question" style="margin-top:12px">“${r[1]}”</div><p class="small">把这句话给 Bartender 看即可。</p></div>`});
 document.getElementById("end").onclick=()=>{tap();ending()};
}

function ending(){
 let s=state.stats,type,title,copy;
 if(s.verified>=2){type="THE CONNECTOR";title="你今晚真的把人连起来了。";copy=`${s.peopleMet} 个 verified connections。你不是来刷题的。`}
 else if(s.verified===1){type="ONE GOOD MATCH";title="认识一个，就够了。";copy="至少今晚结束前，有一个人不再完全是陌生人。"}
 else if(state.mode==="chill"&&s.skips<3){type="THE HOME TABLE";title="你没有到处跑。";copy="但你自己的朋友已经够你玩了。"}
 else if(s.skips>=3||state.routeFinal==="observer"){type="PROFESSIONAL OBSERVER";title="你成功避开了大部分社交任务。";copy="Respect. 看戏也是今晚的一种玩法。"}
 else if(state.mode==="surprise"){type="CHAOS ENJOYER";title="你明明可以选 CHILL。";copy="但你把路线交给系统了。这个结果是你自己造成的。"}
 else{type="YOUR OWN NIGHT";title="没有标准答案。";copy="你走的是自己的路线。"}
 shell(`<div class="resultTag">TONIGHT TYPE</div><div class="endingType">${type}</div><h2 class="title">${title}</h2><p class="lead">${copy}</p>
 <div class="grid2"><div class="stat"><b>${s.warm}</b><span>WARM UPS</span></div><div class="stat"><b>${s.verified}</b><span>VERIFIED</span></div><div class="stat"><b>${s.peopleMet}</b><span>PEOPLE MET</span></div><div class="stat"><b>${s.skips}</b><span>SKIPS</span></div></div>
 <button class="btn primary" id="again">BACK TO TONIGHT</button><button class="btn tertiary" id="reset">RESET MY NIGHT</button>
 <div class="footer">YETIPSY · 今晚有局<br>ONE PERSON · ONE PHONE</div>`,100);
 document.getElementById("again").onclick=()=>{tap();afterMatchChoice()};
 document.getElementById("reset").onclick=()=>{localStorage.removeItem("yt_v2_state");location.reload()};
}

home();