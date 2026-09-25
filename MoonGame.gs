/*
YÉ TIPSY · 月满杯盈 V15.1 REDEEM REF
Staff QR / Customer Game / Claim / Redeem / Admin
与 Tonight Code.gs 共用同一个 Apps Script Project。
Code.gs 需要保留：
case "moon": return json_(moonApi_(ss, data));
*/

const MOON_CLAIMS="MOON_GAME";
const MOON_SESSIONS="MOON_SESSIONS";
const MOON_CONFIG="MOON_CONFIG";
const MOON_REWARDS="MOON_REWARDS";
const MOON_STAFF="MOON_STAFF_SESSIONS";
const MOON_STAFF_ACCOUNTS="MOON_STAFF_ACCOUNTS";

const CLAIM_HEADERS=["recovery_code","created_at","country","whatsapp","dice","ones","reward_id","reward_name","community_opt_in","whatsapp_status","sent_at","redeemed","redeemed_at","redeem_ref","redeemed_by"];
const SESSION_HEADERS=["game_token","created_at","expires_at","used_at","status","reward_id","dice"];
const CONFIG_HEADERS=["key","value","note"];
const REWARD_HEADERS=["reward_id","reward_name","display_ones","probability","enabled","sort_order"];
const STAFF_HEADERS=["staff_token","created_at","expires_at","username","auth_version"];
const STAFF_ACCOUNT_HEADERS=["username","password","display_name","enabled","auth_version"];

function setupMoonGame(){
  const ss=getDB_();
  moon_ensureSheet_(ss,MOON_CLAIMS,CLAIM_HEADERS);
  moon_ensureSheet_(ss,MOON_SESSIONS,SESSION_HEADERS);
  const cfg=moon_ensureSheet_(ss,MOON_CONFIG,CONFIG_HEADERS);
  const rw=moon_ensureSheet_(ss,MOON_REWARDS,REWARD_HEADERS);
  moon_ensureSheet_(ss,MOON_STAFF,STAFF_HEADERS);
  const staff=moon_ensureSheet_(ss,MOON_STAFF_ACCOUNTS,STAFF_ACCOUNT_HEADERS);

  moon_defaultConfig_(cfg,"ACTIVITY_ENABLED","TRUE","TRUE=开放 / FALSE=关闭");
  moon_defaultConfig_(cfg,"ADMIN_PASSWORD","CHANGE-ADMIN","Admin 页面密码");
  moon_defaultConfig_(cfg,"GAME_TOKEN_TTL_MINUTES","20","每局二维码有效分钟");
  moon_defaultConfig_(cfg,"STAFF_LOGIN_DAYS","30","员工设备保持登入天数");
  moon_defaultConfig_(cfg,"WHATSAPP_SEND_DAYS","3","奖励发送工作日");

  if(staff.getLastRow()<2){
    staff.getRange(2,1,3,5).setValues([
      ["staff1","CHANGE-STAFF-1","员工 1","TRUE",1],
      ["staff2","CHANGE-STAFF-2","员工 2","TRUE",1],
      ["staff3","CHANGE-STAFF-3","员工 3","TRUE",1]
    ]);
  }

  if(rw.getLastRow()<2){
    rw.getRange(2,1,4,6).setValues([
      ["R5","断片指南系列 · 任一杯",5,0.5,"TRUE",1],
      ["R4","微醺特调系列 · 任一杯",4,2.0,"TRUE",2],
      ["R3","彩虹 Shot × 1",3,12.5,"TRUE",3],
      ["R0","RM5 Voucher",0,85.0,"TRUE",4]
    ]);
  }
  SpreadsheetApp.flush();
  return {ok:true,version:"V15",spreadsheet:ss.getName()};
}

function moonApi_(ss,d){
  d=d||{};
  switch(String(d.subaction||"")){
    case "staffLogin": return moon_staffLogin_(ss,d);
    case "staffCheck": return {ok:moon_staffAuth_(ss,d.staffToken)};
    case "staffCreateGame": return moon_staffCreateGame_(ss,d);
    case "staffRedeemLookup": return moon_staffRedeemLookup_(ss,d);
    case "staffRedeem": return moon_staffRedeem_(ss,d);
    case "gameOpen": return moon_gameOpen_(ss,d);
    case "claim": return moon_claim_(ss,d);
    case "adminLogin": return moon_adminLogin_(ss,d);
    case "adminState": return moon_adminState_(ss,d);
    case "adminSaveConfig": return moon_adminSaveConfig_(ss,d);
    case "adminSaveRewards": return moon_adminSaveRewards_(ss,d);
    case "adminUpdateClaim": return moon_adminUpdateClaim_(ss,d);
    default:return {ok:false,error:"unknown_moon_action",subaction:d.subaction||""};
  }
}

