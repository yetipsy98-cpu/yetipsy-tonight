/*
YETIPSY TONIGHT V2 — Google Apps Script backend
Create a blank Google Sheet, paste its ID below, deploy as Web App:
Execute as: Me
Who has access: Anyone
*/
const SHEET_ID="PASTE_GOOGLE_SHEET_ID_HERE";
const TABS=["PLAYERS","MATCHES"];

function doGet(){return json_({ok:true,service:"YETIPSY Tonight V2"});}
function doPost(e){
 try{
  const d=JSON.parse((e.postData&&e.postData.contents)||"{}");
  const ss=SpreadsheetApp.openById(SHEET_ID); setup_(ss);
  if(d.action==="join")return join_(ss,d);
  if(d.action==="heartbeat")return heartbeat_(ss,d);
  if(d.action==="status")return status_(ss,d);
  if(d.action==="queue")return queue_(ss,d);
  if(d.action==="matchStatus")return matchStatus_(ss,d);
  if(d.action==="verify")return verify_(ss,d);
  if(d.action==="complete")return complete_(ss,d);
  return json_({ok:false,error:"unknown_action"});
 }catch(err){return json_({ok:false,error:String(err)});}
}
function setup_(ss){
 let p=ss.getSheetByName("PLAYERS")||ss.insertSheet("PLAYERS");
 if(p.getLastRow()===0)p.appendRow(["device_id","nick","table_id","mode","status","joined_at","last_seen","current_match","history"]);
 let m=ss.getSheetByName("MATCHES")||ss.insertSheet("MATCHES");
 if(m.getLastRow()===0)m.appendRow(["match_id","a_device","b_device","a_code","b_code","a_verified","b_verified","status","created_at","completed_at"]);
}
function clean_(s,n){return String(s||"").replace(/[<>]/g,"").trim().slice(0,n);}
function playerRow_(sh,id){
 const v=sh.getDataRange().getValues();
 for(let i=1;i<v.length;i++)if(String(v[i][0])===String(id))return {row:i+1,data:v[i]};
 return null;
}
function join_(ss,d){
 const sh=ss.getSheetByName("PLAYERS"),now=new Date(),x=playerRow_(sh,d.deviceId);
 if(x)sh.getRange(x.row,2,1,6).setValues([[clean_(d.nick,18),clean_(d.table,12),clean_(d.mode,12),"active",x.data[5]||now,now]]);
 else sh.appendRow([clean_(d.deviceId,80),clean_(d.nick,18),clean_(d.table,12),clean_(d.mode,12),"active",now,now,"",""]);
 return json_({ok:true});
}
function heartbeat_(ss,d){
 const sh=ss.getSheetByName("PLAYERS"),x=playerRow_(sh,d.deviceId);
 if(x)sh.getRange(x.row,7).setValue(new Date());
 return json_({ok:true});
}
function status_(ss,d){return matchStatus_(ss,d);}
function queue_(ss,d){
 const lock=LockService.getScriptLock();lock.waitLock(8000);
 try{
  const p=ss.getSheetByName("PLAYERS"),me=playerRow_(p,d.deviceId);
  if(!me)return json_({ok:false,error:"not_joined"});
  if(me.data[7])return matchStatus_(ss,d);
  p.getRange(me.row,5).setValue("queued");
  const vals=p.getDataRange().getValues(),cut=Date.now()-12*60*1000;
  const myTable=String(me.data[2]),history=String(me.data[8]||"").split(",").filter(Boolean);
  let candidates=[];
  for(let i=1;i<vals.length;i++){
    const r=vals[i],id=String(r[0]);
    if(id===String(d.deviceId))continue;
    if(String(r[2])===myTable)continue;
    if(history.includes(id))continue;
    if(String(r[4])!=="queued")continue;
    if(new Date(r[6]).getTime()<cut)continue;
    if(r[7])continue;
    candidates.push({row:i+1,data:r});
  }
  if(!candidates.length)return json_({ok:true,waiting:true});
  // Randomize candidate so people at one table don't all converge on the first person.
  const other=candidates[Math.floor(Math.random()*candidates.length)];
  const id=Utilities.getUuid(),aCode=String(Math.floor(1000+Math.random()*9000)),bCode=String(Math.floor(1000+Math.random()*9000));
  ss.getSheetByName("MATCHES").appendRow([id,d.deviceId,other.data[0],aCode,bCode,false,false,"active",new Date(),""]);
  p.getRange(me.row,5).setValue("matched");p.getRange(me.row,8).setValue(id);
  p.getRange(other.row,5).setValue("matched");p.getRange(other.row,8).setValue(id);
  return matchStatus_(ss,d);
 }finally{lock.releaseLock();}
}
function matchStatus_(ss,d){
 const p=ss.getSheetByName("PLAYERS"),me=playerRow_(p,d.deviceId);
 if(!me||!me.data[7])return json_({ok:true,match:null,waiting:me&&me.data[4]==="queued"});
 const matchId=String(me.data[7]),mv=ss.getSheetByName("MATCHES").getDataRange().getValues();
 for(let i=1;i<mv.length;i++)if(String(mv[i][0])===matchId){
  const r=mv[i],isA=String(r[1])===String(d.deviceId),partnerId=isA?r[2]:r[1],partner=playerRow_(p,partnerId);
  return json_({ok:true,match:{matchId,partnerNick:partner?partner.data[1]:"PLAYER",partnerTable:partner?partner.data[2]:"?",myCode:isA?r[3]:r[4],verified:isA?r[5]:r[6]}});
 }
 return json_({ok:true,match:null});
}
function verify_(ss,d){
 const m=ss.getSheetByName("MATCHES"),mv=m.getDataRange().getValues(),p=ss.getSheetByName("PLAYERS");
 for(let i=1;i<mv.length;i++)if(String(mv[i][0])===String(d.matchId)){
  const r=mv[i],isA=String(r[1])===String(d.deviceId);
  if(!isA&&String(r[2])!==String(d.deviceId))return json_({ok:false,error:"not_member"});
  const expected=String(isA?r[4]:r[3]); // enter partner's displayed code
  if(String(d.partnerCode)!==expected)return json_({ok:false,verified:false});
  m.getRange(i+1,isA?6:7).setValue(true);
  SpreadsheetApp.flush();
  const updated=m.getRange(i+1,1,1,10).getValues()[0];
  const both=updated[5]===true&&updated[6]===true;
  if(both){
   m.getRange(i+1,8).setValue("verified");m.getRange(i+1,10).setValue(new Date());
   finishPlayer_(p,updated[1],updated[2]);finishPlayer_(p,updated[2],updated[1]);
  }
  return json_({ok:true,verified:true,bothVerified:both});
 }
 return json_({ok:false,error:"match_not_found"});
}
function finishPlayer_(p,id,partnerId){
 const x=playerRow_(p,id);if(!x)return;
 let history=String(x.data[8]||"").split(",").filter(Boolean);
 if(!history.includes(String(partnerId)))history.push(String(partnerId));
 p.getRange(x.row,5).setValue("active");
 p.getRange(x.row,8).setValue("");
 p.getRange(x.row,9).setValue(history.join(","));
}
function complete_(ss,d){return json_({ok:true});}
function json_(o){return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);}
