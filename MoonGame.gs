/*
YÉ TIPSY · 月满杯盈 V2 — MoonGame.gs
放在现有 MINIGAME Google Sheet 绑定的 Apps Script Project 内。
本文件刻意不定义 doPost()/doGet()，避免和 Code.gs 冲突。

Code.gs 只需增加 1 条路由：
case "moon": return json_(moonApi_(ss, data));

然后所有活动功能都在本文件内部处理。
*/

const MOON_CLAIMS = "MOON_GAME";
const MOON_SESSIONS = "MOON_SESSIONS";
const MOON_CONFIG = "MOON_CONFIG";
const MOON_REWARDS = "MOON_REWARDS";

const MOON_CLAIM_HEADERS = [
  "recovery_code","created_at","country","whatsapp","dice","ones","reward_id","reward_name",
  "community_opt_in","whatsapp_status","sent_at","redeemed","redeemed_at"
];
const MOON_SESSION_HEADERS = ["unlock_token","created_at","expires_at","used_at","status"];
const MOON_CONFIG_HEADERS = ["key","value","note"];
const MOON_REWARD_HEADERS = ["reward_id","reward_name","display_ones","probability","enabled","sort_order"];

function setupMoonGame(){
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  if (!ss) throw new Error("请从 MINIGAME Google Sheet → 扩展程序 → Apps Script 打开。");

  ensureMoonSheet_(ss, MOON_CLAIMS, MOON_CLAIM_HEADERS);
  ensureMoonSheet_(ss, MOON_SESSIONS, MOON_SESSION_HEADERS);
  const cfg = ensureMoonSheet_(ss, MOON_CONFIG, MOON_CONFIG_HEADERS);
  const rewards = ensureMoonSheet_(ss, MOON_REWARDS, MOON_REWARD_HEADERS);

  moonDefaultConfig_(cfg,"ACTIVITY_ENABLED","TRUE","TRUE=开放 / FALSE=关闭");
  moonDefaultConfig_(cfg,"STAFF_PASSWORD","CHANGE-ME","员工每局解锁密码；Admin 可修改");
  moonDefaultConfig_(cfg,"ADMIN_PASSWORD","CHANGE-ADMIN","Admin 页面密码");
  moonDefaultConfig_(cfg,"TOKEN_TTL_MINUTES","5","每次员工解锁有效分钟");
  moonDefaultConfig_(cfg,"WHATSAPP_SEND_DAYS","3","WhatsApp 奖励承诺发送工作日");

  if (rewards.getLastRow() < 2) {
    rewards.getRange(2,1,4,6).setValues([
      ["R5","断片指南系列 · 任一杯",5,0.5,"TRUE",1],
      ["R4","微醺特调系列 · 任一杯",4,2.0,"TRUE",2],
      ["R3","彩虹 Shot × 1",3,12.5,"TRUE",3],
      ["R0","RM5 Voucher",0,85.0,"TRUE",4]
    ]);
  }
  SpreadsheetApp.flush();
  return {ok:true};
}

function moonApi_(ss,d){
  const sub = String(d.subaction || "");
  if (sub === "unlock") return moonUnlock_(ss,d);
  if (sub === "roll") return moonRoll_(ss,d);
  if (sub === "claim") return moonClaim_(ss,d);
  if (sub === "adminLogin") return moonAdminLogin_(ss,d);
  if (sub === "adminState") return moonAdminState_(ss,d);
  if (sub === "adminSaveConfig") return moonAdminSaveConfig_(ss,d);
  if (sub === "adminSaveRewards") return moonAdminSaveRewards_(ss,d);
  if (sub === "adminUpdateClaim") return moonAdminUpdateClaim_(ss,d);
  return {ok:false,error:"unknown_moon_action"};
}