function moon_ensureSheet_(ss,n,h){
  let sh=ss.getSheetByName(n);
  if(!sh)sh=ss.insertSheet(n);
  if(sh.getMaxColumns()<h.length)sh.insertColumnsAfter(sh.getMaxColumns(),h.length-sh.getMaxColumns());
  sh.getRange(1,1,1,h.length).setValues([h]);
  sh.setFrozenRows(1);
  return sh;
}
function moon_defaultConfig_(sh,k,v,n){if(!moon_configRow_(sh,k))sh.appendRow([k,v,n])}
function moon_configRow_(sh,k){
  if(!sh||sh.getLastRow()<2)return null;
  const v=sh.getRange(2,1,sh.getLastRow()-1,3).getValues(),t=String(k).toUpperCase();
  for(let i=0;i<v.length;i++)if(String(v[i][0]).toUpperCase()===t)return{row:i+2,value:v[i][1],note:v[i][2]};
  return null;
}
function moon_config_(ss,k,f){const r=moon_configRow_(ss.getSheetByName(MOON_CONFIG),k);return r?r.value:f}
function moon_setConfig_(ss,k,v){
  const sh=ss.getSheetByName(MOON_CONFIG),r=moon_configRow_(sh,k);
  if(r)sh.getRange(r.row,2).setValue(v);else sh.appendRow([k,v,""]);
}
function moon_enabled_(ss){return String(moon_config_(ss,"ACTIVITY_ENABLED","TRUE")).toUpperCase()==="TRUE"}
function moon_gameTtl_(ss){return Math.max(2,Math.min(60,Number(moon_config_(ss,"GAME_TOKEN_TTL_MINUTES","20"))||20))*60000}
function moon_tokenTtl_(ss){return moon_gameTtl_(ss)}

function moon_rewards_(ss){
  const sh=ss.getSheetByName(MOON_REWARDS);
  if(!sh||sh.getLastRow()<2)return[];
  return sh.getRange(2,1,sh.getLastRow()-1,6).getValues()
    .map(r=>({id:String(r[0]),name:String(r[1]),displayOnes:Number(r[2]),probability:Number(r[3]),enabled:String(r[4]).toUpperCase()==="TRUE",sort:Number(r[5])}))
    .sort((a,b)=>a.sort-b.sort);
}
function moon_cachedRewards_(ss){
  const c=CacheService.getScriptCache(),k="MOON_REWARD_CONFIG_V15",hit=c.get(k);
  if(hit){try{return JSON.parse(hit)}catch(e){}}
  const r=moon_rewards_(ss).filter(x=>x.enabled);
  c.put(k,JSON.stringify(r),300);
  return r;
}
function moon_clearRewardCache_(){CacheService.getScriptCache().remove("MOON_REWARD_CONFIG_V15")}
function moon_preparedResult_(ss){
  const rs=moon_cachedRewards_(ss);
  if(!rs.length)throw new Error("no_enabled_rewards");
  const total=rs.reduce((a,r)=>a+Number(r.probability||0),0);
  if(Math.abs(total-100)>.001)throw new Error("probability_total_must_be_100");
  let x=Math.random()*100,ch=rs[rs.length-1];
  for(const r of rs){x-=Number(r.probability||0);if(x<0){ch=r;break}}
  let ones=ch.id==="R0"?Math.floor(Math.random()*3):Number(ch.displayOnes||0);
  ones=Math.max(0,Math.min(5,ones));
  const dice=[];
  for(let i=0;i<ones;i++)dice.push(1);
  while(dice.length<5)dice.push(2+Math.floor(Math.random()*5));
  for(let i=4;i>0;i--){const j=Math.floor(Math.random()*(i+1));[dice[i],dice[j]]=[dice[j],dice[i]]}
  return{rewardId:ch.id,reward:ch.name,displayOnes:ones,dice};
}

