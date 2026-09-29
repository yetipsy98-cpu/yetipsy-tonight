const SHEETS={USERS:'Users',PASSES:'QR_Passes',CHECKINS:'Checkins',REDEEMS:'Redeem_Log',WALLET:'Wallet',PAYOUTS:'Payouts',PRICING:'Daily_Pricing',SETTINGS:'Settings',SESSIONS:'Sessions',AUDIT:'Audit_Log'};
const TZ='Asia/Kuala_Lumpur';

function doPost(e){
  try{
    const p=e.parameter||{}, action=p.action;
    if(!action) throw new Error('Missing action');
    const publicActions=['login'];
    let user=null;
    if(!publicActions.includes(action)) user=requireSession_(p.session_token);
    const map={
      login:()=>login_(p), ambassadorDashboard:()=>ambassadorDashboard_(user), createPass:()=>createPass_(user,p),
      updatePass:()=>updatePass_(user,p), lookupPass:()=>lookupPass_(user,p), partialRedeem:()=>partialRedeem_(user,p),
      staffRecent:()=>staffRecent_(user), adminDashboard:()=>adminDashboard_(user),
      createAmbassador:()=>createAmbassador_(user,p), savePricingDefaults:()=>savePricingDefaults_(user,p),
      getPricingDefaults:()=>getPricingDefaults_(user), saveDateOverride:()=>saveDateOverride_(user,p),
      listDateOverrides:()=>listDateOverrides_(user), deleteDateOverride:()=>deleteDateOverride_(user,p),
      createPayout:()=>createPayout_(user,p), payoutHistory:()=>payoutHistory_(user,p),
      listManagedUsers:()=>listManagedUsers_(user), resetUserPassword:()=>resetUserPassword_(user,p),
      changeOwnPassword:()=>changeOwnPassword_(user,p)
    };
    if(!map[action]) throw new Error('Unknown action');
    return json_({ok:true,data:map[action]()});
  }catch(err){ return json_({ok:false,error:String(err.message||err)}) }
}
function json_(o){return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON)}
function ss_(){return SpreadsheetApp.getActive()}
function sh_(name){const s=ss_().getSheetByName(name);if(!s)throw new Error('Missing sheet '+name+'. Run setupSheets() first.');return s}
function rows_(name){const s=sh_(name),v=s.getDataRange().getValues();if(v.length<2)return[];const h=v[0];return v.slice(1).filter(r=>r.some(x=>x!=='' )).map(r=>Object.fromEntries(h.map((k,j)=>[k,r[j]])))}
function append_(name,obj){const s=sh_(name),h=s.getRange(1,1,1,s.getLastColumn()).getValues()[0];s.appendRow(h.map(k=>obj[k]??''))}
function updateById_(name,idField,idValue,patch){const s=sh_(name),v=s.getDataRange().getValues(),h=v[0],idx=h.indexOf(idField);for(let i=1;i<v.length;i++){if(String(v[i][idx])===String(idValue)){Object.entries(patch).forEach(([k,val])=>{const c=h.indexOf(k);if(c>=0)s.getRange(i+1,c+1).setValue(val)});return true}}return false}
function uuid_(prefix){return prefix+'-'+Utilities.getUuid().replace(/-/g,'').slice(0,10).toUpperCase()}
function now_(){return new Date()}
function hash_(s){return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,String(s),Utilities.Charset.UTF_8).map(b=>(b+256)%256).map(b=>b.toString(16).padStart(2,'0')).join('')}
function dateKey_(x){if(!x)return'';if(Object.prototype.toString.call(x)==='[object Date]')return Utilities.formatDate(x,TZ,'yyyy-MM-dd');return String(x).slice(0,10)}
function num_(x){const n=Number(x);return Number.isFinite(n)?n:0}
function requireRole_(u,roles){if(!roles.includes(String(u.role)))throw new Error('Permission denied')}
function audit_(u,action,entity,entity_id,detail){append_(SHEETS.AUDIT,{audit_id:uuid_('AUD'),user_id:u.user_id,action,entity,entity_id,detail,created_at:now_()})}
function getSetting_(k,def=''){const r=rows_(SHEETS.SETTINGS).find(x=>String(x.setting_key)===String(k));return r?String(r.setting_value):def}
function setSetting_(k,v,userId){const cur=rows_(SHEETS.SETTINGS).find(x=>String(x.setting_key)===String(k));if(cur)updateById_(SHEETS.SETTINGS,'setting_key',k,{setting_value:v,updated_by:userId,updated_at:now_()});else append_(SHEETS.SETTINGS,{setting_key:k,setting_value:v,updated_by:userId,updated_at:now_()})}
function dayType_(dateStr){const d=new Date(dateStr+'T00:00:00');const day=d.getDay();return(day===5||day===6)?'WEEKEND':'NORMAL'}

