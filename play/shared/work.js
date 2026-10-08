import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';

const $=id=>document.getElementById(id);
const config=window.YETIPSY_PLAY_CONFIG||{};
const mode=document.body.dataset.portal==='owner'?'owner':'staff';
const configured=/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(config.url||'')&&/^sb_publishable_/.test(config.publishableKey||'');
const workURL=(config.url||'')+'/functions/v1/yt-work-auth';
const pinURL=(config.url||'')+'/functions/v1/yt-pin-auth';
const db=configured?createClient(config.url,config.publishableKey,{auth:{storageKey:'yt-work-session-v1',persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}}):null;
const state={identity:null,campaigns:[],games:[],rewards:[],customers:[],pool:[],assigned:[],activePanel:'issue',pendingRedeem:null,scanStream:null,scanBusy:false,scanAnimation:0};
const esc=v=>String(v??'').replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[ch]));
const uuid=()=>crypto.randomUUID();
const fmt=date=>date?new Intl.DateTimeFormat('zh-MY',{timeZone:'Asia/Kuala_Lumpur',year:'numeric',month:'short',day:'2-digit',hour:'2-digit',minute:'2-digit'}).format(new Date(date)):'—';
const toMyTimestamp=s=>s?s+':00+08:00':null;
const fromMyDate=d=>new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Kuala_Lumpur',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false}).format(d).replace(' ','T');
function status(message,bad=false){const el=$('toast');el.textContent=message;el.style.borderColor=bad?'#dc8380':'#dec392';el.classList.remove('hide');clearTimeout(status.timer);status.timer=setTimeout(()=>el.classList.add('hide'),5100);}
function err(e){const s=String(e?.message||e||'请稍后重试');const messages={server_unavailable:'服务暂时不可用，请稍后重试',work_configuration_error:'工作账户服务器尚未配置完成',invalid_credentials:'账号或密码不正确',too_many_attempts:'错误次数过多，请 15 分钟后再试',weak_password:'密码至少12位，须含大写、小写字母和数字，不能包含用户名',invalid_username:'用户名须为3–24位小写字母开头，后接字母、数字或下划线',owner_only:'需要 Owner 权限',not_authenticated:'工作登录已失效，请重新登录',invalid_setup_or_already_used:'激活码无效、已过期或已经使用',invalid_setup:'初始用户名、密码或激活码不正确',username_taken:'用户名已经被使用',staff_not_found:'找不到员工账号',owner_already_exists:'Owner 已经激活，请直接登录',reward_pool_empty_or_sold_out:'奖池库存已用完',staff_only:'需要 Staff 或 Owner 权限',outside_redeem_hours:'不在允许核销的时段',token_invalid:'二维码无效、过期或已使用',invalid_offer:'领取截止时间必须晚于现在，且总份数与每人领取次数需符合限制',reward_inactive:'这个奖品尚未开放，请先启用奖品',invalid_claim_token:'QR 内容无效，请重新生成'};return messages[s]||s.replaceAll('_',' ');}
function busy(button,fn){if(button?.disabled)return Promise.resolve();if(button)button.disabled=true;return Promise.resolve().then(fn).catch(e=>{status(err(e),true);throw e}).finally(()=>{if(button)button.disabled=false});}
const unpack=r=>{if(r?.error)throw Error(r.error.message||'服务器操作失败');return r.data;};
async function token(){const {data,error}=await db.auth.getSession();if(error||!data.session?.access_token)throw Error('not_authenticated');return data.session.access_token;}
async function work(action,body={},signed=false){const headers={'Content-Type':'application/json',apikey:config.publishableKey};if(signed)headers.Authorization='Bearer '+await token();const resp=await fetch(workURL,{method:'POST',headers,cache:'no-store',body:JSON.stringify({action,...body})});const obj=await resp.json().catch(()=>({ok:false,error:'server_unavailable'}));if(!resp.ok||!obj.ok)throw Error(obj.error||'server_unavailable');return obj;}
async function pin(action,body={}){const headers={'Content-Type':'application/json',apikey:config.publishableKey,Authorization:'Bearer '+await token()};const resp=await fetch(pinURL,{method:'POST',cache:'no-store',headers,body:JSON.stringify({action,...body})});const obj=await resp.json().catch(()=>({ok:false,error:'server_unavailable'}));if(!resp.ok||!obj.ok)throw Error(obj.message||obj.error||'server_unavailable');return obj;}
function renderGate(section='login'){ $('gate').classList.remove('hide');$('console').classList.add('hide');$('gateMessage').textContent='';for(const part of ['login','setup','change'])$(part+'Card').classList.toggle('hide',part!==section);$('setupPrompt').classList.toggle('hide',mode!=='owner'||section!=='login'); }
async function setupVisibility(){if(mode!=='owner')return;const data=await work('setup_status');$('setupPrompt').classList.toggle('hide',!data.bootstrap_available);}
function passwordStrong(p,u){return p.length>=12&&p.length<=128&&/[A-Z]/.test(p)&&/[a-z]/.test(p)&&/\d/.test(p)&&!p.toLowerCase().includes(u.toLowerCase());}
function signinView(){renderGate('login');setupVisibility().catch(()=>{});}
async function login(e){e.preventDefault();const u=$('username').value.trim().toLowerCase(),p=$('password').value;const btn=e.submitter;await busy(btn,async()=>{const data=await work('login',{username:u,password:p});if(mode==='owner'&&data.role!=='owner')throw Error('owner_only');const {error}=await db.auth.setSession({access_token:data.access_token,refresh_token:data.refresh_token});if(error)throw error;state.identity={username:data.username,role:data.role,must_change_password:data.must_change_password};$('password').value='';if(data.must_change_password){renderGate('change');$('changeOld').value=p;status('首次登录必须更换临时密码');return;}await displayConsole();});}
async function activate(e){e.preventDefault();const btn=e.submitter,newpw=$('setupNew').value;if(newpw!==$('setupAgain').value)throw Error('两次新密码不一致');if(!passwordStrong(newpw,'owner'))throw Error('weak_password');await busy(btn,async()=>{await work('activate_owner',{username:'owner',password:$('setupOld').value,setup_code:$('setupCode').value.trim(),new_password:newpw});$('setupForm').reset();signinView();$('username').value='owner';$('gateMessage').style.color='#92ddb5';$('gateMessage').textContent='Owner 激活成功。现在请用你刚设置的新密码登录。';status('Owner 激活成功，请使用新密码登录');});}
async function changePassword(e){e.preventDefault();const btn=e.submitter;const newPw=$('changeNew').value;if(newPw!==$('changeAgain').value)throw Error('两次新密码不一致');if(!passwordStrong(newPw,state.identity?.username||''))throw Error('weak_password');await busy(btn,async()=>{await work('password_change',{old_password:$('changeOld').value,new_password:newPw},true);await db.auth.signOut();state.identity=null;$('changeForm').reset();signinView();$('gateMessage').textContent='新密码已保存。请重新登录工作账户。';status('新密码生效，请重新登录');});}
async function signout(){stopCamera();await db.auth.signOut();state.identity=null;signinView();$('password').value='';}
function roleIsOwner(){return state.identity?.role==='owner';}
function openPanel(p){stopCamera();state.activePanel=p;for(const s of ['issue','redeem','reset','team','rewards','campaign','loyalty','insights'])$('panel-'+s).classList.toggle('hide',s!==p);document.querySelectorAll('[data-tool]').forEach(b=>b.classList.toggle('active',b.dataset.tool===p));if(p==='issue')loadCampaigns().catch(report);if(p==='team')loadStaff().catch(report);if(p==='rewards')loadRewards().catch(report);if(p==='campaign')loadCampaignAdmin().catch(report);if(p==='loyalty')loadLoyaltyOwner().catch(report);if(p==='insights')loadInsights().catch(report);}
function report(e){status(err(e),true);}
async function displayConsole(){const a=await work('me',{},true);if(mode==='owner'&&a.role!=='owner'){await signout();throw Error('owner_only');}state.identity={username:a.username,role:a.role,must_change_password:a.must_change_password};if(a.must_change_password){renderGate('change');return;}$('gate').classList.add('hide');$('console').classList.remove('hide');$('welcomeKicker').textContent=a.role==='owner'?'OWNER WORKSPACE':'STAFF WORKSPACE';$('welcomeTitle').textContent=a.role==='owner'?'Yetipsy · Owner Console':'Yetipsy · Staff Console';$('welcomeInfo').textContent='当前工作账号：'+a.username+' · 顾客会员账户保持独立';const tabs=[['issue','发 Game Pass'],['redeem','扫码核销'],['reset','重设 PIN'],...a.role==='owner'?[['team','员工管理'],['rewards','奖品发放'],['campaign','活动概率'],['loyalty','会员活动与积分'],['insights','数据概览']]:[]];const nav=$('menu');nav.replaceChildren();for(const [key,label] of tabs){const b=document.createElement('button');b.dataset.tool=key;b.textContent=label;b.type='button';b.onclick=()=>openPanel(key);nav.append(b);}openPanel('issue');}
async function boot(){bind();if(!configured){renderGate();$('gateMessage').textContent='缺少 Supabase 配置，确认路径 /play/config.js 已存在。';return;}const {data}=await db.auth.getSession();if(data?.session){try{await displayConsole();return;}catch(e){await db.auth.signOut();report(e);}}signinView();}