/* STAFF */
function moon_staffAccount_(ss,username){
  const sh=ss.getSheetByName(MOON_STAFF_ACCOUNTS);
  if(!sh||sh.getLastRow()<2)return null;
  const target=String(username||"").trim().toLowerCase();
  const rows=sh.getRange(2,1,sh.getLastRow()-1,5).getValues();
  for(let i=0;i<rows.length;i++){
    if(String(rows[i][0]).trim().toLowerCase()===target){
      return{
        row:i+2,username:String(rows[i][0]).trim(),password:String(rows[i][1]),
        displayName:String(rows[i][2]||rows[i][0]),
        enabled:String(rows[i][3]).trim().toUpperCase()==="TRUE",
        authVersion:Number(rows[i][4])||1
      };
    }
  }
  return null;
}
function moon_staffLogin_(ss,d){
  const a=moon_staffAccount_(ss,d.username);
  if(!a||!a.enabled||String(d.password||"")!==a.password)return{ok:false,error:"wrong_login"};
  const token=Utilities.getUuid(),now=new Date();
  const days=Math.max(1,Math.min(90,Number(moon_config_(ss,"STAFF_LOGIN_DAYS","30"))||30));
  const exp=new Date(now.getTime()+days*86400000);
  ss.getSheetByName(MOON_STAFF).appendRow([token,now,exp,a.username,a.authVersion]);
  moon_cacheStaff_(token,exp,a.username,a.authVersion);
  return{ok:true,staffToken:token,expiresAt:exp.toISOString(),username:a.username,displayName:a.displayName};
}
function moon_cacheStaff_(token,exp,u,v){
  const seconds=Math.max(1,Math.min(21600,Math.floor((exp.getTime()-Date.now())/1000)));
  CacheService.getScriptCache().put("moon_staff_"+token,JSON.stringify({exp:exp.getTime(),u:u,v:Number(v)||1}),seconds);
}
function moon_staffAuth_(ss,t){
  t=String(t||"").trim();if(!t)return false;
  const cache=CacheService.getScriptCache(),hit=cache.get("moon_staff_"+t);
  if(hit){
    try{
      const h=JSON.parse(hit),a=moon_staffAccount_(ss,h.u);
      if(Number(h.exp)>Date.now()&&a&&a.enabled&&a.authVersion===Number(h.v))return a.username;
    }catch(e){}
  }
  const sh=ss.getSheetByName(MOON_STAFF);if(!sh||sh.getLastRow()<2)return false;
  const f=sh.getRange(2,1,sh.getLastRow()-1,1).createTextFinder(t).matchEntireCell(true).findNext();
  if(!f)return false;
  const vals=sh.getRange(f.getRow(),1,1,5).getValues()[0];
  const exp=vals[2] instanceof Date?vals[2].getTime():new Date(vals[2]).getTime();
  const u=String(vals[3]),v=Number(vals[4])||1,a=moon_staffAccount_(ss,u);
  if(!exp||exp<=Date.now()||!a||!a.enabled||a.authVersion!==v)return false;
  moon_cacheStaff_(t,new Date(exp),u,v);
  return a.username;
}
function moon_staffCreateGame_(ss,d){
  if(!moon_staffAuth_(ss,d.staffToken))return{ok:false,error:"staff_auth"};
  if(!moon_enabled_(ss))return{ok:false,error:"activity_closed"};
  const token=Utilities.getUuid(),now=new Date(),exp=new Date(now.getTime()+moon_gameTtl_(ss));
  const result=moon_preparedResult_(ss);
  ss.getSheetByName(MOON_SESSIONS).appendRow([token,now,exp,"","READY",result.rewardId,result.dice.join(",")]);
  return{ok:true,gameToken:token,shortCode:token.replace(/-/g,"").slice(0,8).toUpperCase(),expiresAt:exp.toISOString()};
}