function setupSheets(){
  const defs={
    Users:['user_id','role','name','username','password_hash','commission_rate','status','created_at'],
    QR_Passes:['pass_id','pass_ref','qr_token','ambassador_id','type','label','reservation_date','planned_pax','remark','status','actual_pax','actual_male','actual_female','sales','created_at','updated_at','closed_at'],
    Checkins:['checkin_ref','pass_id','ambassador_id','staff_id','pax','male','female','table_no','remark','created_at'],
    Redeem_Log:['redeem_ref','pass_id','pass_ref','ambassador_id','staff_id','reservation_date','table_no','male_charged','female_charged','male_price','female_price','sales_amount','commission_rate','commission_amount','final_payment','created_at','status'],
    Wallet:['wallet_txn_id','ambassador_id','redeem_ref','type','amount','created_at'],
    Payouts:['payout_ref','ambassador_id','amount','method','note','paid_by','created_at'],
    Daily_Pricing:['price_id','price_date','male_price','female_price','note','status','updated_by','updated_at'],
    Settings:['setting_key','setting_value','updated_by','updated_at'],
    Sessions:['session_token','user_id','role','created_at','expires_at'],
    Audit_Log:['audit_id','user_id','action','entity','entity_id','detail','created_at']
  };
  Object.entries(defs).forEach(([n,h])=>{let s=ss_().getSheetByName(n);if(!s)s=ss_().insertSheet(n);if(s.getLastRow()===0){s.appendRow(h)}else{const old=s.getRange(1,1,1,s.getLastColumn()).getValues()[0];h.forEach(col=>{if(!old.includes(col)){s.getRange(1,s.getLastColumn()+1).setValue(col);old.push(col)}})}});
  const defaults={normal_male_price:'20',normal_female_price:'20',weekend_male_price:'25',weekend_female_price:'25'};
  Object.entries(defaults).forEach(([k,v])=>{if(getSetting_(k,'')==='')setSetting_(k,v,'system')});
}
function seedDemoUsers(){setupSheets();const users=rows_(SHEETS.USERS);if(!users.find(x=>String(x.username)==='owner'))append_(SHEETS.USERS,{user_id:uuid_('ADM'),role:'admin',name:'Owner',username:'owner',password_hash:hash_('ChangeMe123!'),commission_rate:'',status:'ACTIVE',created_at:now_()});if(!users.find(x=>String(x.username)==='staff1'))append_(SHEETS.USERS,{user_id:uuid_('STF'),role:'staff',name:'Staff 1',username:'staff1',password_hash:hash_('ChangeMe123!'),commission_rate:'',status:'ACTIVE',created_at:now_()})}

