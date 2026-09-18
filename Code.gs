const SHEET_ID = 'PASTE_GOOGLE_SHEET_ID_HERE';
const ADMIN_KEY = 'CHANGE_THIS_TO_A_LONG_RANDOM_SECRET';
const TABS = ['SESSIONS','WALL','EVENTS'];

function doGet(){ return json_({ok:true,service:'YETIPSY Tonight API'}); }
function doPost(e){
  try{
    const d=JSON.parse(e.postData.contents||'{}');
    const ss=SpreadsheetApp.openById(SHEET_ID); setup_(ss);
    if(d.action==='join') return join_(ss,d);
    if(d.action==='heartbeat') return heartbeat_(ss,d);
    if(d.action==='status') return status_(ss);
    if(d.action==='wall') return wall_(ss);
    if(d.action==='postWall') return postWall_(ss,d);
    if(d.action==='event') return event_(ss);
    if(d.action==='adminEvent') return adminEvent_(ss,d);
    if(d.action==='moderate') return moderate_(ss,d);
    return json_({ok:false,error:'unknown_action'});
  }catch(err){ return json_({ok:false,error:String(err)}); }
}
function setup_(ss){
  TABS.forEach(n=>{if(!ss.getSheetByName(n)) ss.insertSheet(n)});
  const s=ss.getSheetByName('SESSIONS'); if(s.getLastRow()===0)s.appendRow(['session','mode','joined_at','last_seen']);
  const w=ss.getSheetByName('WALL'); if(w.getLastRow()===0)w.appendRow(['id','created_at','session','message','status']);
  const ev=ss.getSheetByName('EVENTS'); if(ev.getLastRow()===0)ev.appendRow(['id','title','body','starts_at','ends_at','active']);
}
function join_(ss,d){
  const sh=ss.getSheetByName('SESSIONS'), now=new Date(), vals=sh.getDataRange().getValues(); let row=0;
  for(let i=1;i<vals.length;i++) if(vals[i][0]===d.session){row=i+1;break}
  if(row) sh.getRange(row,2,1,3).setValues([[clean_(d.mode,20),now,now]]); else sh.appendRow([clean_(d.session,80),clean_(d.mode,20),now,now]);
  return status_(ss);
}
function heartbeat_(ss,d){const sh=ss.getSheetByName('SESSIONS'),v=sh.getDataRange().getValues();for(let i=1;i<v.length;i++)if(v[i][0]===d.session){sh.getRange(i+1,4).setValue(new Date());break}return status_(ss)}
function status_(ss){const v=ss.getSheetByName('SESSIONS').getDataRange().getValues(),cut=Date.now()-30*60*1000;let online=0,modes={chill:0,open:0,surprise:0};for(let i=1;i<v.length;i++){let t=new Date(v[i][3]).getTime();if(t>=cut){online++;if(modes[v[i][1]]!==undefined)modes[v[i][1]]++}}return json_({ok:true,online,modes});}
function wall_(ss){const v=ss.getSheetByName('WALL').getDataRange().getValues(),out=[];for(let i=v.length-1;i>=1&&out.length<20;i--)if(v[i][4]==='approved')out.push({id:v[i][0],message:v[i][3],created_at:v[i][1]});return json_({ok:true,items:out});}
function postWall_(ss,d){let m=clean_(d.message,120);if(!m)return json_({ok:false,error:'empty'});ss.getSheetByName('WALL').appendRow([Utilities.getUuid(),new Date(),clean_(d.session,80),m,'pending']);return json_({ok:true,pending:true});}
function event_(ss){const v=ss.getSheetByName('EVENTS').getDataRange().getValues(),now=Date.now();for(let i=v.length-1;i>=1;i--){let active=String(v[i][5]).toLowerCase()==='true'||v[i][5]===true,start=new Date(v[i][3]).getTime(),end=new Date(v[i][4]).getTime();if(active&&(!start||start<=now)&&(!end||end>=now))return json_({ok:true,event:{id:v[i][0],title:v[i][1],body:v[i][2],starts_at:v[i][3],ends_at:v[i][4]}})}return json_({ok:true,event:null});}
function adminEvent_(ss,d){if(d.key!==ADMIN_KEY)return json_({ok:false,error:'forbidden'});ss.getSheetByName('EVENTS').appendRow([Utilities.getUuid(),clean_(d.title,60),clean_(d.body,240),new Date(d.starts_at||Date.now()),new Date(d.ends_at||Date.now()+600000),true]);return json_({ok:true});}
function moderate_(ss,d){if(d.key!==ADMIN_KEY)return json_({ok:false,error:'forbidden'});const sh=ss.getSheetByName('WALL'),v=sh.getDataRange().getValues();for(let i=1;i<v.length;i++)if(v[i][0]===d.id){sh.getRange(i+1,5).setValue(d.status==='approved'?'approved':'rejected');return json_({ok:true})}return json_({ok:false,error:'not_found'});}
function clean_(s,n){return String(s||'').replace(/[<>]/g,'').trim().slice(0,n)}
function json_(o){return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON)}