/* GAME */
function moon_session_(sh,t){
  if(!sh||sh.getLastRow()<2)return null;
  const rows=sh.getRange(2,1,sh.getLastRow()-1,SESSION_HEADERS.length).getValues();
  for(let i=0;i<rows.length;i++)if(String(rows[i][0])===String(t||""))return{row:i+2,data:rows[i]};
  return null;
}
function moon_validGame_(ss,t){
  const sh=ss.getSheetByName(MOON_SESSIONS),s=moon_session_(sh,t);
  if(!s)return{ok:false,error:"invalid_game"};
  const status=String(s.data[4]||"").trim().toUpperCase();
  if(s.data[3]||status==="USED")return{ok:false,error:"game_used"};
  if(status==="EXPIRED")return{ok:false,error:"game_expired"};
  if(status!=="READY"&&status!=="UNLOCKED")return{ok:false,error:"invalid_game_status",status:status};
  const raw=s.data[2],exp=raw instanceof Date?raw.getTime():typeof raw==="number"?raw:new Date(raw).getTime();
  if(!exp)return{ok:false,error:"invalid_game_expiry"};
  if(Date.now()>exp){sh.getRange(s.row,5).setValue("EXPIRED");return{ok:false,error:"game_expired"}}
  return{ok:true,sheet:sh,session:s};
}
function moon_gameOpen_(ss,d){
  if(!moon_enabled_(ss))return{ok:false,error:"activity_closed"};
  const c=moon_validGame_(ss,d.gameToken);if(!c.ok)return c;
  const id=String(c.session.data[5]||""),dice=String(c.session.data[6]||"").split(",").map(Number);
  const rw=moon_rewards_(ss).find(x=>x.id===id);
  if(!rw)return{ok:false,error:"reward_not_found"};
  return{ok:true,gameToken:d.gameToken,rollResult:{rewardId:id,reward:rw.name,displayOnes:dice.filter(n=>n===1).length,dice:dice}};
}

/* CLAIM */
function moon_claim_(ss,d){
  const lock=LockService.getScriptLock();lock.waitLock(10000);
  try{
    const c=moon_validGame_(ss,d.gameToken);if(!c.ok)return c;
    const id=String(c.session.data[5]||""),diceText=String(c.session.data[6]||"");
    const rw=moon_rewards_(ss).find(x=>x.id===id);if(!rw)return{ok:false,error:"reward_not_found"};

    const cc=String(d.countryCode||""),digits=String(d.phone||"").replace(/\D/g,""),phone=cc+digits;
    if(!["+60","+65"].includes(cc))return{ok:false,error:"invalid_country"};
    if(cc==="+65"&&!/^\+65\d{8}$/.test(phone))return{ok:false,error:"invalid_phone"};
    if(cc==="+60"&&!/^\+60\d{9,11}$/.test(phone))return{ok:false,error:"invalid_phone"};

    const sh=ss.getSheetByName(MOON_CLAIMS),code=moon_recoveryCode_(sh),now=new Date();
    const dice=diceText.split(",").map(Number);
    sh.appendRow([
      code,now,cc==="+65"?"SG":"MY",phone,diceText,dice.filter(n=>n===1).length,
      rw.id,rw.name,d.communityOptIn?"YES":"NO","PENDING","","NO",""
    ]);
    c.sheet.getRange(c.session.row,4).setValue(now);
    c.sheet.getRange(c.session.row,5).setValue("USED");
    SpreadsheetApp.flush();
    return{
      ok:true,recoveryCode:code,reward:rw.name,whatsapp:phone,status:"PENDING",
      sendWithinBusinessDays:Number(moon_config_(ss,"WHATSAPP_SEND_DAYS","3"))||3
    };
  }finally{lock.releaseLock()}
}
function moon_recoveryCode_(sh){
  for(let i=0;i<30;i++){
    const code="YT-MOON-"+Utilities.getUuid().replace(/-/g,"").slice(0,8).toUpperCase();
    if(sh.getLastRow()<2)return code;
    const f=sh.getRange(2,1,sh.getLastRow()-1,1).createTextFinder(code).matchEntireCell(true).findNext();
    if(!f)return code;
  }
  throw new Error("recovery_code_generation_failed");
}

