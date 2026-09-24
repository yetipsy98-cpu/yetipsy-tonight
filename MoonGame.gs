/*
YÉ TIPSY · 月满杯盈 V11
完整 Staff QR / Customer Shake / Claim / Redeem / Admin backend
与现有 Tonight Code.gs 同一个 Apps Script Project。
Code.gs 保留 case "moon": return json_(moonApi_(ss, data));
*/
const MOON_CLAIMS="MOON_GAME";
const MOON_SESSIONS="MOON_SESSIONS";
const MOON_CONFIG="MOON_CONFIG";
const MOON_REWARDS="MOON_REWARDS";
const MOON_STAFF="MOON_STAFF_SESSIONS";

const CLAIM_HEADERS=["recovery_code","created_at","country","whatsapp","dice","ones","reward_id","reward_name","community_opt_in","whatsapp_status","sent_at","redeemed","redeemed_at"];
const SESSION_HEADERS=["game_token","created_at","expires_at","used_at","status","reward_id","dice"];
const CONFIG_HEADERS=["key","value","note"];
const REWARD_HEADERS=["reward_id","reward_name","display_ones","probability","enabled","sort_order"];
const STAFF_HEADERS=["staff_token","created_at","expires_at","username"];

function setupMoonGame(){
  const ss=getDB_();
  moon_ensureSheet_(ss,MOON_CLAIMS,CLAIM_HEADERS);
  moon_ensureSheet_(ss,MOON_SESSIONS,SESSION_HEADERS);
  const cfg=moon_ensureSheet_(ss,MOON_CONFIG,CONFIG_HEADERS);
  const rw=moon_ensureSheet_(ss,MOON_REWARDS,REWARD_HEADERS);
  moon_ensureSheet_(ss,MOON_STAFF,STAFF_HEADERS);

  moon_defaultConfig_(cfg,"ACTIVITY_ENABLED","TRUE","TRUE=开放 / FALSE=关闭");
  moon_defaultConfig_(cfg,"STAFF_USERNAME","staff","服务员登入账号");
  moon_defaultConfig_(cfg,"STAFF_LOGIN_PASSWORD","CHANGE-STAFF","服务员登入密码");
  moon_defaultConfig_(cfg,"ADMIN_PASSWORD","CHANGE-ADMIN","Admin 页面密码");
  moon_defaultConfig_(cfg,"GAME_TOKEN_TTL_MINUTES","10","二维码游戏有效分钟");
  moon_defaultConfig_(cfg,"STAFF_LOGIN_HOURS","12","服务员登入有效小时");
  moon_defaultConfig_(cfg,"WHATSAPP_SEND_DAYS","3","奖励承诺发送工作日");

  if(rw.getLastRow()<2)rw.getRange(2,1,4,6).setValues([
    ["R5","断片指南系列 · 任一杯",5,0.5,"TRUE",1],
    ["R4","微醺特调系列 · 任一杯",4,2.0,"TRUE",2],
    ["R3","彩虹 Shot × 1",3,12.5,"TRUE",3],
    ["R0","RM5 Voucher",0,85.0,"TRUE",4]
  ]);
  SpreadsheetApp.flush();
  return {ok:true,spreadsheet:ss.getName()};
}