// QR rendering uses a public script only for visual encoding. Codes are signed/checked server-side.
let qrcodePromise=null;function script(src){return new Promise((resolve,reject)=>{const el=document.createElement('script');el.src=src;el.async=true;el.onload=resolve;el.onerror=()=>reject(Error('无法加载二维码资源；可使用下方复制链接'));document.head.append(el)});}
function copy(s){return navigator.clipboard?.writeText(s).then(()=>status('已复制')).catch(()=>fallbackCopy(s))??fallbackCopy(s);}
function fallbackCopy(s){const el=document.createElement('textarea');el.value=s;document.body.append(el);el.select();document.execCommand('copy');el.remove();status('已复制');}
function codeLink(type,id){
 // Resolve from the module file, not from the current Owner/Staff page URL.
 if(!['claim','gift','reset'].includes(type)||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(id)))throw Error('invalid_claim_token');
 const url=new URL('../',import.meta.url);url.search='';url.hash='';url.searchParams.set(type,id);
 return url.href;
}
async function ensureQRLibrary(){
 if(window.QRCode?.CorrectLevel)return;
 if(!qrcodePromise){qrcodePromise=(async()=>{
  for(const src of ['https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js',
   'https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js']){
   try{await script(src);if(window.QRCode?.CorrectLevel)return;}catch(e){console.warn('QR library source unavailable',src);}
  }
  throw Error('二维码图片组件暂时加载失败，领取链接仍可复制和打开');
 })().catch(e=>{qrcodePromise=null;throw e;});}
 return qrcodePromise;
}
async function showQR(target,title,link,expiry=null){
 const el=$(target);el.classList.remove('hide');el.replaceChildren();
 const heading=document.createElement('h3');heading.textContent=title;el.append(heading);
 const square=document.createElement('div');square.className='qr-canvas';el.append(square);
 const href=document.createElement('a');href.className='qr-link';href.href=link;href.textContent=link;href.target='_blank';href.rel='noreferrer';el.append(href);
 const btn=document.createElement('button');btn.className='btn outline small';btn.type='button';btn.textContent='复制二维码链接';btn.onclick=()=>copy(link);el.append(btn);
 if(expiry){const exp=document.createElement('div');exp.className='qr-exp';exp.textContent='领取码有效至：'+fmt(expiry);el.append(exp);}
 const verification=document.createElement('div');verification.className='notice';verification.textContent='正在验证二维码可领取状态…';el.append(verification);
 let rendered=false;
 try{
  await ensureQRLibrary();
  new window.QRCode(square,{text:link,width:212,height:212,colorDark:'#202820',colorLight:'#ffffff',correctLevel:window.QRCode.CorrectLevel.M});
  rendered=true;
 }catch(e){square.textContent='无法显示 QR 图片，请使用下方链接直接打开或复制';console.warn('QR render',e);}
 return {rendered,verification};
}
async function verifyIssuedCode(kind,raw,render){
 try{
  const result=await pin('preview',{kind,token:raw});
  if(!result.preview?.valid){
   render.verification.textContent='⚠ 服务器未确认这个领取码可用：'+(result.preview?.message||'码可能已到期或活动尚未开放')+'。先不要发给顾客。';
   status('二维码尚未通过服务器核验，请勿分享',true);return false;
  }
  render.verification.textContent=render.rendered?'✓ 服务器已验证：此 QR 当前可领取':'✓ 服务器已验证领取码：QR 图片加载失败，可复制链接领取';
  status(render.rendered?'已创建并验证 QR，可让顾客扫码':'领取码已创建并验证，请使用复制链接',!render.rendered);
  return true;
 }catch(e){
  render.verification.textContent='⚠ 领取码已写入服务器，但实时验证失败：'+err(e)+'。请暂时不要分享。';
  status('无法验证领取码：'+err(e),true);return false;
 }
}
function optionSet(node,values,value,label){const last=node.value;node.replaceChildren();for(const x of values)node.add(new Option(label(x),value(x)));if(values.some(x=>value(x)===last))node.value=last;}
async function loadCampaigns(){const rows=unpack(await db.from('campaigns').select('id,name,active,starts_at,ends_at').eq('active',true).order('created_at',{ascending:false}));state.campaigns=rows||[];optionSet($('passCampaign'),state.campaigns,x=>x.id,x=>x.name);if(!rows.length)status('目前没有开放中的活动；Owner 请先开放活动。',true);}
async function issuePass(e){e.preventDefault();const btn=e.submitter;await busy(btn,async()=>{
 const campaign=$('passCampaign').value;if(!campaign)throw Error('请选择有效的活动');
 const mins=Number($('passMins').value);if(!Number.isInteger(mins)||mins<1||mins>60)throw Error('有效分钟须为1–60');
  const amount=Number($('passSpend').value),receipt=$('passReceipt').value.trim().toUpperCase();
  if(!Number.isFinite(amount)||amount<0.01||Math.round(amount*100)/100!==amount)throw Error('请输入正确的消费金额，例如 60.00');
  if(!/^[A-Z0-9_-]{3,60}$/.test(receipt))throw Error('请输入有效消费单号（3–60位字母、数字、横线或下划线）');
  const raw=uuid(),req=uuid();
  const result=unpack(await db.rpc('yt_issue_spend_pass',{p_campaign:campaign,p_request:req,p_token:raw,p_minutes:mins,p_amount:amount,p_receipt:receipt}));
 if(!result?.length)throw Error('生成 Game Pass 失败');
 const card=await showQR('passQR','Game Pass · 顾客扫码领取',codeLink('claim',raw),result[0].expires_at);
 await verifyIssuedCode('claim',raw,card);
  $('passReceipt').value=nextInternalReceipt();
});}
function parseQR(raw){const text=String(raw||'').trim();let value=text,kind='redeem';const match=text.match(/^(claim|gift|redeem|reset):([0-9a-f-]{36})$/i);if(match){kind=match[1].toLowerCase();value=match[2];}else{try{const u=new URL(text);for(const key of ['redeem','claim','gift','reset'])if(u.searchParams.has(key)){kind=key;value=u.searchParams.get(key);break;}}catch{}}
 if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value))throw Error('无效二维码，请扫描完整的兑奖凭证');return{kind,token:value};}