function login_(p){
  const role=String(p.role||'').toLowerCase();
  const username=String(p.username||'').trim();
  const matches=rows_(SHEETS.USERS).filter(x=>String(x.username).trim()===username&&String(x.role).toLowerCase()===role&&String(x.status||'ACTIVE')==='ACTIVE');
  if(matches.length>1)throw new Error('Duplicate username detected. Owner must remove duplicate account rows first.');
  const u=matches[0];
  if(!u||String(u.password_hash)!==hash_(p.password||''))throw new Error('Invalid login');
  const token=uuid_('SES');
  append_(SHEETS.SESSIONS,{session_token:token,user_id:u.user_id,role:u.role,created_at:now_(),expires_at:new Date(Date.now()+1000*60*60*24*7)});
  return{token,role:u.role,name:u.name,username:u.username,user_id:u.user_id};
}
function requireSession_(token){const s=rows_(SHEETS.SESSIONS).find(x=>String(x.session_token)===String(token));if(!s||new Date(s.expires_at)<new Date())throw new Error('Session expired');const u=rows_(SHEETS.USERS).find(x=>String(x.user_id)===String(s.user_id)&&String(x.status||'ACTIVE')==='ACTIVE');if(!u)throw new Error('User not found');return u}
function createAmbassador_(u,p){requireRole_(u,['admin']);if(!p.name||!p.username||!p.password)throw new Error('Missing fields');if(rows_(SHEETS.USERS).some(x=>String(x.username)===String(p.username)))throw new Error('Username exists');const rate=num_(p.commission_rate);if(rate<0||rate>100)throw new Error('Invalid commission rate');append_(SHEETS.USERS,{user_id:uuid_('AMB'),role:'ambassador',name:p.name,username:p.username,password_hash:hash_(p.password),commission_rate:rate,status:'ACTIVE',created_at:now_()});audit_(u,'CREATE_AMBASSADOR','user',p.username,p.name);return true}

function listManagedUsers_(u){
  requireRole_(u,['admin']);
  return rows_(SHEETS.USERS).filter(x=>['admin','staff','ambassador'].includes(String(x.role))).map(x=>({user_id:x.user_id,role:x.role,name:x.name,username:x.username,status:x.status||'ACTIVE',commission_rate:num_(x.commission_rate)}));
}
function deleteSessionsForUser_(userId){
  const s=sh_(SHEETS.SESSIONS),v=s.getDataRange().getValues();
  if(v.length<2)return;
  const h=v[0],idx=h.indexOf('user_id');
  for(let i=v.length-1;i>=1;i--){
    if(String(v[i][idx])===String(userId))s.deleteRow(i+1);
  }
}
function writePasswordAndVerify_(userId,newPassword){
  const newHash=hash_(newPassword);
  const ok=updateById_(SHEETS.USERS,'user_id',userId,{password_hash:newHash});
  if(!ok)throw new Error('Password update failed: user row not found');
  SpreadsheetApp.flush();
  const fresh=rows_(SHEETS.USERS).find(x=>String(x.user_id)===String(userId));
  if(!fresh||String(fresh.password_hash)!==newHash)throw new Error('Password update verification failed');
  return true;
}
function resetUserPassword_(u,p){
  requireRole_(u,['admin']);
  const target=rows_(SHEETS.USERS).find(x=>String(x.user_id)===String(p.user_id));
  if(!target)throw new Error('User not found');
  const np=String(p.new_password||'');
  if(np.length<8)throw new Error('新密码至少 8 个字符');
  writePasswordAndVerify_(target.user_id,np);
  deleteSessionsForUser_(target.user_id);
  audit_(u,'RESET_PASSWORD','user',target.user_id,`${target.role}/${target.username}`);
  return{success:true,username:target.username};
}
function changeOwnPassword_(u,p){
  const current=String(p.current_password||''),np=String(p.new_password||'');
  const fresh=rows_(SHEETS.USERS).find(x=>String(x.user_id)===String(u.user_id));
  if(!fresh)throw new Error('User not found');
  if(String(fresh.password_hash)!==hash_(current))throw new Error('Current password incorrect');
  if(np.length<8)throw new Error('新密码至少 8 个字符');
  if(hash_(np)===String(fresh.password_hash))throw new Error('新密码不能和当前密码相同');
  writePasswordAndVerify_(u.user_id,np);
  audit_(u,'CHANGE_OWN_PASSWORD','user',u.user_id,u.username);
  deleteSessionsForUser_(u.user_id);
  return{success:true,force_logout:true};
}
function createPayout_(u,p){
  requireRole_(u,['admin']);
  const amb=rows_(SHEETS.USERS).find(x=>String(x.user_id)===String(p.ambassador_id)&&String(x.role)==='ambassador');
  if(!amb)throw new Error('Ambassador not found');
  const amount=Math.round(num_(p.amount)*100)/100;
  if(!(amount>0))throw new Error('请输入实际付款金额');
  const walletRows=rows_(SHEETS.WALLET).filter(x=>String(x.ambassador_id)===String(amb.user_id));
  const available=Math.round(walletRows.reduce((s,w)=>s+num_(w.amount),0)*100)/100;
  if(amount>available+0.001)throw new Error('付款金额不能超过可用佣金 '+available.toFixed(2));
  const ref='YT-PAY-'+Utilities.formatDate(now_(),TZ,'yyMMdd')+'-'+Utilities.getUuid().replace(/-/g,'').slice(0,5).toUpperCase();
  append_(SHEETS.PAYOUTS,{payout_ref:ref,ambassador_id:amb.user_id,amount,method:p.method||'',note:p.note||'',paid_by:u.user_id,created_at:now_()});
  append_(SHEETS.WALLET,{wallet_txn_id:uuid_('WLT'),ambassador_id:amb.user_id,redeem_ref:ref,type:'PAYOUT',amount:-amount,created_at:now_()});
  audit_(u,'AMBASSADOR_PAYOUT','ambassador',amb.user_id,`${amount}; ${p.method||''}; ${p.note||''}`);
  return{payout_ref:ref,amount,balance:Math.round((available-amount)*100)/100};
}
function payoutHistory_(u,p){
  requireRole_(u,['admin']);
  let list=rows_(SHEETS.PAYOUTS);
  if(p&&p.ambassador_id)list=list.filter(x=>String(x.ambassador_id)===String(p.ambassador_id));
  const users=rows_(SHEETS.USERS);
  return list.sort((a,b)=>new Date(b.created_at)-new Date(a.created_at)).slice(0,100).map(x=>({...x,ambassador_name:users.find(y=>String(y.user_id)===String(x.ambassador_id))?.name||x.ambassador_id}));
}