function moonApi_(ss,d){
  switch(String(d.subaction||"")){
    case "staffLogin":return moon_staffLogin_(ss,d);
    case "staffCreateGame":return moon_staffCreateGame_(ss,d);
    case "staffRedeemLookup":return moon_staffRedeemLookup_(ss,d);
    case "staffRedeem":return moon_staffRedeem_(ss,d);
    case "gameOpen":return moon_gameOpen_(ss,d);
    case "claim":return moon_claim_(ss,d);
    case "adminLogin":return moon_adminLogin_(ss,d);
    case "adminState":return moon_adminState_(ss,d);
    case "adminSaveConfig":return moon_adminSaveConfig_(ss,d);
    case "adminSaveRewards":return moon_adminSaveRewards_(ss,d);
    case "adminUpdateClaim":return moon_adminUpdateClaim_(ss,d);
    default:return {ok:false,error:"unknown_moon_action",subaction:d.subaction||""};
  }
}
function moon_ensureSheet_(ss,n,h){let sh=ss.getSheetByName(n);if(!sh)sh=ss.insertSheet(n);if(sh.getMaxColumns()<h.length)sh.insertColumnsAfter(sh.getMaxColumns(),h.length-sh.getMaxColumns());sh.getRange(1,1,1,h.length).setValues([h]);sh.setFrozenRows(1);return sh}
function moon_defaultConfig_(sh,k,v,n){if(!moon_configRow_(sh,k))sh.appendRow([k,v,n])}
function moon_configRow_(sh,k){if(!sh||sh.getLastRow()<2)return null;const v=sh.getRange(2,1,sh.getLastRow()-1,3).getValues(),t=String(k).toUpperCase();for(let i=0;i<v.length;i++)if(String(v[i][0]).toUpperCase()===t)return{row:i+2,value:v[i][1],note:v[i][2]};return null}
function moon_config_(ss,k,f){const r=moon_configRow_(ss.getSheetByName(MOON_CONFIG),k);return r?r.value:f}
function moon_setConfig_(ss,k,v){const sh=ss.getSheetByName(MOON_CONFIG),r=moon_configRow_(sh,k);if(r)sh.getRange(r.row,2).setValue(v);else sh.appendRow([k,v,""])}
function moon_enabled_(ss){return String(moon_config_(ss,"ACTIVITY_ENABLED","TRUE")).toUpperCase()==="TRUE"}
function moon_gameTtl_(ss){return Math.max(2,Math.min(60,Number(moon_config_(ss,"GAME_TOKEN_TTL_MINUTES","10"))||10))*60000}
function moon_rewards_(ss){const sh=ss.getSheetByName(MOON_REWARDS);if(!sh||sh.getLastRow()<2)return[];return sh.getRange(2,1,sh.getLastRow()-1,6).getValues().map(r=>({id:String(r[0]),name:String(r[1]),displayOnes:Number(r[2]),probability:Number(r[3]),enabled:String(r[4]).toUpperCase()==="TRUE",sort:Number(r[5])})).sort((a,b)=>a.sort-b.sort)}
function moon_cachedRewards_(ss){const c=CacheService.getScriptCache(),k="MOON_REWARD_CONFIG_V11",h=c.get(k);if(h){try{return JSON.parse(h)}catch(e){}}const r=moon_rewards_(ss).filter(x=>x.enabled);c.put(k,JSON.stringify(r),300);return r}
function moon_clearRewardCache_(){CacheService.getScriptCache().remove("MOON_REWARD_CONFIG_V11")}
function moon_preparedResult_(ss){
  const rs=moon_cachedRewards_(ss);if(!rs.length)throw new Error("no_enabled_rewards");
  const total=rs.reduce((s,r)=>s+Number(r.probability||0),0);if(Math.abs(total-100)>.001)throw new Error("probability_total_must_be_100");
  let x=Math.random()*100,ch=rs[rs.length-1];for(const r of rs){x-=Number(r.probability||0);if(x<0){ch=r;break}}
  let ones=ch.id==="R0"?Math.floor(Math.random()*3):Number(ch.displayOnes||0);ones=Math.max(0,Math.min(5,ones));
  const dice=[];for(let i=0;i<ones;i++)dice.push(1);while(dice.length<5)dice.push(2+Math.floor(Math.random()*5));
  for(let i=4;i>0;i--){const j=Math.floor(Math.random()*(i+1));[dice[i],dice[j]]=[dice[j],dice[i]]}
  return{rewardId:ch.id,reward:ch.name,displayOnes:ones,dice};
}
function moon_staffLogin_(ss,d){
  const u=String(moon_config_(ss,"STAFF_USERNAME","staff")),p=String(moon_config_(ss,"STAFF_LOGIN_PASSWORD","CHANGE-STAFF"));
  if(String(d.username||"").trim()!==u||String(d.password||"")!==p)return{ok:false,error:"wrong_login"};
  const t=Utilities.getUuid(),now=new Date(),hrs=Math.max(1,Math.min(24,Number(moon_config_(ss,"STAFF_LOGIN_HOURS","12"))||12)),exp=new Date(now.getTime()+hrs*3600000);
  ss.getSheetByName(MOON_STAFF).appendRow([t,now,exp,u]);return{ok:true,staffToken:t,expiresAt:exp.toISOString(),username:u};
}
function moon_staffAuth_(ss,t){
  const sh=ss.getSheetByName(MOON_STAFF);if(!sh||sh.getLastRow()<2)return false;
  const v=sh.getRange(2,1,sh.getLastRow()-1,4).getValues(),now=Date.now();
  for(let i=v.length-1;i>=0;i--)if(String(v[i][0])===String(t||"")&&new Date(v[i][2]).getTime()>now)return true;
  return false;
}
function moon_staffCreateGame_(ss,d){
  if(!moon_staffAuth_(ss,d.staffToken))return{ok:false,error:"staff_auth"};
  if(!moon_enabled_(ss))return{ok:false,error:"activity_closed"};
  const sh=ss.getSheetByName(MOON_SESSIONS),t=Utilities.getUuid(),now=new Date(),exp=new Date(now.getTime()+moon_gameTtl_(ss)),r=moon_preparedResult_(ss);
  sh.appendRow([t,now,exp,"","READY",r.rewardId,r.dice.join(",")]);
  return{ok:true,gameToken:t,shortCode:t.replace(/-/g,"").slice(0,8).toUpperCase(),expiresAt:exp.toISOString()};
}
function moon_session_(sh,t){if(!sh||sh.getLastRow()<2)return null;const v=sh.getRange(2,1,sh.getLastRow()-1,SESSION_HEADERS.length).getValues();for(let i=0;i<v.length;i++)if(String(v[i][0])===String(t||""))return{row:i+2,data:v[i]};return null}
function moon_validGame_(ss,t){
  const sh=ss.getSheetByName(MOON_SESSIONS),s=moon_session_(sh,t);if(!s)return{ok:false,error:"invalid_game"};
  if(String(s.data[4])!=="READY"||s.data[3])return{ok:false,error:"game_used"};
  const exp=new Date(s.data[2]).getTime();if(!exp||Date.now()>exp){sh.getRange(s.row,5).setValue("EXPIRED");return{ok:false,error:"game_expired"}}
  return{ok:true,sheet:sh,session:s};
}
function moon_gameOpen_(ss,d){
  if(!moon_enabled_(ss))return{ok:false,error:"activity_closed"};
  const c=moon_validGame_(ss,d.gameToken);if(!c.ok)return c;
  const id=String(c.session.data[5]||""),dice=String(c.session.data[6]||"").split(",").map(Number),rw=moon_rewards_(ss).find(x=>x.id===id);
  if(!rw)return{ok:false,error:"reward_not_found"};
  return{ok:true,gameToken:d.gameToken,rollResult:{rewardId:id,reward:rw.name,displayOnes:dice.filter(x=>x===1).length,dice}};
}
function moon_claim_(ss,d){
  const lock=LockService.getScriptLock();lock.waitLock(10000);
  try{
    const c=moon_validGame_(ss,d.gameToken);if(!c.ok)return c;
    const id=String(c.session.data[5]||""),diceText=String(c.session.data[6]||""),rw=moon_rewards_(ss).find(x=>x.id===id);if(!rw)return{ok:false,error:"reward_not_found"};
    const cc=String(d.countryCode||""),digits=String(d.phone||"").replace(/\D/g,""),phone=cc+digits;
    if(!["+60","+65"].includes(cc))return{ok:false,error:"invalid_country"};
    if(cc==="+65"&&!/^\+65\d{8}$/.test(phone))return{ok:false,error:"invalid_phone"};
    if(cc==="+60"&&!/^\+60\d{9,11}$/.test(phone))return{ok:false,error:"invalid_phone"};
    const sh=ss.getSheetByName(MOON_CLAIMS),code=moon_recoveryCode_(sh),now=new Date(),dice=diceText.split(",").map(Number);
    sh.appendRow([code,now,cc==="+65"?"SG":"MY",phone,diceText,dice.filter(x=>x===1).length,rw.id,rw.name,d.communityOptIn?"YES":"NO","PENDING","","NO",""]);
    c.sheet.getRange(c.session.row,4).setValue(now);c.sheet.getRange(c.session.row,5).setValue("USED");SpreadsheetApp.flush();
    return{ok:true,recoveryCode:code,reward:rw.name,whatsapp:phone,status:"PENDING",sendWithinBusinessDays:Number(moon_config_(ss,"WHATSAPP_SEND_DAYS","3"))||3};
  }finally{lock.releaseLock()}
}
function moon_recoveryCode_(sh){for(let i=0;i<30;i++){const c="YT-MOON-"+Utilities.getUuid().replace(/-/g,"").slice(0,8).toUpperCase();if(sh.getLastRow()<2)return c;const f=sh.getRange(2,1,sh.getLastRow()-1,1).createTextFinder(c).matchEntireCell(true).findNext();if(!f)return c}throw new Error("recovery_code_generation_failed")}
function moon_claimByCode_(ss,code){
  const sh=ss.getSheetByName(MOON_CLAIMS);if(!sh||sh.getLastRow()<2)return null;
  const f=sh.getRange(2,1,sh.getLastRow()-1,1).createTextFinder(String(code||"").trim().toUpperCase()).matchEntireCell(true).findNext();if(!f)return null;
  const row=f.getRow(),r=sh.getRange(row,1,1,CLAIM_HEADERS.length).getValues()[0];
  return{row,code:r[0],created:r[1],phone:r[3],dice:r[4],ones:r[5],rewardId:r[6],reward:r[7],status:r[9],sentAt:r[10],redeemed:String(r[11]).toUpperCase()==="YES",redeemedAt:r[12]};
}
function moon_staffRedeemLookup_(ss,d){
  if(!moon_staffAuth_(ss,d.staffToken))return{ok:false,error:"staff_auth"};
  const c=moon_claimByCode_(ss,d.code);if(!c)return{ok:false,error:"code_not_found"};
  return{ok:true,claim:c};
}
function moon_staffRedeem_(ss,d){
  if(!moon_staffAuth_(ss,d.staffToken))return{ok:false,error:"staff_auth"};
  const lock=LockService.getScriptLock();lock.waitLock(7000);
  try{const c=moon_claimByCode_(ss,d.code);if(!c)return{ok:false,error:"code_not_found"};if(c.redeemed)return{ok:false,error:"already_redeemed",claim:c};
    const sh=ss.getSheetByName(MOON_CLAIMS),now=new Date();sh.getRange(c.row,12).setValue("YES");sh.getRange(c.row,13).setValue(now);SpreadsheetApp.flush();return{ok:true,reward:c.reward,code:c.code,redeemedAt:now.toISOString()};
  }finally{lock.releaseLock()}
}
function moon_adminLogin_(ss,d){const p=String(moon_config_(ss,"ADMIN_PASSWORD",""));if(String(d.password||"")!==p)return{ok:false,error:"wrong_admin_password"};const t=Utilities.getUuid();CacheService.getScriptCache().put("moon_admin_"+t,"1",21600);return{ok:true,adminToken:t}}
function moon_adminAuth_(d){return!!CacheService.getScriptCache().get("moon_admin_"+String(d.adminToken||""))}
function moon_adminState_(ss,d){
  if(!moon_adminAuth_(d))return{ok:false,error:"admin_auth"};const claims=[],sh=ss.getSheetByName(MOON_CLAIMS);
  if(sh&&sh.getLastRow()>=2){const n=Math.min(100,sh.getLastRow()-1),start=sh.getLastRow()-n+1,rows=sh.getRange(start,1,n,CLAIM_HEADERS.length).getValues();rows.reverse().forEach(r=>claims.push({code:r[0],created:r[1],country:r[2],phone:r[3],dice:r[4],ones:r[5],rewardId:r[6],reward:r[7],community:r[8],status:r[9],sentAt:r[10],redeemed:r[11],redeemedAt:r[12]}))}
  return{ok:true,config:{activityEnabled:moon_enabled_(ss),staffUsername:String(moon_config_(ss,"STAFF_USERNAME","staff")),gameTtl:Number(moon_config_(ss,"GAME_TOKEN_TTL_MINUTES","10")),staffHours:Number(moon_config_(ss,"STAFF_LOGIN_HOURS","12")),sendDays:Number(moon_config_(ss,"WHATSAPP_SEND_DAYS","3"))},rewards:moon_rewards_(ss),claims};
}
function moon_adminSaveConfig_(ss,d){
  if(!moon_adminAuth_(d))return{ok:false,error:"admin_auth"};
  if(typeof d.activityEnabled!=="undefined")moon_setConfig_(ss,"ACTIVITY_ENABLED",d.activityEnabled?"TRUE":"FALSE");
  if(String(d.staffUsername||"").trim())moon_setConfig_(ss,"STAFF_USERNAME",String(d.staffUsername).trim());
  if(String(d.staffPassword||"").trim())moon_setConfig_(ss,"STAFF_LOGIN_PASSWORD",String(d.staffPassword).trim());
  if(String(d.adminPassword||"").trim())moon_setConfig_(ss,"ADMIN_PASSWORD",String(d.adminPassword).trim());
  if(d.gameTtl)moon_setConfig_(ss,"GAME_TOKEN_TTL_MINUTES",String(Math.max(2,Math.min(60,Number(d.gameTtl)||10))));
  if(d.staffHours)moon_setConfig_(ss,"STAFF_LOGIN_HOURS",String(Math.max(1,Math.min(24,Number(d.staffHours)||12))));
  SpreadsheetApp.flush();return{ok:true};
}
function moon_adminSaveRewards_(ss,d){
  if(!moon_adminAuth_(d))return{ok:false,error:"admin_auth"};const rows=Array.isArray(d.rewards)?d.rewards:[];if(!rows.length)return{ok:false,error:"no_rewards"};
  const a=rows.map((x,i)=>({id:String(x.id||"").trim(),name:String(x.name||"").trim(),displayOnes:Math.max(0,Math.min(5,Number(x.displayOnes)||0)),probability:Number(x.probability)||0,enabled:!!x.enabled,sort:i+1}));
  if(a.some(x=>!x.id||!x.name))return{ok:false,error:"invalid_reward"};const total=a.filter(x=>x.enabled).reduce((s,x)=>s+x.probability,0);if(Math.abs(total-100)>.001)return{ok:false,error:"probability_total",total};
  const sh=ss.getSheetByName(MOON_REWARDS);if(sh.getLastRow()>1)sh.getRange(2,1,sh.getLastRow()-1,6).clearContent();sh.getRange(2,1,a.length,6).setValues(a.map(x=>[x.id,x.name,x.displayOnes,x.probability,x.enabled?"TRUE":"FALSE",x.sort]));SpreadsheetApp.flush();moon_clearRewardCache_();return{ok:true};
}
function moon_adminUpdateClaim_(ss,d){
  if(!moon_adminAuth_(d))return{ok:false,error:"admin_auth"};const c=moon_claimByCode_(ss,d.code);if(!c)return{ok:false,error:"not_found"};const sh=ss.getSheetByName(MOON_CLAIMS),now=new Date();
  if(d.status==="SENT"){sh.getRange(c.row,10).setValue("SENT");sh.getRange(c.row,11).setValue(now)}
  if(d.status==="PENDING"){sh.getRange(c.row,10).setValue("PENDING");sh.getRange(c.row,11).setValue("")}
  if(d.status==="REDEEMED"){if(c.redeemed)return{ok:false,error:"already_redeemed"};sh.getRange(c.row,12).setValue("YES");sh.getRange(c.row,13).setValue(now)}
  SpreadsheetApp.flush();return{ok:true};
}