async function lookupRedeem(e){e?.preventDefault();const btn=e?.submitter||$('lookupBtn');await busy(btn,async()=>{const parsed=parseQR($('redeemValue').value);if(parsed.kind!=='redeem')throw Error('这不是兑奖凭证，请让顾客打开 Wallet 生成兑奖 QR');const rows=unpack(await db.rpc('yt_lookup_redeem',{p_token:parsed.token}));const r=rows?.[0];state.pendingRedeem=null;const root=$('redeemResult');root.className='';root.replaceChildren();if(!r){root.className='empty';root.textContent='找不到这个兑奖码。';return;}root.innerHTML='<h3>'+esc(r.reward_name||'Yetipsy Reward')+'</h3><p class="muted tiny">有效期至 '+esc(fmt(r.expires_at))+'</p>';if(!r.valid){const div=document.createElement('div');div.className='notice';div.textContent='该码无效、已过期、未到使用时间或已核销。';root.append(div);return;}state.pendingRedeem=parsed.token;const confirm=document.createElement('button');confirm.className='btn full';confirm.textContent='确认核销这份奖励 →';confirm.onclick=()=>busy(confirm,redeemReward).catch(()=>{});root.append(confirm);});}
async function redeemReward(){if(!state.pendingRedeem)throw Error('需要先查验兑奖码');const code=state.pendingRedeem;const data=unpack(await db.rpc('yt_redeem',{p_token:code,p_request:uuid()}));if(!data?.length)throw Error('核销未完成，请稍后检查记录');state.pendingRedeem=null;$('redeemValue').value='';$('redeemResult').innerHTML='<div class="notice">✓ 核销成功 · '+esc(data[0].reward_name||'Reward')+'<br>核销时间：'+esc(fmt(data[0].redeemed_at))+'</div>';status('核销成功，已在顾客钱包标记已使用');stopCamera();}
let cameraDetector=null,jsqrPromise=null;
async function startCamera(){if(state.scanStream)return;const frame=$('scanArea');frame.classList.remove('hide');try{state.scanStream=await navigator.mediaDevices.getUserMedia({video:{facingMode:{ideal:'environment'}},audio:false});const video=$('scanVideo');video.srcObject=state.scanStream;await video.play();if('BarcodeDetector'in window){try{cameraDetector=new BarcodeDetector({formats:['qr_code','code_128']});}catch{cameraDetector=null;}}if(!cameraDetector){if(!window.jsQR)jsqrPromise??=script('https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js');await jsqrPromise;}
 state.scanBusy=true;const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d',{willReadFrequently:true});const poll=async()=>{if(!state.scanBusy)return;try{let value=null;if(cameraDetector){const codes=await cameraDetector.detect(video);value=codes[0]?.rawValue;}else if(video.videoWidth){canvas.width=video.videoWidth;canvas.height=video.videoHeight;ctx.drawImage(video,0,0);const data=ctx.getImageData(0,0,canvas.width,canvas.height);value=window.jsQR(data.data,canvas.width,canvas.height)?.data;}if(value){const qr=parseQR(value);if(qr.kind==='redeem'){$('redeemValue').value=value;stopCamera();await lookupRedeem();return;}status('请扫描顾客钱包生成的兑换码',true);}}catch(e){if(state.scanBusy)console.warn('scanner frame',e);}state.scanAnimation=setTimeout(poll,260);};poll();}catch(e){stopCamera();throw Error('相机无法启动，请检查浏览器权限或直接粘贴兑奖码');}}
function stopCamera(){state.scanBusy=false;clearTimeout(state.scanAnimation);if(state.scanStream){for(const t of state.scanStream.getTracks())t.stop();state.scanStream=null;}$('scanArea').classList.add('hide');$('scanVideo').srcObject=null;}
function normalizePhone(country,national){let d=String(national||'').replace(/\D/g,'');if(country==='+60'){if(d.startsWith('60'))d=d.slice(2);if(d.startsWith('0'))d=d.slice(1);if(!/^1\d{8,9}$/.test(d))throw Error('请填写正确的马来西亚手机号');}else{if(d.startsWith('65'))d=d.slice(2);if(!/^[89]\d{7}$/.test(d))throw Error('请填写正确的新加坡手机号');}return country+d;}
async function makeReset(e){e.preventDefault();const btn=e.submitter;await busy(btn,async()=>{if(!$('resetVerified').checked)throw Error('请先确认已完成现场身份核验');const phone=normalizePhone($('resetCountry').value,$('resetPhone').value);const r=await pin('reset_prepare',{phone,birthday:$('resetBirthday').value,onsite_confirmed:true});await showQR('resetQR','仅限顾客本人 · 5分钟内设置新 PIN',codeLink('reset',r.token),new Date(Date.now()+300000).toISOString());$('resetForm').reset();status('PIN 重设二维码已生成');});}
function nextInternalReceipt(){const local=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Kuala_Lumpur',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date()).replaceAll('-','');return 'YT-'+local+'-'+crypto.randomUUID().replaceAll('-','').slice(0,7).toUpperCase();}
function randomPassword(){const chars='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%';const vals=new Uint32Array(18);crypto.getRandomValues(vals);return Array.from(vals,x=>chars[x%chars.length]).join('');}
function showModal(title,body){const root=$('modal');root.replaceChildren();const h=document.createElement('h2');h.textContent=title;root.append(h);const p=document.createElement('p');p.textContent=body;root.append(p);const copyBtn=document.createElement('button');copyBtn.className='btn full';copyBtn.textContent='复制以上内容';copyBtn.onclick=()=>copy(body);const close=document.createElement('button');close.className='btn outline full';close.style.marginTop='8px';close.textContent='关闭';close.onclick=()=>closeModal();root.append(copyBtn,close);$('modalBackdrop').classList.remove('hide');}
function closeModal(){$('modalBackdrop').classList.add('hide');$('modal').replaceChildren();}
async function createStaff(e){e.preventDefault();const btn=e.submitter;await busy(btn,async()=>{const u=$('staffUsername').value.trim().toLowerCase();const pw=$('staffTemp').value;if(!passwordStrong(pw,u))throw Error('weak_password');await work('staff_create',{username:u,temporary_password:pw},true);showModal('新员工账号已创建','Staff Login\nUsername: '+u+'\nTemporary Password: '+pw+'\n\n首次登录必须修改密码。此临时密码只显示这一次，建议通过私下渠道交给员工。');$('staffForm').reset();await loadStaff();status('Staff '+u+' 已建立');});}
async function loadStaff(){const result=await work('staff_list',{},true);const root=$('staffList');root.replaceChildren();for(const person of result.staff||[]){const card=document.createElement('div');card.className='user-card';const active=person.active,change=person.must_change_password;card.innerHTML='<div class="user-row"><div><strong>'+esc(person.username)+'</strong><small>创建 '+esc(fmt(person.created_at))+'</small><small>'+esc(change?'等待首次更改密码':'密码已完成设置')+'</small></div><span class="status-chip '+(active?'':'off')+'">'+(active?'启用中':'已停用')+'</span></div>';
 const buttons=document.createElement('div');buttons.className='button-row';const toggle=document.createElement('button');toggle.className='btn small '+(active?'danger':'outline');toggle.textContent=active?'停用权限':'重新启用';toggle.onclick=()=>busy(toggle,async()=>{if(!confirm('确定'+(active?'停用':'启用')+' '+person.username+'？'))return;await work('staff_toggle',{username:person.username,active:!active},true);await loadStaff();status('员工状态已更新');}).catch(()=>{});
 const reset=document.createElement('button');reset.className='btn outline small';reset.textContent='重设临时密码';reset.onclick=()=>busy(reset,async()=>{if(!confirm('确定重设 '+person.username+' 的登录密码？原密码将失效。'))return;const pw=randomPassword();await work('staff_reset',{username:person.username,temporary_password:pw},true);showModal('员工临时密码已重设','Username: '+person.username+'\nNew temporary password: '+pw+'\n\n员工下次登录必须改为自己的密码。');await loadStaff();}).catch(()=>{});
 buttons.append(toggle,reset);card.append(buttons);root.append(card);}
 if(!root.children.length)root.innerHTML='<div class="empty">尚未创建 Staff。填写左侧表单即可新增员工。</div>';}
async function loadRewards(){
 if(!$('offerUntil').value){$('offerFrom').value=fromMyDate(new Date());$('offerUntil').value=fromMyDate(new Date(Date.now()+7*86400000));}
 const [rs,customers]=await Promise.all([db.from('rewards').select('id,name,description,active,category').eq('active',true).order('created_at',{ascending:false}).limit(400),db.from('profiles').select('id,display_name,phone').not('phone','is',null).order('created_at',{ascending:false}).limit(300)]);
 state.rewards=unpack(rs)||[];state.customers=unpack(customers)||[];
 optionSet($('issueReward'),state.rewards,x=>x.id,x=>x.name);
 optionSet($('directMember'),state.customers,x=>x.id,x=>(x.display_name||'Member')+' · '+(x.phone||'——'));
 if(!state.rewards.length)status('当前没有开放奖品，请先在本页创建一个奖品',true);
}
async function createReward(e){e.preventDefault();const btn=e.submitter;await busy(btn,async()=>{const df=$('rewardClockFrom').value,du=$('rewardClockUntil').value;if(Boolean(df)!==Boolean(du))throw Error('每日使用时间必须同时输入开始和结束');const r=unpack(await db.rpc('yt_create_reward_v11',{p_name:$('rewardName').value.trim(),p_description:$('rewardDesc').value.trim(),p_category:$('rewardCategory').value,p_validity:Number($('rewardDays').value),p_next_day:$('rewardNextDay').checked,p_use_from:toMyTimestamp($('rewardStart').value),p_use_until:toMyTimestamp($('rewardEnd').value),p_daily_from:df||null,p_daily_until:du||null}));$('rewardForm').reset();$('rewardNextDay').checked=true;await loadRewards();$('issueReward').value=r;status('自定义奖品创建成功，可以直接发放或生成 QR');});}
async function createOffer(e){const btn=e.currentTarget;await busy(btn,async()=>{
 const reward=$('issueReward').value;if(!reward)throw Error('请先创建并选择奖品');
 const startRaw=$('offerFrom').value,endRaw=$('offerUntil').value;
 if(!endRaw)throw Error('请先选择奖励领取的截止时间');
 const from=toMyTimestamp(startRaw),until=toMyTimestamp(endRaw);
 if(!Number.isFinite(Date.parse(until))||Date.parse(until)<=Date.now()+10000)throw Error('领取截止时间必须晚于现在');
 if(from&&Date.parse(from)>=Date.parse(until))throw Error('领取截止时间必须晚于开始时间');
 const total=Number($('offerTotal').value),per=Number($('offerPerPerson').value);
 if(!Number.isInteger(total)||total<1||total>10000||!Number.isInteger(per)||per<1||per>10)throw Error('总份数应为1–10000，每人可领次数应为1–10');
 const token=uuid();
 unpack(await db.rpc('yt_create_offer',{p_reward:reward,p_token:token,p_from:from,p_until:until,p_max:total,p_per_user:per}));
 const card=await showQR('giftQR','Reward Claim · 顾客扫码领取',codeLink('gift',token),until);
 await verifyIssuedCode('gift',token,card);
});}
async function directReward(e){const btn=e.currentTarget;await busy(btn,async()=>{const member=$('directMember').value,reward=$('issueReward').value;if(!member||!reward)throw Error('请选择会员与奖品');if(!confirm('确认把这份奖励直接放入所选顾客钱包？'))return;unpack(await db.rpc('yt_send_reward',{p_customer:member,p_reward:reward,p_request:uuid()}));status('奖励已入账顾客钱包');});}
async function loadCampaignAdmin(){const [ca,g,r]=await Promise.all([db.from('campaigns').select('id,name,active').order('created_at',{ascending:false}),db.from('games').select('id,title,slug,active').eq('active',true).order('slug'),db.from('rewards').select('id,name,active').eq('active',true)]);state.campaigns=unpack(ca)||[];state.games=unpack(g)||[];state.rewards=unpack(r)||[];optionSet($('ownerCampaign'),state.campaigns,x=>x.id,x=>(x.active?'● ':'○ ')+x.name);optionSet($('poolGame'),state.games,x=>x.id,x=>x.title);await loadCampaignSettings();}
async function loadCampaignSettings(){const campaign=$('ownerCampaign').value;if(!campaign)return;const c=state.campaigns.find(x=>x.id===campaign);$('campaignActive').checked=!!c?.active;const [links,pool]=await Promise.all([db.from('campaign_games').select('game_id').eq('campaign_id',campaign),db.from('reward_pool_entries').select('id,game_id,result_key,reward_id,weight,max_total,max_daily,issued_total,issued_today').eq('campaign_id',campaign)]);state.assigned=(unpack(links)||[]).map(x=>x.game_id);state.pool=unpack(pool)||[];const root=$('gameToggles');root.replaceChildren();for(const game of state.games){const card=document.createElement('div');card.className='user-card tiny-row';const label=document.createElement('label');label.className='checkline';const cb=document.createElement('input');cb.type='checkbox';cb.checked=state.assigned.includes(game.id);const span=document.createElement('span');span.textContent=game.title;label.append(cb,span);cb.onchange=()=>busy(cb,async()=>{unpack(await db.rpc('yt_owner_set_game',{p_campaign:campaign,p_game:game.id,p_enabled:cb.checked}));await loadCampaignSettings();status('游戏状态已保存');}).catch(()=>{cb.checked=!cb.checked});card.append(label);root.append(card);}renderPool();}
function renderPool(){const game=$('poolGame').value,root=$('poolEditor');root.replaceChildren();const entries=state.pool.filter(x=>x.game_id===game),total=entries.reduce((sum,x)=>sum+Number(x.weight||0),0);for(const x of entries){const card=document.createElement('div');card.className='pool-item';const title=document.createElement('div');title.className='tiny-row';const name=document.createElement('strong');name.textContent='奖项 '+x.result_key;const rate=document.createElement('span');rate.className='rate';rate.textContent=(100*x.weight/Math.max(1,total)).toFixed(2)+'%';title.append(name,rate);card.append(title);const reward=document.createElement('select');for(const r of state.rewards)reward.add(new Option(r.name,r.id));reward.value=x.reward_id;card.append(reward);const form=document.createElement('div');form.className='split';const fields=[['中奖权重',x.weight,1,10000],['总库存（可留空）',x.max_total??'',0,100000],['每日上限（可留空）',x.max_daily??'',0,100000]];const inputs=[];for(const [label,val,min,max] of fields){const col=document.createElement('div');const text=document.createElement('label');text.textContent=label;const inp=document.createElement('input');inp.type='number';inp.value=String(val);inp.min=min;inp.max=max;col.append(text,inp);form.append(col);inputs.push(inp);}card.append(form);const b=document.createElement('button');b.className='btn outline full';b.style.marginTop='12px';b.textContent='保存这个奖项';b.onclick=()=>busy(b,async()=>{const numeric=inp=>inp.value===''?null:Number(inp.value);unpack(await db.rpc('yt_owner_set_pool_v11',{p_entry:x.id,p_reward:reward.value,p_weight:Number(inputs[0].value),p_max_total:numeric(inputs[1]),p_max_daily:numeric(inputs[2])}));status('概率和库存已更新');await loadCampaignSettings();}).catch(()=>{});card.append(b);root.append(card);}if(!entries.length)root.innerHTML='<div class="empty">当前游戏还没有奖池。</div>';}
async function updateCampaign(e){const btn=e.currentTarget;await busy(btn,async()=>{const id=$('ownerCampaign').value;if(!id)throw Error('请先选择活动');unpack(await db.rpc('yt_owner_set_campaign',{p_campaign:id,p_active:$('campaignActive').checked}));status('活动状态已保存');await loadCampaignAdmin();await loadCampaigns();});}
async function cloneCampaign(e){const btn=e.currentTarget;await busy(btn,async()=>{const id=$('ownerCampaign').value,name=$('cloneCampaignName').value.trim();if(!id||!name)throw Error('请填写新活动名称');const created=unpack(await db.rpc('yt_owner_clone_campaign',{p_source:id,p_name:name}));$('cloneCampaignName').value='';await loadCampaignAdmin();$('ownerCampaign').value=created;await loadCampaignSettings();status('新活动已复制，默认关闭');});}
async function loadInsights(){const targets=[['profiles','countMembers',true],['game_passes','countPass',false],['user_rewards','countWallet',false],['redemptions','countRedeem',false]];for(const [table,id] of targets){const result=table==='profiles'?await db.from(table).select('id',{count:'exact',head:true}).not('phone','is',null):await db.from(table).select('id',{count:'exact',head:true});if(result.error){$(id).textContent='—';continue;}$(id).textContent=Number(result.count||0).toLocaleString('en-MY');}}

let loyaltyOwnerData=null;
function loyaltySelect(id,selected,emptyLabel='不提供'){const node=$(id);if(!node)return;node.replaceChildren();node.add(new Option(emptyLabel,''));for(const reward of state.rewards)node.add(new Option(reward.name,reward.id));node.value=selected||'';}
async function loadLoyaltyOwner(){
 if(!roleIsOwner())throw Error('owner_only');
 const [rs,s]=await Promise.all([db.from('rewards').select('id,name,active').eq('active',true).order('name'),db.rpc('yt_loyalty_owner_settings')]);
 state.rewards=unpack(rs)||[];const cfg=unpack(s);loyaltyOwnerData=cfg;
 $('loyaltyWelcomeEnabled').checked=!!cfg.welcome_enabled;
 $('loyaltyReferralEnabled').checked=!!cfg.referral_enabled;
 $('loyaltyStack').checked=!!cfg.rewards_stack;
 $('loyaltyPointsEnabled').checked=!!cfg.points_enabled;
 $('loyaltyPointsRate').value=cfg.points_per_rm;
 $('loyaltyCap').value=cfg.max_points_percent;
 $('loyaltyMinSpend').value=cfg.min_spend_rm;
 $('loyaltyMaxSpend').value=cfg.max_spend_rm;
 loyaltySelect('loyaltyWelcomeReward',cfg.welcome_reward_id,'请选择注册奖励');
 loyaltySelect('loyaltyFriendReward',cfg.friend_reward_id,'请选择好友注册奖励');
 loyaltySelect('loyaltyInviterReward',cfg.inviter_reward_id,'不奖励邀请人（默认）');
 const sbox=$('loyaltyStats');sbox.textContent=`已记录邀请 ${cfg.stats?.referred_members||0} 位 · 新人礼 ${cfg.stats?.welcome_grants||0} 份 · 推荐礼 ${cfg.stats?.referral_grants||0} 份 · 累计送出积分 ${Number(cfg.stats?.points_awarded||0).toLocaleString('en-MY')} P`;
 const root=$('loyaltyTierEditor');root.replaceChildren();
 for(const t of cfg.tiers||[]){const section=document.createElement('div');section.className='user-card';section.innerHTML=`<strong>随机积分档位</strong><div class="split"><div><label>积分数</label><input class="tier-points" type="number" min="1" max="1000000" value="${Number(t.points)}"></div><div><label>权重（仅 Owner 可见）</label><input class="tier-weight" type="number" min="0" max="10000" value="${Number(t.weight)}"></div></div><label class="checkline"><input class="tier-enabled" type="checkbox" ${t.enabled?'checked':''}> 启用此档位</label><button type="button" class="btn outline small tier-save">保存档位</button>`;
  section.querySelector('.tier-save').onclick=e=>busy(e.currentTarget,async()=>{
   unpack(await db.rpc('yt_loyalty_owner_tier',{p_id:t.id,p_points:Number(section.querySelector('.tier-points').value),p_weight:Number(section.querySelector('.tier-weight').value),p_enabled:section.querySelector('.tier-enabled').checked}));
   status('积分档位已保存');await loadLoyaltyOwner();
  }).catch(()=>{});
  root.append(section);
 }
}
async function saveLoyaltyOwner(e){const btn=e.currentTarget;await busy(btn,async()=>{
 const p={
  p_welcome_enabled:$('loyaltyWelcomeEnabled').checked,p_welcome_reward:$('loyaltyWelcomeReward').value||null,
  p_referral_enabled:$('loyaltyReferralEnabled').checked,p_friend_reward:$('loyaltyFriendReward').value||null,
  p_inviter_reward:$('loyaltyInviterReward').value||null,p_stack:$('loyaltyStack').checked,
  p_points_enabled:$('loyaltyPointsEnabled').checked,p_points_per_rm:Number($('loyaltyPointsRate').value),
  p_cap_percent:Number($('loyaltyCap').value),p_min_spend:Number($('loyaltyMinSpend').value),p_max_spend:Number($('loyaltyMaxSpend').value)
 };
 if((p.p_welcome_enabled||p.p_referral_enabled)&&!confirm('注意：手机号目前未完成短信验证，免费礼物可能被重复开新账号领取。确认要开放这些活动？'))return;
 unpack(await db.rpc('yt_loyalty_owner_save',p));status('活动与积分设置已保存');await loadLoyaltyOwner();
}).catch(()=>{});}
async function addLoyaltyTier(e){const btn=e.currentTarget;await busy(btn,async()=>{
 const pts=Number($('loyaltyNewTierPoints').value),weight=Number($('loyaltyNewTierWeight').value);
 unpack(await db.rpc('yt_loyalty_owner_tier',{p_id:null,p_points:pts,p_weight:weight,p_enabled:true}));
 $('loyaltyNewTierPoints').value='';$('loyaltyNewTierWeight').value='';await loadLoyaltyOwner();status('已新增积分抽取档位');
}).catch(()=>{});}

function bind(){ $('loginForm').onsubmit=e=>login(e).catch(report);$('setupForm').onsubmit=e=>activate(e).catch(report);$('changeForm').onsubmit=e=>changePassword(e).catch(report);$('openSetup').onclick=()=>renderGate('setup');$('setupBack').onclick=signinView;$('logoutBtn').onclick=()=>signout().catch(report);$('passReceiptAuto').onclick=()=>{$('passReceipt').value=nextInternalReceipt();};if(!$('passReceipt').value)$('passReceipt').value=nextInternalReceipt();$('passForm').onsubmit=e=>issuePass(e).catch(()=>{});$('lookupForm').onsubmit=e=>lookupRedeem(e).catch(()=>{});$('scanBtn').onclick=e=>busy(e.currentTarget,startCamera).catch(()=>{});$('scanStop').onclick=stopCamera;$('resetForm').onsubmit=e=>makeReset(e).catch(()=>{});$('staffForm').onsubmit=e=>createStaff(e).catch(()=>{});$('staffTempGenerate').onclick=()=>{$('staffTemp').value=randomPassword();};$('refreshStaff').onclick=e=>busy(e.currentTarget,loadStaff).catch(()=>{});$('rewardForm').onsubmit=e=>createReward(e).catch(()=>{});$('issueOfferBtn').onclick=e=>createOffer(e).catch(()=>{});$('directSendBtn').onclick=e=>directReward(e).catch(()=>{});$('ownerCampaign').onchange=()=>loadCampaignSettings().catch(report);$('poolGame').onchange=renderPool;$('saveCampaignBtn').onclick=e=>updateCampaign(e).catch(()=>{});$('cloneBtn').onclick=e=>cloneCampaign(e).catch(()=>{});$('refreshInsights').onclick=e=>busy(e.currentTarget,loadInsights).catch(()=>{});$('saveLoyaltyOwner').onclick=saveLoyaltyOwner;$('addLoyaltyTier').onclick=addLoyaltyTier;$('modalBackdrop').onclick=e=>{if(e.target===$('modalBackdrop'))closeModal();};document.addEventListener('keydown',e=>{if(e.key==='Escape'){closeModal();stopCamera();}});}
boot().catch(report);