function savePricingDefaults_(u,p){requireRole_(u,['admin']);const vals={normal_male_price:num_(p.normal_male_price),normal_female_price:num_(p.normal_female_price),weekend_male_price:num_(p.weekend_male_price),weekend_female_price:num_(p.weekend_female_price)};Object.entries(vals).forEach(([k,v])=>{if(v<0)throw new Error('Invalid price');setSetting_(k,String(v),u.user_id)});audit_(u,'SAVE_DEFAULT_PRICING','settings','pricing',JSON.stringify(vals));return true}
function getPricingDefaults_(u){requireRole_(u,['admin']);return{normal_male_price:num_(getSetting_('normal_male_price','0')),normal_female_price:num_(getSetting_('normal_female_price','0')),weekend_male_price:num_(getSetting_('weekend_male_price','0')),weekend_female_price:num_(getSetting_('weekend_female_price','0'))}}
function saveDateOverride_(u,p){requireRole_(u,['admin']);const d=dateKey_(p.price_date),male=num_(p.male_price),female=num_(p.female_price);if(!/^\d{4}-\d{2}-\d{2}$/.test(d))throw new Error('请选择日期');if(male<0||female<0)throw new Error('Invalid price');const existing=rows_(SHEETS.PRICING).find(x=>dateKey_(x.price_date)===d&&String(x.status||'ACTIVE')==='ACTIVE');if(existing)updateById_(SHEETS.PRICING,'price_id',existing.price_id,{price_date:d,male_price:male,female_price:female,note:p.note||'',status:'ACTIVE',updated_by:u.user_id,updated_at:now_()});else append_(SHEETS.PRICING,{price_id:uuid_('PRICE'),price_date:d,male_price:male,female_price:female,note:p.note||'',status:'ACTIVE',updated_by:u.user_id,updated_at:now_()});audit_(u,'SAVE_DATE_OVERRIDE','pricing',d,`${male}/${female}`);return true}
function listDateOverrides_(u){requireRole_(u,['admin']);return rows_(SHEETS.PRICING).filter(x=>String(x.status||'ACTIVE')==='ACTIVE').map(x=>({...x,price_date:dateKey_(x.price_date),male_price:num_(x.male_price),female_price:num_(x.female_price)})).sort((a,b)=>String(b.price_date).localeCompare(String(a.price_date))).slice(0,180)}
function deleteDateOverride_(u,p){requireRole_(u,['admin']);const row=rows_(SHEETS.PRICING).find(x=>String(x.price_id)===String(p.price_id));if(!row)throw new Error('Override not found');updateById_(SHEETS.PRICING,'price_id',row.price_id,{status:'DELETED',updated_by:u.user_id,updated_at:now_()});audit_(u,'DELETE_DATE_OVERRIDE','pricing',row.price_id,row.price_date);return true}
function getPriceForDate_(d){const ds=dateKey_(d);const override=rows_(SHEETS.PRICING).find(x=>dateKey_(x.price_date)===ds&&String(x.status||'ACTIVE')==='ACTIVE');if(override)return{male_price:num_(override.male_price),female_price:num_(override.female_price),note:override.note||'',source:'DATE OVERRIDE'};const type=dayType_(ds);if(type==='WEEKEND')return{male_price:num_(getSetting_('weekend_male_price','0')),female_price:num_(getSetting_('weekend_female_price','0')),note:'Friday / Saturday',source:'WEEKEND DEFAULT'};return{male_price:num_(getSetting_('normal_male_price','0')),female_price:num_(getSetting_('normal_female_price','0')),note:'Sunday – Thursday',source:'NORMAL DAY DEFAULT'}}