function ensureMoonSheet_(ss,name,headers){
  let sh=ss.getSheetByName(name); if(!sh) sh=ss.insertSheet(name);
  if(sh.getMaxColumns()<headers.length) sh.insertColumnsAfter(sh.getMaxColumns(),headers.length-sh.getMaxColumns());
  sh.getRange(1,1,1,headers.length).setValues([headers]); sh.setFrozenRows(1); return sh;
}
function moonDefaultConfig_(sh,key,value,note){
  if(!moonConfigRow_(sh,key)) sh.appendRow([key,value,note]);
}
function moonConfigRow_(sh,key){
  if(sh.getLastRow()<2)return null;
  const v=sh.getRange(2,1,sh.getLastRow()-1,3).getValues();
  for(let i=0;i<v.length;i++)if(String(v[i][0]).toUpperCase()===String(key).toUpperCase())return {row:i+2,value:v[i][1],note:v[i][2]};
  return null;
}
function moonConfig_(ss,key,fallback){
  const sh=ss.getSheetByName(MOON_CONFIG),r=sh&&moonConfigRow_(sh,key); return r?r.value:fallback;
}
function moonEnabled_(ss){return String(moonConfig_(ss,"ACTIVITY_ENABLED","TRUE")).toUpperCase()==="TRUE";}
function moonTokenTtl_(ss){const n=Number(moonConfig_(ss,"TOKEN_TTL_MINUTES","5"));return Math.max(1,Math.min(30,isFinite(n)?n:5))*60000;}

function moonUnlock_(ss,d){
  if(!moonEnabled_(ss))return {ok:false,error:"activity_closed"};
  const expected=String(moonConfig_(ss,"STAFF_PASSWORD",""));
  if(!expected||expected==="CHANGE-ME")return {ok:false,error:"password_not_configured"};
  if(String(d.password||"")!==expected)return {ok:false,error:"wrong_password"};
  const sh=ss.getSheetByName(MOON_SESSIONS),token=Utilities.getUuid(),now=new Date(),exp=new Date(now.getTime()+moonTokenTtl_(ss));
  sh.appendRow([token,now,exp,"","UNLOCKED"]); return {ok:true,unlockToken:token,expiresAt:exp.toISOString()};
}
function moonSession_(sh,token){
  if(sh.getLastRow()<2)return null;
  const v=sh.getRange(2,1,sh.getLastRow()-1,5).getValues();
  for(let i=0;i<v.length;i++)if(String(v[i][0])===String(token||""))return {row:i+2,data:v[i]}; return null;
}
function moonRequireSession_(ss,token){
  const sh=ss.getSheetByName(MOON_SESSIONS),s=moonSession_(sh,token);
  if(!s)return {ok:false,error:"invalid_unlock"};
  if(String(s.data[4])!=="UNLOCKED"||s.data[3])return {ok:false,error:"unlock_used"};
  if(Date.now()>new Date(s.data[2]).getTime()){sh.getRange(s.row,5).setValue("EXPIRED");return {ok:false,error:"unlock_expired"};}
  return {ok:true,session:s,sheet:sh};
}

function moonRewards_(ss){
  const sh=ss.getSheetByName(MOON_REWARDS); if(!sh||sh.getLastRow()<2)return [];
  return sh.getRange(2,1,sh.getLastRow()-1,6).getValues().map(r=>({
    id:String(r[0]),name:String(r[1]),displayOnes:Number(r[2]),probability:Number(r[3]),enabled:String(r[4]).toUpperCase()==="TRUE",sort:Number(r[5])
  })).sort((a,b)=>a.sort-b.sort);
}
function moonPickReward_(ss){
  const rows=moonRewards_(ss).filter(x=>x.enabled&&x.probability>0);
  const total=rows.reduce((s,x)=>s+x.probability,0);
  if(Math.abs(total-100)>0.001)throw new Error("reward_probability_must_equal_100");
  let r=Math.random()*100;
  for(const x of rows){r-=x.probability;if(r<0)return x;}
  return rows[rows.length-1];
}
function moonDiceForOnes_(ones){
  ones=Math.max(0,Math.min(5,Number(ones)||0));
  const a=[];
  for(let i=0;i<ones;i++)a.push(1);
  while(a.length<5)a.push(2+Math.floor(Math.random()*5));
  for(let i=a.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[a[i],a[j]]=[a[j],a[i]];}
  return a;
}