/* REDEEM — V15: full code or final 8 chars */
function moon_normalizeRecoveryCode_(value){
  let q=String(value==null?"":value).trim().toUpperCase();
  q=q.replace(/^YT[\s\-_]*MOON[\s\-_]*/,"");
  return q.replace(/[^A-Z0-9]/g,"");
}
function moon_claimByCode_(ss,code){
  const sh=ss.getSheetByName(MOON_CLAIMS);
  if(!sh||sh.getLastRow()<2)return null;

  const q=moon_normalizeRecoveryCode_(code);
  if(!q)return null;

  const codes=sh.getRange(2,1,sh.getLastRow()-1,1).getDisplayValues();
  const matches=[];
  for(let i=0;i<codes.length;i++){
    const normalized=moon_normalizeRecoveryCode_(codes[i][0]);
    if(normalized&&normalized===q)matches.push(i+2);
  }
  if(!matches.length)return null;
  if(matches.length>1)return{ambiguous:true,count:matches.length};

  const row=matches[0],r=sh.getRange(row,1,1,CLAIM_HEADERS.length).getValues()[0];
  return{
    row:row,code:String(r[0]||""),created:r[1],phone:r[3],dice:r[4],ones:r[5],
    rewardId:r[6],reward:r[7],status:r[9],sentAt:r[10],
    redeemed:String(r[11]||"").trim().toUpperCase()==="YES",redeemedAt:r[12],redeemRef:r[13]||"",redeemedBy:r[14]||""
  };
}
function moon_staffRedeemLookup_(ss,d){
  if(!moon_staffAuth_(ss,d.staffToken))return{ok:false,error:"staff_auth"};
  const c=moon_claimByCode_(ss,d.code);
  if(!c)return{ok:false,error:"code_not_found"};
  if(c.ambiguous)return{ok:false,error:"code_ambiguous",count:c.count};
  return{ok:true,claim:c};
}
function moon_newRedeemRef_(sh){
  // Example: RD-250925-7K4M2P — short enough to read back, unique enough for daily ops.
  const tz=Session.getScriptTimeZone()||"Asia/Kuala_Lumpur";
  const day=Utilities.formatDate(new Date(),tz,"yyMMdd");
  for(let i=0;i<30;i++){
    const tail=Utilities.getUuid().replace(/-/g,"").slice(0,6).toUpperCase();
    const ref="RD-"+day+"-"+tail;
    if(sh.getLastRow()<2)return ref;
    const vals=sh.getRange(2,14,sh.getLastRow()-1,1).getDisplayValues().flat();
    if(!vals.includes(ref))return ref;
  }
  throw new Error("redeem_ref_generation_failed");
}
function moon_staffRedeem_(ss,d){
  const staffUser=moon_staffAuth_(ss,d.staffToken);
  if(!staffUser)return{ok:false,error:"staff_auth"};
  const lock=LockService.getScriptLock();lock.waitLock(7000);
  try{
    const c=moon_claimByCode_(ss,d.code);
    if(!c)return{ok:false,error:"code_not_found"};
    if(c.ambiguous)return{ok:false,error:"code_ambiguous",count:c.count};
    if(c.redeemed)return{ok:false,error:"already_redeemed",claim:c};

    const sh=ss.getSheetByName(MOON_CLAIMS),now=new Date();
    const ref=moon_newRedeemRef_(sh);

    sh.getRange(c.row,12).setValue("YES");
    sh.getRange(c.row,13).setValue(now);
    sh.getRange(c.row,14).setValue(ref);
    sh.getRange(c.row,15).setValue(staffUser);
    SpreadsheetApp.flush();

    return{
      ok:true,
      reward:c.reward,
      code:c.code,
      redeemedAt:now.toISOString(),
      redeemRef:ref,
      redeemedBy:staffUser
    };
  }finally{lock.releaseLock()}
}