function passView_(p){const amb=rows_(SHEETS.USERS).find(x=>String(x.user_id)===String(p.ambassador_id));const price=getPriceForDate_(dateKey_(p.reservation_date));return{...p,reservation_date:dateKey_(p.reservation_date),ambassador_name:amb?.name||p.ambassador_id,male_price:num_(price.male_price),female_price:num_(price.female_price),price_note:price.note||'',price_source:price.source||'',can_edit:String(p.status)==='ISSUED'&&num_(p.actual_pax)===0}}
function createPass_(u,p){requireRole_(u,['ambassador','admin']);const type=String(p.type||'GROUP').toUpperCase();if(!['INDIVIDUAL','GROUP'].includes(type))throw new Error('Invalid type');const pax=Math.floor(num_(p.planned_pax));if(!(pax>0))throw new Error('人数必须大于 0');const reservationDate=dateKey_(p.reservation_date);if(!/^\d{4}-\d{2}-\d{2}$/.test(reservationDate))throw new Error('请选择预定日期');const pass_id=uuid_('PASS'),pass_ref='YT-'+(type==='GROUP'?'G':'I')+'-'+Utilities.getUuid().replace(/-/g,'').slice(0,6).toUpperCase(),qr_token=Utilities.getUuid().replace(/-/g,'');append_(SHEETS.PASSES,{pass_id,pass_ref,qr_token,ambassador_id:u.user_id,type,label:p.label||'',reservation_date:reservationDate,planned_pax:pax,remark:p.remark||'',status:'ISSUED',actual_pax:0,actual_male:0,actual_female:0,sales:0,created_at:now_(),updated_at:now_()});audit_(u,'CREATE_PASS','pass',pass_id,`${reservationDate} / ${pax} pax`);return{pass_id,pass_ref,qr_token,reservation_date:reservationDate}}
function updatePass_(u,p){requireRole_(u,['ambassador','admin']);const pass=rows_(SHEETS.PASSES).find(x=>String(x.pass_id)===String(p.pass_id)&&String(x.ambassador_id)===String(u.user_id));if(!pass)throw new Error('Pass not found');if(String(pass.status)!=='ISSUED'||num_(pass.actual_pax)>0)throw new Error('Staff 已开始 Check-in，预定内容已锁定');const pax=Math.floor(num_(p.planned_pax));if(!(pax>0))throw new Error('人数必须大于 0');const reservationDate=dateKey_(p.reservation_date);if(!/^\d{4}-\d{2}-\d{2}$/.test(reservationDate))throw new Error('请选择预定日期');const type=String(p.type||pass.type).toUpperCase();if(!['INDIVIDUAL','GROUP'].includes(type))throw new Error('Invalid type');updateById_(SHEETS.PASSES,'pass_id',pass.pass_id,{type,label:p.label||'',reservation_date:reservationDate,planned_pax:pax,remark:p.remark||'',updated_at:now_()});audit_(u,'UPDATE_PASS','pass',pass.pass_id,`${reservationDate} / ${pax} pax`);return passView_(rows_(SHEETS.PASSES).find(x=>String(x.pass_id)===String(pass.pass_id)))}
function lookupPass_(u,p){requireRole_(u,['staff','admin']);const q=String(p.token_or_ref||'').trim();const pass=rows_(SHEETS.PASSES).find(x=>String(x.qr_token)===q||String(x.pass_ref).toUpperCase()===q.toUpperCase());if(!pass)throw new Error('Pass not found');if(String(pass.status)==='VOID')throw new Error('Pass is void');return passView_(pass)}