/* 中奖结果由后端先抽奖，再返回对应骰面。前端不能自己指定奖励。 */
function moonRoll_(ss,d){
  if(!moonEnabled_(ss))return {ok:false,error:"activity_closed"};
  const check=moonRequireSession_(ss,d.unlockToken); if(!check.ok)return check;
  const reward=moonPickReward_(ss),dice=moonDiceForOnes_(reward.displayOnes);
  return {ok:true,rewardId:reward.id,reward:reward.name,displayOnes:reward.displayOnes,dice:dice};
}

function moonClaim_(ss,d){
  const lock=LockService.getScriptLock();lock.waitLock(10000);
  try{
    const check=moonRequireSession_(ss,d.unlockToken);if(!check.ok)return check;
    const cc=String(d.countryCode||""),digits=String(d.phone||"").replace(/\D/g,""),phone=cc+digits;
    if(cc==="+65"&&!/^\+65\d{8}$/.test(phone))return {ok:false,error:"invalid_phone"};
    if(cc==="+60"&&!/^\+60\d{9,11}$/.test(phone))return {ok:false,error:"invalid_phone"};
    if(!["+60","+65"].includes(cc))return {ok:false,error:"invalid_country"};

    const rewards=moonRewards_(ss),rw=rewards.find(x=>x.id===String(d.rewardId||""));
    if(!rw)return {ok:false,error:"invalid_reward"};
    const dice=Array.isArray(d.dice)?d.dice.map(Number):[];
    if(dice.length!==5||dice.some(n=>!Number.isInteger(n)||n<1||n>6))return {ok:false,error:"invalid_dice"};
    if(dice.filter(n=>n===1).length!==rw.displayOnes)return {ok:false,error:"reward_dice_mismatch"};

    const claims=ss.getSheetByName(MOON_CLAIMS),code=moonCode_(claims),now=new Date();
    claims.appendRow([code,now,cc==="+65"?"SG":"MY",phone,dice.join(","),rw.displayOnes,rw.id,rw.name,d.communityOptIn?"YES":"NO","PENDING","","NO",""]);
    check.sheet.getRange(check.session.row,4).setValue(now);check.sheet.getRange(check.session.row,5).setValue("USED");
    SpreadsheetApp.flush();
    return {ok:true,recoveryCode:code,reward:rw.name,ones:rw.displayOnes,status:"PENDING",sendWithinBusinessDays:Number(moonConfig_(ss,"WHATSAPP_SEND_DAYS","3"))||3};
  }finally{lock.releaseLock();}
}
function moonCode_(sh){
  for(let i=0;i<20;i++){const c="YT-MOON-"+Utilities.getUuid().replace(/-/g,"").slice(0,8).toUpperCase();if(sh.getLastRow()<2||!sh.getRange(2,1,sh.getLastRow()-1,1).createTextFinder(c).matchEntireCell(true).findNext())return c;}throw new Error("code_generation_failed");
}