/* ADMIN */
function moon_adminLogin_(ss,d){
  if(String(d.password||"")!==String(moon_config_(ss,"ADMIN_PASSWORD","")))return{ok:false,error:"wrong_admin_password"};
  const t=Utilities.getUuid();
  CacheService.getScriptCache().put("moon_admin_"+t,"1",21600);
  return{ok:true,adminToken:t};
}
function moon_adminAuth_(d){return!!CacheService.getScriptCache().get("moon_admin_"+String(d.adminToken||""))}
function moon_adminState_(ss,d){
  if(!moon_adminAuth_(d))return{ok:false,error:"admin_auth"};
  const claims=[],sh=ss.getSheetByName(MOON_CLAIMS);
  if(sh&&sh.getLastRow()>=2){
    const n=Math.min(100,sh.getLastRow()-1),start=sh.getLastRow()-n+1;
    const rows=sh.getRange(start,1,n,CLAIM_HEADERS.length).getValues().reverse();
    rows.forEach(r=>claims.push({
      code:r[0],created:r[1],country:r[2],phone:r[3],dice:r[4],ones:r[5],
      rewardId:r[6],reward:r[7],community:r[8],status:r[9],sentAt:r[10],
      redeemed:r[11],redeemedAt:r[12],redeemRef:r[13]||"",redeemedBy:r[14]||""
    }));
  }
  return{
    ok:true,
    config:{
      activityEnabled:moon_enabled_(ss),
      gameTtl:Number(moon_config_(ss,"GAME_TOKEN_TTL_MINUTES","20")),
      staffDays:Number(moon_config_(ss,"STAFF_LOGIN_DAYS","30")),
      sendDays:Number(moon_config_(ss,"WHATSAPP_SEND_DAYS","3"))
    },
    rewards:moon_rewards_(ss),
    claims:claims
  };
}
function moon_adminSaveConfig_(ss,d){
  if(!moon_adminAuth_(d))return{ok:false,error:"admin_auth"};
  if(typeof d.activityEnabled!=="undefined")moon_setConfig_(ss,"ACTIVITY_ENABLED",d.activityEnabled?"TRUE":"FALSE");
  if(String(d.adminPassword||"").trim())moon_setConfig_(ss,"ADMIN_PASSWORD",String(d.adminPassword).trim());
  if(d.gameTtl!==undefined)moon_setConfig_(ss,"GAME_TOKEN_TTL_MINUTES",String(Math.max(2,Math.min(60,Number(d.gameTtl)||20))));
  if(d.staffDays!==undefined)moon_setConfig_(ss,"STAFF_LOGIN_DAYS",String(Math.max(1,Math.min(90,Number(d.staffDays)||30))));
  if(d.sendDays!==undefined)moon_setConfig_(ss,"WHATSAPP_SEND_DAYS",String(Math.max(1,Math.min(30,Number(d.sendDays)||3))));
  SpreadsheetApp.flush();
  return{ok:true};
}
function moon_adminSaveRewards_(ss,d){
  if(!moon_adminAuth_(d))return{ok:false,error:"admin_auth"};
  const rows=Array.isArray(d.rewards)?d.rewards:[];
  if(!rows.length)return{ok:false,error:"no_rewards"};
  const a=rows.map((r,i)=>({
    id:String(r.id||"").trim(),name:String(r.name||"").trim(),
    displayOnes:Math.max(0,Math.min(5,Number(r.displayOnes)||0)),
    probability:Number(r.probability)||0,enabled:!!r.enabled,sort:i+1
  }));
  if(a.some(r=>!r.id||!r.name))return{ok:false,error:"invalid_reward"};
  const total=a.filter(r=>r.enabled).reduce((sum,r)=>sum+r.probability,0);
  if(Math.abs(total-100)>.001)return{ok:false,error:"probability_total",total:total};
  const sh=ss.getSheetByName(MOON_REWARDS);
  if(sh.getLastRow()>1)sh.getRange(2,1,sh.getLastRow()-1,6).clearContent();
  sh.getRange(2,1,a.length,6).setValues(a.map(r=>[r.id,r.name,r.displayOnes,r.probability,r.enabled?"TRUE":"FALSE",r.sort]));
  SpreadsheetApp.flush();moon_clearRewardCache_();
  return{ok:true};
}
function moon_adminUpdateClaim_(ss,d){
  if(!moon_adminAuth_(d))return{ok:false,error:"admin_auth"};
  const c=moon_claimByCode_(ss,d.code);
  if(!c)return{ok:false,error:"not_found"};
  if(c.ambiguous)return{ok:false,error:"code_ambiguous",count:c.count};
  const sh=ss.getSheetByName(MOON_CLAIMS),now=new Date();
  if(d.status==="SENT"){sh.getRange(c.row,10).setValue("SENT");sh.getRange(c.row,11).setValue(now)}
  if(d.status==="PENDING"){sh.getRange(c.row,10).setValue("PENDING");sh.getRange(c.row,11).setValue("")}
  if(d.status==="REDEEMED"){
    if(c.redeemed)return{ok:false,error:"already_redeemed"};
    sh.getRange(c.row,12).setValue("YES");sh.getRange(c.row,13).setValue(now);
  }
  SpreadsheetApp.flush();
  return{ok:true};
}