function partialRedeem_(u,p){requireRole_(u,['staff','admin']);const lock=LockService.getScriptLock();if(!lock.tryLock(10000))throw new Error('System busy, retry');try{return partialLocked_(u,p)}finally{lock.releaseLock()}}
function partialLocked_(u,p){
  const pass=rows_(SHEETS.PASSES).find(x=>String(x.pass_id)===String(p.pass_id));
  if(!pass)throw new Error('Pass not found');
  if(['CLOSED','PAID','VOID'].includes(String(pass.status)))throw new Error('Pass closed');
  const m=Math.floor(num_(p.male)),f=Math.floor(num_(p.female)),pax=m+f;
  if(!(pax>0)||m<0||f<0)throw new Error('请输入男女人数');
  const price=getPriceForDate_(dateKey_(pass.reservation_date));
  let mp=num_(price.male_price),fp=num_(price.female_price);
  if(String(u.role)==='admin'){
    if(String(p.custom_male_price||'').trim()!=='') mp=num_(p.custom_male_price);
    if(String(p.custom_female_price||'').trim()!=='') fp=num_(p.custom_female_price);
    if(mp<0||fp<0) throw new Error('Custom price cannot be negative');
  }
  const sales=Math.round((m*mp+f*fp)*100)/100;
  const amb=rows_(SHEETS.USERS).find(x=>String(x.user_id)===String(pass.ambassador_id));
  if(!amb)throw new Error('Ambassador not found');
  const rate=num_(amb.commission_rate),commission=Math.round(sales*rate)/100;
  const nr={pax:num_(pass.actual_pax)+pax,m:num_(pass.actual_male)+m,f:num_(pass.actual_female)+f};
  const closed=nr.pax>=num_(pass.planned_pax);
  const checkin_ref=uuid_('CI');
  const redeem_ref='YT-RD-'+Utilities.formatDate(now_(),TZ,'yyMMdd')+'-'+Utilities.getUuid().replace(/-/g,'').slice(0,5).toUpperCase();
  append_(SHEETS.CHECKINS,{checkin_ref,pass_id:pass.pass_id,ambassador_id:pass.ambassador_id,staff_id:u.user_id,pax,male:m,female:f,table_no:p.table_no||'',remark:p.remark||'',created_at:now_()});
  append_(SHEETS.REDEEMS,{redeem_ref,pass_id:pass.pass_id,pass_ref:pass.pass_ref,ambassador_id:pass.ambassador_id,staff_id:u.user_id,reservation_date:dateKey_(pass.reservation_date),table_no:p.table_no||'',male_charged:m,female_charged:f,male_price:mp,female_price:fp,sales_amount:sales,commission_rate:rate,commission_amount:commission,final_payment:closed?'YES':'NO',created_at:now_(),status:'CONFIRMED'});
  append_(SHEETS.WALLET,{wallet_txn_id:uuid_('WLT'),ambassador_id:pass.ambassador_id,redeem_ref,type:'COMMISSION',amount:commission,created_at:now_()});
  const newSales=Math.round((num_(pass.sales)+sales)*100)/100;
  updateById_(SHEETS.PASSES,'pass_id',pass.pass_id,{actual_pax:nr.pax,actual_male:nr.m,actual_female:nr.f,sales:newSales,status:closed?'CLOSED':'PARTIAL',updated_at:now_(),closed_at:closed?now_():''});
  audit_(u,'CHECKIN_PAYMENT','pass',pass.pass_id,`${m}M@${mp}+${f}F@${fp}=${sales}; commission=${commission}; closed=${closed}; pricing=${String(u.role)==='admin'?'OWNER_OVERRIDE_ALLOWED':'SYSTEM'}`);
  return{checkin_ref,redeem_ref,sales_amount:sales,commission_amount:commission,closed,pass:passView_(rows_(SHEETS.PASSES).find(x=>String(x.pass_id)===String(pass.pass_id)))};
}