/* Admin session is short-lived and signed by CacheService. */
function moonAdminLogin_(ss,d){
  if(String(d.password||"")!==String(moonConfig_(ss,"ADMIN_PASSWORD","")))return {ok:false,error:"wrong_admin_password"};
  const token=Utilities.getUuid();CacheService.getScriptCache().put("moon_admin_"+token,"1",21600);return {ok:true,adminToken:token};
}
function moonAdminAuth_(d){return !!CacheService.getScriptCache().get("moon_admin_"+String(d.adminToken||""));}
function moonAdminState_(ss,d){
  if(!moonAdminAuth_(d))return {ok:false,error:"admin_auth"};
  const cfg={activityEnabled:moonEnabled_(ss),tokenTtl:Number(moonConfig_(ss,"TOKEN_TTL_MINUTES","5")),sendDays:Number(moonConfig_(ss,"WHATSAPP_SEND_DAYS","3"))};
  const rewards=moonRewards_(ss);
  const sh=ss.getSheetByName(MOON_CLAIMS),claims=[];
  if(sh&&sh.getLastRow()>=2){const v=sh.getRange(Math.max(2,sh.getLastRow()-99),1,Math.min(100,sh.getLastRow()-1),MOON_CLAIM_HEADERS.length).getValues();v.reverse().forEach(r=>claims.push({code:r[0],created:r[1],country:r[2],phone:r[3],dice:r[4],ones:r[5],rewardId:r[6],reward:r[7],community:r[8],status:r[9],sentAt:r[10],redeemed:r[11],redeemedAt:r[12]}));}
  return {ok:true,config:cfg,rewards:rewards,claims:claims};
}
function moonSetConfig_(ss,key,value){
  const sh=ss.getSheetByName(MOON_CONFIG),r=moonConfigRow_(sh,key);if(r)sh.getRange(r.row,2).setValue(value);else sh.appendRow([key,value,""]);
}
function moonAdminSaveConfig_(ss,d){
  if(!moonAdminAuth_(d))return {ok:false,error:"admin_auth"};
  if(typeof d.activityEnabled!=="undefined")moonSetConfig_(ss,"ACTIVITY_ENABLED",d.activityEnabled?"TRUE":"FALSE");
  if(d.staffPassword)moonSetConfig_(ss,"STAFF_PASSWORD",String(d.staffPassword));
  if(d.adminPassword)moonSetConfig_(ss,"ADMIN_PASSWORD",String(d.adminPassword));
  if(d.tokenTtl)moonSetConfig_(ss,"TOKEN_TTL_MINUTES",String(Math.max(1,Math.min(30,Number(d.tokenTtl)||5))));
  return {ok:true};
}
function moonAdminSaveRewards_(ss,d){
  if(!moonAdminAuth_(d))return {ok:false,error:"admin_auth"};
  const rows=Array.isArray(d.rewards)?d.rewards:[];
  if(!rows.length)return {ok:false,error:"no_rewards"};
  const enabled=rows.filter(x=>x.enabled),total=enabled.reduce((s,x)=>s+Number(x.probability||0),0);
  if(Math.abs(total-100)>0.001)return {ok:false,error:"probability_total",total:total};
  const sh=ss.getSheetByName(MOON_REWARDS);if(sh.getLastRow()>1)sh.getRange(2,1,sh.getLastRow()-1,6).clearContent();
  sh.getRange(2,1,rows.length,6).setValues(rows.map((x,i)=>[String(x.id),String(x.name),Number(x.displayOnes),Number(x.probability),x.enabled?"TRUE":"FALSE",i+1]));
  return {ok:true};
}
function moonAdminUpdateClaim_(ss,d){
  if(!moonAdminAuth_(d))return {ok:false,error:"admin_auth"};
  const sh=ss.getSheetByName(MOON_CLAIMS);if(!sh||sh.getLastRow()<2)return {ok:false,error:"not_found"};
  const f=sh.getRange(2,1,sh.getLastRow()-1,1).createTextFinder(String(d.code||"")).matchEntireCell(true).findNext();if(!f)return {ok:false,error:"not_found"};
  const row=f.getRow(),now=new Date();
  if(d.status==="SENT"){sh.getRange(row,10).setValue("SENT");sh.getRange(row,11).setValue(now);}
  if(d.status==="REDEEMED"){sh.getRange(row,12).setValue("YES");sh.getRange(row,13).setValue(now);}
  return {ok:true};
}