function checkout_(u,p){requireRole_(u,['staff','admin']);const lock=LockService.getScriptLock();if(!lock.tryLock(10000))throw new Error('System busy, retry');try{const pass=rows_(SHEETS.PASSES).find(x=>String(x.pass_id)===String(p.pass_id));if(!pass)throw new Error('Pass not found');if(['PAID','VOID'].includes(String(pass.status)))throw new Error('Pass closed');if(num_(pass.actual_pax)<=0)throw new Error('请先登记实际到场人数');const price=getPriceForDate_(dateKey_(pass.reservation_date)),mp=num_(price.male_price),fp=num_(price.female_price);const existing=rows_(SHEETS.REDEEMS).filter(x=>String(x.pass_id)===String(pass.pass_id)&&String(x.status)==='CONFIRMED');const chargedM=existing.reduce((s,r)=>s+num_(r.male_charged),0),chargedF=existing.reduce((s,r)=>s+num_(r.female_charged),0);const dueM=Math.max(0,num_(pass.actual_male)-chargedM),dueF=Math.max(0,num_(pass.actual_female)-chargedF);const sales=Math.round((dueM*mp+dueF*fp)*100)/100;if(!(sales>0))throw new Error('目前没有新的应收金额');const amb=rows_(SHEETS.USERS).find(x=>String(x.user_id)===String(pass.ambassador_id));if(!amb)throw new Error('Ambassador not found');const rate=num_(amb.commission_rate),commission=Math.round(sales*rate)/100;const redeem_ref='YT-RD-'+Utilities.formatDate(now_(),TZ,'yyMMdd')+'-'+Utilities.getUuid().replace(/-/g,'').slice(0,5).toUpperCase();append_(SHEETS.REDEEMS,{redeem_ref,pass_id:pass.pass_id,pass_ref:pass.pass_ref,ambassador_id:pass.ambassador_id,staff_id:u.user_id,reservation_date:dateKey_(pass.reservation_date),table_no:p.table_no||'',male_charged:dueM,female_charged:dueF,male_price:mp,female_price:fp,sales_amount:sales,commission_rate:rate,commission_amount:commission,final_payment:String(p.final_payment)==='1'?'YES':'NO',created_at:now_(),status:'CONFIRMED'});append_(SHEETS.WALLET,{wallet_txn_id:uuid_('WLT'),ambassador_id:pass.ambassador_id,redeem_ref,type:'COMMISSION',amount:commission,created_at:now_()});const newSales=Math.round((num_(pass.sales)+sales)*100)/100,newStatus=String(p.final_payment)==='1'?'PAID':'PARTIALLY_PAID';updateById_(SHEETS.PASSES,'pass_id',pass.pass_id,{sales:newSales,status:newStatus,updated_at:now_(),closed_at:newStatus==='PAID'?now_():''});audit_(u,'CHECKOUT','pass',pass.pass_id,`${dueM}M@${mp}+${dueF}F@${fp}=${sales}`);return{redeem_ref,commission,sales_amount:sales,male_charged:dueM,female_charged:dueF,male_price:mp,female_price:fp,pass:passView_(rows_(SHEETS.PASSES).find(x=>String(x.pass_id)===String(pass.pass_id)))}}finally{lock.releaseLock()}}

function ambassadorPriceCalendar_(){
  const today=dateKey_(now_()),base=new Date(today+'T00:00:00');
  const days=['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
  const out=[];
  for(let i=0;i<7;i++){
    const d=new Date(base);d.setDate(base.getDate()+i);
    const key=Utilities.formatDate(d,TZ,'yyyy-MM-dd'),p=getPriceForDate_(key);
    out.push({date:key,day_label:(i===0?'Today · ':'')+days[d.getDay()]+' '+Utilities.formatDate(d,TZ,'dd/MM'),male_price:num_(p.male_price),female_price:num_(p.female_price),source:p.source||'',is_today:i===0});
  }
  return out;
}
function ambassadorDashboard_(u){requireRole_(u,['ambassador','admin']);const passes=rows_(SHEETS.PASSES).filter(x=>String(x.ambassador_id)===String(u.user_id)).map(passView_).sort((a,b)=>new Date(b.created_at)-new Date(a.created_at));const wallet=rows_(SHEETS.WALLET).filter(x=>String(x.ambassador_id)===String(u.user_id));const cal=ambassadorPriceCalendar_();const earned=wallet.filter(x=>String(x.type)==='COMMISSION').reduce((a,x)=>a+num_(x.amount),0),paid=Math.abs(wallet.filter(x=>String(x.type)==='PAYOUT').reduce((a,x)=>a+num_(x.amount),0));return{sales:passes.reduce((a,x)=>a+num_(x.sales),0),wallet:wallet.reduce((a,x)=>a+num_(x.amount),0),commission_earned:earned,commission_paid:paid,issued_count:passes.length,redeemed_count:passes.filter(x=>num_(x.sales)>0).length,today_price:cal[0]||null,price_calendar:cal,passes,wallet_history:wallet.sort((a,b)=>new Date(b.created_at)-new Date(a.created_at)).slice(0,100)}}
function staffRecent_(u){requireRole_(u,['staff','admin']);return rows_(SHEETS.REDEEMS).filter(x=>String(u.role)==='admin'||String(x.staff_id)===String(u.user_id)).sort((a,b)=>new Date(b.created_at)-new Date(a.created_at)).slice(0,50)}
function adminDashboard_(u){requireRole_(u,['admin']);const users=rows_(SHEETS.USERS),wallet=rows_(SHEETS.WALLET),redeems=rows_(SHEETS.REDEEMS),checkins=rows_(SHEETS.CHECKINS);const ambassadors=users.filter(x=>String(x.role)==='ambassador').map(a=>{const w=wallet.filter(x=>String(x.ambassador_id)===String(a.user_id));const earned=w.filter(x=>String(x.type)==='COMMISSION').reduce((s,x)=>s+num_(x.amount),0),paid=Math.abs(w.filter(x=>String(x.type)==='PAYOUT').reduce((s,x)=>s+num_(x.amount),0));return{...a,wallet:w.reduce((s,x)=>s+num_(x.amount),0),commission_earned:earned,commission_paid:paid}});return{total_sales:redeems.reduce((s,r)=>s+num_(r.sales_amount),0),total_commission:redeems.reduce((s,r)=>s+num_(r.commission_amount),0),total_pax:checkins.reduce((s,c)=>s+num_(c.pax),0),ambassadors,redeems:redeems.sort((a,b)=>new Date(b.created_at)-new Date(a.created_at)).slice(0,100).map(r=>({...r,ambassador_name:users.find(x=>String(x.user_id)===String(r.ambassador_id))?.name||r.ambassador_id}))}}
