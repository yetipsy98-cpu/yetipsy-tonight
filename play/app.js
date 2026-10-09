import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';
import {createBannerManager} from './owner-banners.js?v=20261009-client-v5-1';
import {createHomeCarousel} from './home-carousel.js?v=20261009-client-v5-1';

const $=id=>document.getElementById(id);
const urlConfig=window.YETIPSY_PLAY_CONFIG||{};
const configured=/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(urlConfig.url||'')&&/^sb_publishable_/.test(urlConfig.publishableKey||'');
const db=configured?createClient(urlConfig.url,urlConfig.publishableKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}}):null;
const EDGE_URL=(urlConfig.url||'')+'/functions/v1/yt-pin-auth';
const MY_TZ='Asia/Kuala_Lumpur';
const state={user:null,role:null,profile:null,view:'home',games:[],passes:[],wallet:[],rewards:[],campaigns:[],ownerGames:[],pool:[],assigned:[],busy:false,refreshing:false,activeSession:null,currentRedemption:null,currentOffer:null,board:[],staffRoles:[],handleToken:null,loginMode:'phone',checkedPhone:null,pendingClaim:null,gamePlaying:false,referralDraft:'',loyalty:null};
let scanner=null,scannerRunning=false,qrLibPromise=null,barcodeLibPromise=null;
const uuid=()=>crypto.randomUUID();
const esc=x=>String(x??'').replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[ch]));
const fmt=t=>t?new Intl.DateTimeFormat('zh-MY',{timeZone:MY_TZ,day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit'}).format(new Date(t)):'未设置';
const millis=t=>t?new Date(t).getTime():0;
const pending=(btn,job)=>{if(btn?.disabled)return Promise.resolve();if(btn)btn.disabled=true;return Promise.resolve().then(job).catch(err=>{toast(errorText(err),true);throw err;}).finally(()=>{if(btn)btn.disabled=false;});};
const unpack=result=>{if(result?.error)throw new Error(result.error.message||'数据库请求失败');return result.data;};
const isStaff=()=>state.role==='staff'||state.role==='owner';
const isOwner=()=>state.role==='owner';
const newLink=(kind,token)=>{const u=new URL(location.href);u.search='';u.hash='';u.searchParams.set(kind,token);return u.toString();};
const failerr=(message)=>{throw new Error(message);};
function toast(message,bad=false){const el=$('toast');el.textContent=message;el.style.borderColor=bad?'#c77d70':'#ccaa76';el.classList.add('show');clearTimeout(toast.timer);toast.timer=setTimeout(()=>el.classList.remove('show'),4600);}
function errorText(e){const s=String(e?.message||e||'操作失败');const map={claim_code_invalid:'领取码不正确，请核对 8 位短码',claim_code_rate_limited:'输入次数过多，请一分钟后再试',owner_only:'仅限 Owner 操作',staff_only:'仅限员工操作',not_authenticated:'登录已失效，请重新登录',pass_invalid_or_claimed:'游戏码无效、已领取或已过期',offer_unavailable:'奖励已领完、尚未开放或已到期',offer_not_found:'找不到这个奖励领取码',account_claim_limit:'你已经达到这个活动的领取次数',reward_no_valid_window:'奖品的可用时间设置有冲突',reward_not_redeemable:'奖励尚未到可兑换时间，或已经过期',outside_redeem_hours:'不在奖品允许兑换的营业时段',reward_pool_empty_or_sold_out:'奖池库存已用完',invalid_credentials:'手机号或 PIN 不正确',too_many_attempts:'尝试次数过多，请 15 分钟后再试',already_registered:'该号码已注册，请直接登录',invalid_pin:'请输入 6 位数字 PIN',weak_pin:'PIN 太容易猜，请换一个',invalid_phone:'请输入正确的手机号码',request_conflict:'请刷新后重试'};return map[s]||s.replaceAll('_',' ');}
function shell(showMain){$('authView').classList.toggle('hide',showMain);$('mainView').classList.toggle('hide',!showMain);$('workspaceView').classList.add('hide');}
function navigate(page='home'){state.view=page;shell(true);for(const e of document.querySelectorAll('.page'))e.classList.toggle('hide',e.id!==page+'Page');for(const e of document.querySelectorAll('[data-page]'))e.classList.toggle('active',e.dataset.page===page);window.scrollTo({top:0,behavior:'smooth'});if(page==='wallet'){wallet().catch(e=>toast(errorText(e),true));loadMyLoyalty().catch(()=>{});}if(page==='home'){updateHome();homeCarousel?.refresh().catch(()=>{});}if(page==='account'){drawProfile();loadMyLoyalty().catch(()=>{});}}
async function pinRequest(action,phone='',pin='',nickname='',extras={}){
 const {bearer, ...fields}=extras;
 const headers={'Content-Type':'application/json',apikey:urlConfig.publishableKey};
 if(bearer)headers.Authorization='Bearer '+bearer;
 const resp=await fetch(EDGE_URL,{method:'POST',headers,body:JSON.stringify({action,phone,pin,nickname,...fields}),cache:'no-store'});
 const data=await resp.json().catch(()=>({ok:false,error:'server_unavailable'}));
 if(!resp.ok||!data.ok)throw new Error(data.message||errorText(data.error)||'操作失败');
 return data;
}
function normalizePhone(country,value){
 let raw=String(value||'').trim().replace(/[^\d]/g,'');
 if(country==='+60'){
  if(raw.startsWith('60'))raw=raw.slice(2);
  if(raw.startsWith('0'))raw=raw.slice(1);
  if(!/^1\d{8,9}$/.test(raw))throw Error('请输入正确的马来西亚手机号码');
 }else{
  if(raw.startsWith('65'))raw=raw.slice(2);
  if(!/^\d{8}$/.test(raw)||!raw.startsWith('8')&&!raw.startsWith('9'))throw Error('新加坡手机号码须为 8 位，且以 8 或 9 开头');
 }
 return country+raw;
}
function phoneNumber(){return normalizePhone($('country').value,$('phone').value);}
function changeAuthMode(mode='phone'){
 state.loginMode=mode;
 $('phoneStage').classList.toggle('hide',mode!=='phone');
 $('authForm').classList.toggle('hide',mode==='phone');
 const signup=mode==='register';
 $('nicknameGroup').classList.toggle('hide',!signup);
 $('birthdayGroup').classList.toggle('hide',!signup);
 $('referralGroup').classList.toggle('hide',!signup);
  if(signup && state.referralDraft)$('referralCode').value=state.referralDraft;
 $('confirmPinGroup').classList.toggle('hide',!signup);
 $('consentGroup').classList.toggle('hide',!signup);
 $('nickname').required=signup;$('birthday').required=signup;$('pinConfirm').required=signup;
 if(mode!=='phone'){$('authKnownPhone').textContent=state.checkedPhone;$('authStepTitle').textContent=signup?'JOIN YETIPSY · ONE LAST STEP':'WELCOME BACK · MEMBER SIGN-IN';}
 $('authSubmit').innerHTML=signup?'完成注册并加入 <span>↗</span>':'安全登录 <span>↗</span>';
 $('pinLabel').textContent=signup?'设置 6 位安全 PIN *':'你的 6 位 PIN *';
 $('pinHint').textContent=signup?'无短信验证码，请记住你的 PIN；忘记时需到店由员工核实。':'输入已设置的 PIN。忘记 PIN 可到店由员工协助重设。';
 $('authError').textContent='';
}
async function submitPhone(ev){ev.preventDefault();const button=$('checkPhone');try{
 await pending(button,async()=>{
  const phone=phoneNumber(),result=await pinRequest('check',phone);
  state.checkedPhone=phone;changeAuthMode(result.registered?'login':'register');
  $('pin').value='';$('pinConfirm').value='';
  $('pin').focus();
 });
}catch(err){$('authError').textContent=errorText(err);}}
async function submitAuth(ev){ev.preventDefault();const b=$('authSubmit');try{
 await pending(b,async()=>{
  if(!configured)throw Error('Supabase 尚未配置');
  const phone=state.checkedPhone,pin=$('pin').value;
  if(!phone)throw Error('请先输入手机号');
  if(!/^\d{6}$/.test(pin))throw Error('PIN 必须为 6 位数字');
  $('authError').textContent='';
  const signup=state.loginMode==='register';
  let extras={};
  if(signup){
   if($('pinConfirm').value!==pin)throw Error('两次 PIN 不一致');
   if($('nickname').value.trim().length<2)throw Error('请填写你的称呼');
   if(!$('birthday').value)throw Error('请选择完整出生日期');
   extras={birthday:$('birthday').value,referral_code:$('referralCode').value.trim().toUpperCase()};
  }
  const data=await pinRequest(state.loginMode,phone,pin,$('nickname').value.trim(),extras);
  const {error}=await db.auth.setSession({access_token:data.access_token,refresh_token:data.refresh_token});
  if(error)throw error;
  $('pin').value='';$('pinConfirm').value='';
  await initialize();toast(signup?'欢迎加入 Yetipsy Play ✳':'欢迎回来 ✳');
   if(signup){state.referralDraft='';const next=new URL(location.href);next.searchParams.delete('invite');history.replaceState(null,'',next.href);}
   loadMyLoyalty().catch(()=>{});
   if(state.pendingClaim){const claim=state.pendingClaim;state.pendingClaim=null;try{await redeemScanValue(claim.token,claim.kind);}catch(e){toast(errorText(e),true);}}
 });
}catch(err){$('authError').textContent=errorText(err);}}
async function initialize(){if(!db)return;const {data:{user},error}=await db.auth.getUser();if(error&&!/Auth session missing/i.test(error.message||''))console.warn('Session:',error.message);state.user=user||null;
 if(!user){state.role=null;state.profile=null;state.wallet=[];state.passes=[];shell(false);return;}
 const [role,profile]=await Promise.all([
 db.from('staff_roles').select('role').eq('user_id',user.id).eq('active',true).maybeSingle(),
 db.from('profiles').select('id,display_name,phone').eq('id',user.id).maybeSingle()
 ]);
 state.role=unpack(role)?.role||null;state.profile=unpack(profile)||null;
 $('accountStaff').classList.toggle('hide',!isStaff());$('accountOwner').classList.toggle('hide',!isOwner());
 await Promise.all([refreshPasses(),loadGames(),wallet(true)]);
 navigate('home');
 if(new URL(location.href).searchParams.has('redeem')&&isStaff()){openWorkspace('staff');$('staffRedeemInput').value=new URL(location.href).searchParams.get('redeem');showStaffRedeem();}
}
function drawProfile(){const p=state.profile||{};$('profileName').textContent=p.display_name||'Yetipsy Member';$('profilePhone').textContent=p.phone||'PLAY CLUB MEMBER';$('profileLevel').textContent=isOwner()?'OWNER MEMBER':isStaff()?'STAFF MEMBER':'PLAY CLUB MEMBER';}
function updateHome(){const valid=state.passes.filter(p=>p.status==='claimed'&&millis(p.expires_at)>Date.now());$('openExistingPass').classList.toggle('hide',!valid.length);$('homeGreetingSub').textContent=state.profile?.display_name?'嗨，'+state.profile.display_name+' · 今晚玩点新的？':'YETIPSY PLAY · 轻松享受此刻';}
async function refreshPasses(){if(!state.user)return;state.passes=unpack(await db.from('game_passes').select('id,status,claimed_at,expires_at,campaign_id,created_at,spend_amount_rm,spend_ref,selection').eq('customer_id',state.user.id).order('created_at',{ascending:false}).limit(50));updateHome();}
async function loadGames(){state.games=unpack(await db.from('games').select('id,slug,title,mode,active').eq('active',true).order('slug'));}
async function wallet(silent=false){if(!state.user)return;const items=unpack(await db.from('user_rewards').select('id,status,created_at,redeem_after,expires_at,redeemed_at,rewards(name,description,category,daily_start_local,daily_end_local)').eq('customer_id',state.user.id).order('created_at',{ascending:false}).limit(100));state.wallet=items;renderWallet();if(!silent)updateHome();}
const iconFor=category=>({drink:'♧',voucher:'◇',gift:'✳',event:'✦',custom:'◈'})[category]||'✦';
function renderWallet(){const root=$('walletItems');root.replaceChildren();
 if(!state.wallet.length){root.innerHTML='<div class="empty-state"><span class="empty-symbol">✦</span>这里还没有奖励。<br/>扫码玩游戏，或领取店主送出的好礼。</div>';return;}
 for(const r of state.wallet){const expires=millis(r.expires_at)<=Date.now(),early=millis(r.redeem_after)>Date.now(),redeemed=r.status==='redeemed';const available=r.status==='available'&&!expires&&!early;const card=document.createElement('div');card.className='reward-item';const status=redeemed?'已核销':expires?'已过期':r.status==='revoked'?'已作废':early?'未到使用时间':'可兑换';card.innerHTML=`<div class="reward-icon">${iconFor(r.rewards?.category)}</div><div><span class="chip ${available?'ok':redeemed?'off':''}">${status}</span><h3>${esc(r.rewards?.name||'Reward')}</h3><p>${esc(r.rewards?.description||'到店出示凭证由员工核销')}</p><p>开始：${esc(fmt(r.redeem_after))}<br/>截止：${esc(fmt(r.expires_at))}</p>${r.rewards?.daily_start_local?`<p>每日可用：${esc(r.rewards.daily_start_local.slice(0,5))} – ${esc(r.rewards.daily_end_local.slice(0,5))}</p>`:''}</div>`;
 if(available){const btn=document.createElement('button');btn.className='button button-outline';btn.textContent='▣ 出示兑奖二维码 / 兑换码';btn.onclick=()=>pending(btn,()=>showRewardQR(r));card.append(btn);}root.append(card);}
}
function showSheet(title,eyebrow='YETIPSY PLAY'){if(scannerRunning)stopScanner();$('sheetTitle').textContent=title;$('sheetEyebrow').textContent=eyebrow;$('sheetBody').replaceChildren();$('sheetBackdrop').classList.remove('hide');document.body.style.overflow='hidden';}
async function closeSheet(){await stopScanner();$('sheetBackdrop').classList.add('hide');document.body.style.overflow='';}
function sheetHtml(s){$('sheetBody').innerHTML=s;}
function sheetAction(id,label,callback,klass='button-primary'){const b=document.createElement('button');b.id=id;b.className='button '+klass+' wide';b.textContent=label;b.onclick=()=>pending(b,callback);$('sheetBody').append(b);return b;}
const loadScript=url=>new Promise((resolve,reject)=>{const el=document.createElement('script');el.src=url;el.async=true;el.onload=resolve;el.onerror=()=>reject(Error('资源暂时加载失败，您可以使用复制链接'));document.head.append(el);});
async function qrcode(target,text){
 if(!window.QRCode?.CorrectLevel){
  if(!qrLibPromise)qrLibPromise=(async()=>{
   for(const url of ['https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js','https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js']){
    try{await loadScript(url);if(window.QRCode?.CorrectLevel)return;}catch(e){console.warn('QR library fallback',url);}
   }
   throw Error('QR 图片资源暂时不可用');
  })().catch(e=>{qrLibPromise=null;throw e;});
  await qrLibPromise;
 }
 target.replaceChildren();
 new window.QRCode(target,{text,width:220,height:220,colorDark:'#171b19',colorLight:'#faf6e9',correctLevel:window.QRCode.CorrectLevel.M});
}
async function barcode(svg,text){if(!window.JsBarcode)barcodeLibPromise??=loadScript('https://cdn.jsdelivr.net/npm/jsbarcode@3.11.6/dist/JsBarcode.all.min.js');await barcodeLibPromise;window.JsBarcode(svg,text,{format:'CODE128',lineColor:'#1c2421',background:'#f2ecdf',width:1.1,height:51,displayValue:false,margin:3});}
function copy(text){navigator.clipboard?.writeText(text).then(()=>toast('已复制')).catch(()=>{const input=document.createElement('textarea');input.value=text;document.body.append(input);input.select();document.execCommand('copy');input.remove();toast('已复制');});}
async function showCodeSheet(title,subtitle,link,withBarcode=true,deadline=null,shortCode=null,shortKind='redeem'){showSheet(title,'SCAN & CLAIM');sheetHtml(`<div class="sheet-content"><p>${esc(subtitle)}</p><div class="code-card"><b>YE·TIPSY</b><small style="display:block">PRESENT THIS CODE</small><div id="sheetQR" class="sheet-qr-container"></div>${withBarcode?'<svg id="sheetBarcode" aria-label="可扫描条形码"></svg>':''}<div class="token-text" id="sheetToken"></div></div><button type="button" id="sheetCopy" class="button button-outline wide">${shortCode?(shortKind==='gift'?'复制领取码':'复制兑换码'):'复制领取链接 / 扫描内容'}</button>${deadline?'<p id="sheetCountdown" class="tiny-help"></p>':''}<p class="tiny-help">${shortCode?(shortKind==='gift'?'扫不到时，在客户端点击「领取奖励」，输入这组 8 位领取码。':'扫不到时，把这组 8 位兑换码报给店员，在点单购物车中输入即可。'):'优先使用二维码；支持条形码的扫描设备也可以读取同一凭证。'}</p></div>`);$('sheetToken').textContent=shortCode||link;if(shortCode){$('sheetToken').classList.add('redeem-short-code');$('sheetToken').setAttribute('aria-label','短兑换码');}const codeURL=new URL(link);const codeKey=[...codeURL.searchParams.keys()][0]||'claim';const codeRaw=codeURL.searchParams.get(codeKey)||link;const raw=codeKey+':'+codeRaw;try{await qrcode($('sheetQR'),link);}catch(e){$('sheetQR').style.display='none';toast(shortCode?'二维码加载失败，请出示下方兑换码':'二维码素材加载失败，请复制链接',true);}if(withBarcode){try{await barcode($('sheetBarcode'),raw);}catch(e){$('sheetBarcode').classList.add('hide');}}
 $('sheetCopy').onclick=()=>copy(shortCode||link);if(deadline){const tick=()=>{const el=$('sheetCountdown');if(!el||!el.isConnected){clearInterval(timer);return;}const secs=Math.max(0,Math.ceil((millis(deadline)-Date.now())/1000));el.textContent=secs?(shortKind==='gift'?'领取截止：'+fmt(deadline):`${shortCode?(shortKind==='gift'?'二维码与领取码':'二维码与兑换码'):'动态二维码'} ${secs} 秒后失效`):'已过期，需要重新生成';if(!secs){clearInterval(timer);if(shortCode){$('sheetCopy').disabled=true;$('sheetToken').classList.add('code-expired');}}};let timer=setInterval(tick,1000);tick();}}
async function showRewardQR(reward){const code=uuid();const data=unpack(await db.rpc('yt_make_redeem_v5',{p_award:reward.id,p_token:code}));const link=newLink('redeem',code);await showCodeSheet('出示奖励凭证',reward.rewards?.name||'Yetipsy Reward',link,true,data.expires_at,data.display_code);const regenerate=document.createElement('button');regenerate.type='button';regenerate.className='button button-outline wide';regenerate.textContent='重新生成兑换码';regenerate.onclick=()=>pending(regenerate,()=>showRewardQR(reward));$('sheetCountdown').after(regenerate);}
function tokenDetails(raw){const s=String(raw||'').trim();const short=s.replace(/[\s-]/g,'').toUpperCase();if(/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$/.test(short))return {kind:'gift_code',token:short};let kind='claim',token=s;const prefixed=s.match(/^(gift|claim|redeem):([0-9a-f-]{36})$/i);if(prefixed){kind=prefixed[1].toLowerCase();token=prefixed[2];}
 try{const url=new URL(s);for(const k of ['claim','gift','redeem']){if(url.searchParams.has(k)){kind=k;token=url.searchParams.get(k);break;}}}catch{}
 if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(token))throw Error('无效的二维码或条形码，请扫描完整凭证');return {kind,token};}
const requestStore={get(key){try{return sessionStorage.getItem(key)}catch{return null}},set(key,v){try{sessionStorage.setItem(key,v)}catch{}},remove(key){try{sessionStorage.removeItem(key)}catch{}}};
function retryId(key){let prev=requestStore.get('v11:'+key);if(prev)return prev;prev=uuid();requestStore.set('v11:'+key,prev);return prev;}
async function previewClaim(raw,assumed=null){
 const info=tokenDetails(raw);if(assumed&&info.kind!=='gift_code')info.kind=assumed;
 if(info.kind==='gift_code')return redeemScanValue(info.token);
 if(info.kind==='redeem'){if(!state.user||!isStaff())throw Error('请由店员扫码核销奖励');return redeemScanValue(info.token,'redeem');}
 const data=(await pinRequest('preview','','','',{kind:info.kind,token:info.token})).preview;
 if(!data)throw Error('暂时无法预览这份领取码');
 showSheet(data.valid?'Almost yours.':'领取状态','YETIPSY · JUST ONE MORE STEP');
 const title=data.title||'Yetipsy Reward',limit=data.expires_at?`有效至 ${fmt(data.expires_at)}`:'';
 const count=info.kind==='gift'&&data.remaining!=null?`剩余 ${Number(data.remaining)} 份`:info.kind==='claim'?`${data.game_count||0} 款游戏可选`:'';
 sheetHtml(`<div class="sheet-content claim-preview"><div class="preview-glyph">${info.kind==='gift'?'✦':'◇'}</div><div class="overline">${esc(data.subtitle||'YETIPSY PLAY')}</div><h2>${esc(title)}</h2><p>${esc(data.description||'你的专属惊喜')}</p><div class="preview-infos"><span>${esc(limit)}</span><span>${esc(count)}</span></div>${data.rules?`<p class="tiny-help">${esc(data.rules)}</p>`:''}<div id="previewAction"></div></div>`);
 const target=$('previewAction');
 if(!data.valid){target.innerHTML='<div class="preview-unavailable">这份领取码暂不可用，可能尚未开始、已被领取、已过期或已领完。</div>';return;}
 const button=document.createElement('button');button.className='button button-primary wide';button.textContent=state.user?'确认领取 '+(info.kind==='claim'?'Game Pass':'奖励')+' ↗':'领取 '+(info.kind==='claim'?'Game Pass':'奖励')+' · 只差一步 ↗';
 button.onclick=()=>pending(button,async()=>{
  if(!state.user){state.pendingClaim=info;await closeSheet();shell(false);changeAuthMode('phone');$('authError').textContent='只差一步！输入手机号码，领取会在登录或注册后自动完成。';window.scrollTo(0,0);return;}
  await redeemScanValue(info.token,info.kind);
 }).catch(()=>{});target.append(button);
}
async function redeemScanValue(raw,assumed){const info=tokenDetails(raw);if(assumed&&info.kind!=='gift_code')info.kind=assumed;
 if(!state.user){state.pendingClaim=info;await closeSheet();shell(false);changeAuthMode('phone');$('authError').textContent='只差一步！登录或注册后会继续领取这份奖励。';return;}

 if(info.kind==='redeem'){if(!isStaff())throw Error('兑奖二维码需由 Staff 扫描');openWorkspace('staff');showStaffRedeem();$('staffRedeemInput').value=info.token;await lookupRedeem();return;}
 if(info.kind==='gift'||info.kind==='gift_code'){
  const key=info.kind+':'+info.token,req=retryId(key);let rows;
  if(info.kind==='gift_code'){const result=unpack(await db.rpc('yt_claim_offer_code',{p_code:info.token,p_request:req}));if(result?.error_code)throw Error(result.error_code);rows=result?.awards;}
  else rows=unpack(await db.rpc('yt_claim_offer',{p_token:info.token,p_request:req}));if(!rows?.length)throw Error('奖励领取失败');stripLink('gift');await wallet(true);await showSimpleSuccess('领取成功',rows[0].reward_name||'礼物已放进奖励钱包','奖励可在「我的奖励」里查看使用时间。');requestStore.remove('v11:'+key);return;
 }
 const claimedId=unpack(await db.rpc('yt_claim_pass',{p_token:info.token}));stripLink('claim');await refreshPasses();toast('游戏机会已经领取 ✳');const p=state.passes.find(x=>x.id===claimedId&&x.status==='claimed'&&millis(x.expires_at)>Date.now());if(p)await choosePassReward(p);else toast('游戏机会已入账，请到首页选择游戏',true);
}
function stripLink(kind){const u=new URL(location.href);u.searchParams.delete(kind);history.replaceState(null,'',u.href);}
function openRewardClaim(){
 showSheet('输入奖励领取码','REWARD CLAIM');
 sheetHtml('<div class="sheet-content"><p>输入店员提供的 8 位 Reward Claim 短码，奖励会存入你的 Wallet。</p><form id="rewardClaimForm"><label for="rewardClaimCode">奖励领取码</label><input id="rewardClaimCode" class="claim-code-input" placeholder="例如 7K3M-9X2P" maxlength="16" autocomplete="off" autocapitalize="characters" spellcheck="false" required/><button id="rewardClaimSubmit" class="button button-primary wide" type="submit">领取奖励 ↗</button></form><p class="tiny-help">请按活动设置的开始与截止时间领取，每账户限额保持有效。</p></div>');
 $('rewardClaimForm').onsubmit=e=>{e.preventDefault();return pending($('rewardClaimSubmit'),()=>redeemScanValue($('rewardClaimCode').value)).catch(()=>{});};
}
async function manualClaimSubmit(){const raw=$('scanManual').value.trim();await redeemScanValue(raw);}
async function openScanner(mode='claim'){
 showSheet(mode==='redeem'?'扫描兑奖凭证':'扫一扫，开启惊喜','SCAN CODE');
 sheetHtml(`<div class="sheet-content"><div class="scan-frame" id="cameraFrame"><div class="scan-placeholder"><span>▣</span>准备启动相机…</div></div><p class="scan-helper">可扫描 Yetipsy QR / CODE128 条形码。首次使用请允许相机访问。</p><div class="sheet-sep"></div><label for="scanManual">扫描不方便？输入奖励领取短码</label><input id="scanManual" placeholder="输入 8 位 Reward Claim 短码"/><button type="button" id="scanSubmit" class="button button-outline wide">确认领取 / 核销查询</button></div>`);
 $('scanSubmit').onclick=()=>pending($('scanSubmit'),async()=>{const raw=$('scanManual').value;if(!raw.trim())throw Error('请输入凭证');await stopScanner();await (mode==='redeem'?redeemScanValue(raw,'redeem'):previewClaim(raw));});
 if(!window.Html5Qrcode){try{await loadScript('https://cdn.jsdelivr.net/npm/html5-qrcode@2.3.8/html5-qrcode.min.js');}catch(e){$('cameraFrame').innerHTML='<div class="scan-placeholder"><span>▣</span>相机组件加载失败，请输入领取短码</div>';return;}}
 if($('sheetBackdrop').classList.contains('hide'))return;
 try{
  $('cameraFrame').replaceChildren();const element=document.createElement('div');element.id='ytScannerCamera';element.style.width='100%';$('cameraFrame').append(element);
  const formats=window.Html5QrcodeSupportedFormats;
  scanner=new window.Html5Qrcode('ytScannerCamera',{formatsToSupport:[formats.QR_CODE,formats.CODE_128],verbose:false});
  await scanner.start({facingMode:'environment'},{fps:10,qrbox:{width:Math.min(245,Math.max(155,innerWidth-110)),height:180}},async text=>{
   if(!scannerRunning)return;scannerRunning=false;await stopScanner();try{await (mode==='redeem'?redeemScanValue(text,'redeem'):previewClaim(text));}catch(e){toast(errorText(e),true);}
  });scannerRunning=true;
 }catch(e){$('cameraFrame').innerHTML='<div class="scan-placeholder"><span>▣</span>无法启动相机，请检查权限或使用粘贴方式</div>';scanner=null;scannerRunning=false;}
}
async function stopScanner(){if(!scanner)return;const live=scanner;scanner=null;try{await live.stop();}catch{}try{await live.clear();}catch{}scannerRunning=false;}
async function showSimpleSuccess(title,reward,sub){showSheet(title,'REWARD SAVED');sheetHtml(`<div class="sheet-content"><div class="game-arena"><div class="game-result-star">✳</div><div class="game-result-name">${esc(reward)}</div><div class="game-result-sub">${esc(sub)}</div></div><button id="successWallet" class="button button-primary wide">查看我的奖励 ↗</button></div>`);$('successWallet').onclick=()=>{closeSheet();navigate('wallet');};}

const symbols={'moon-dice':'⚄','mystery-card':'✦','mystery-box':'◈','reaction-test':'⚡','stop-the-bar':'◎'};
const titles={'moon-dice':['幸运骰子','SHAKE YOUR LUCK'],'mystery-card':['神秘翻牌','CHOOSE YOUR DESTINY'],'mystery-box':['神秘礼盒','UNBOX A SURPRISE'],'reaction-test':['反应挑战','BEAT YOUR REFLEX'],'stop-the-bar':['精准挑战','FIND THE PERFECT SPOT']};
const gameTips={
 'moon-dice':'亲手摇动五颗骰子，等待骰盅停下来，数数你摇出了多少颗「1」。',
 'mystery-card':'四张命运卡，只有一次选择机会。翻开属于你的今日签语。',
 'mystery-box':'从三份神秘礼盒中选一个，再亲手打开，看看藏着什么惊喜讯息。',
 'reaction-test':'挑战三回合反应力。等按钮变绿再点击，记录你的最佳反应时间。',
 'stop-the-bar':'三次机会，把移动的光标停在金色目标区，挑战最高精准度。'
};
let gameAudioOn=false, gameAudioCtx=null;
try{gameAudioOn=localStorage.getItem('yt-play-game-sound')==='on';}catch{}
function gameHaptic(ms=24){try{navigator.vibrate?.(ms);}catch{}}
function gameSound(kind='tap'){
 if(!gameAudioOn)return;
 try{
  const AC=window.AudioContext||window.webkitAudioContext;if(!AC)return;
  gameAudioCtx??=new AC();if(gameAudioCtx.state==='suspended')gameAudioCtx.resume().catch(()=>{});
  const notes=kind==='win'?[660,880,990]:kind==='tick'?[425]:kind==='stop'?[540,690]:[480,610];
  notes.forEach((freq,i)=>{const t=gameAudioCtx.currentTime+i*.105,osc=gameAudioCtx.createOscillator(),gain=gameAudioCtx.createGain();osc.type='sine';osc.frequency.setValueAtTime(freq,t);gain.gain.setValueAtTime(.0001,t);gain.gain.exponentialRampToValueAtTime(.055,t+.018);gain.gain.exponentialRampToValueAtTime(.0001,t+.18);osc.connect(gain).connect(gameAudioCtx.destination);osc.start(t);osc.stop(t+.19);});
 }catch{}
}
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function stageMeta(step='01',label='PLAY'){return `<div class="yt-play-top"><span class="yt-play-step">${esc(step)} / 03</span><span class="yt-play-kicker">${esc(label)}</span><button type="button" id="ytSoundToggle" class="yt-sound-toggle" aria-label="切换游戏音效">${gameAudioOn?'♪ 声音开':'♪ 静音'}</button></div>`;}
function attachSound(){const button=$('ytSoundToggle');if(!button)return;button.onclick=()=>{gameAudioOn=!gameAudioOn;try{localStorage.setItem('yt-play-game-sound',gameAudioOn?'on':'off');}catch{}button.textContent=gameAudioOn?'♪ 声音开':'♪ 静音';gameSound();};}
function arena(label,visual,foot=''){
 $('sheetBody').innerHTML=`<div class="sheet-content yt-play-content">${stageMeta('02','NOW PLAYING')}<div class="game-arena yt-premium-arena"><div class="yt-orbit yt-orbit-one"></div><div class="yt-orbit yt-orbit-two"></div><div class="arena-label">${esc(label)}</div><div id="gameVisual" class="yt-game-visual">${visual}</div><div class="game-foot" id="gameFoot" aria-live="polite">${esc(foot)}</div></div><p class="tiny-help yt-game-hint" id="gameProgress">互动结束后会先展示本局结果，奖品将在你点击揭晓后出现。</p></div>`;
 attachSound();return $('gameVisual');
}
function foot(text){const el=$('gameFoot');if(el)el.textContent=text;}
async function chooseGame(pass){
 await loadGames();const ids=unpack(await db.from('campaign_games').select('game_id').eq('campaign_id',pass.campaign_id)).map(x=>x.game_id);
 const available=state.games.filter(g=>ids.includes(g.id));if(!available.length)throw Error('该活动暂时没有开放的游戏');
 showSheet('选一场今晚的小游戏','ONE PASS · YOUR CHOICE');
 const root=document.createElement('div');root.className='sheet-content yt-game-selection';root.innerHTML='<div class="yt-selection-header"><div class="yt-mini-symbol">✳</div><h2>挑一个，玩出今晚的故事。</h2><p>每张 Game Pass 只有一次机会。预览玩法不会消耗机会，点击「正式开始」才使用。</p></div><div class="choice-grid yt-choice-grid" id="gameChoices"></div>';
 for(const g of available){const b=document.createElement('button');b.className='choice-card yt-choice-card';b.innerHTML=`<span class="yt-choice-number">${String(available.indexOf(g)+1).padStart(2,'0')}</span><span class="symbol">${symbols[g.slug]||'✦'}</span><strong>${esc(titles[g.slug]?.[0]||g.title)}</strong><small>${esc(titles[g.slug]?.[1]||'YETIPSY PLAY')}</small><p>${esc(gameTips[g.slug]||'开启一份属于你的惊喜。')}</p>`;b.onclick=()=>showGameIntro(pass,g);root.querySelector('#gameChoices').append(b);}
 $('sheetBody').append(root);
}
function showGameIntro(pass,g){
 showSheet(titles[g.slug]?.[0]||g.title,'READY TO PLAY');
 sheetHtml(`<div class="sheet-content yt-game-intro">${stageMeta('01','GET READY')}<div class="yt-intro-orb"><span>${symbols[g.slug]||'✦'}</span></div><div class="yt-eyebrow">${esc(titles[g.slug]?.[1]||'YETIPSY PLAY')}</div><h2>${esc(titles[g.slug]?.[0]||g.title)}</h2><p>${esc(gameTips[g.slug]||'开启你的小游戏体验。')}</p><div class="yt-rule-note">${esc(g.slug==='moon-dice'?'五颗骰子的「1」数量对应奖励档位；每种结果的出现概率由本游戏独立设置。': '本游戏奖品从自己的独立奖池随机抽取。技巧型游戏的成绩只用于排行榜，不改变中奖概率。')} 完成后先展示本局结果，再亲手揭晓奖励。</div><div id="ytDynamicRules" class="yt-game-prize-map"><span>正在加载本游戏可获得的奖励…</span></div><button id="ytStartActualGame" type="button" class="button button-primary wide yt-primary-action">正式开始 <span>↗</span></button><button id="ytGameBoard" type="button" class="button button-outline wide">查看这款游戏的排行榜 ↗</button><button id="ytBackToGames" type="button" class="button button-outline wide">换一个游戏</button></div>`);
 attachSound();loadGameRules(pass,g).catch(e=>{const el=$('ytDynamicRules');if(el)el.textContent='规则正在更新，请从「奖品与玩法」查看。';});$('ytStartActualGame').onclick=e=>pending(e.currentTarget,()=>startGame(pass,g)).catch(()=>{});$('ytBackToGames').onclick=()=>chooseGame(pass).catch(e=>toast(errorText(e),true));$('ytGameBoard').onclick=()=>showLeaderboard(g.slug).catch(e=>toast(errorText(e),true));
}
function diceElement(n){const patterns={1:[5],2:[1,9],3:[1,5,9],4:[1,3,7,9],5:[1,3,5,7,9],6:[1,3,4,6,7,9]};return `<div class="dice-cube">${(patterns[n]||[]).map(i=>`<i class="pip p${i}"></i>`).join('')}</div>`;}
function diceResult(tier,seed=''){
 // Repeating the same server session gives the same five faces; prize tier remains server-authoritative.
 let value=2166136261;for(const c of String(seed)+':'+tier){value=Math.imul(value^c.charCodeAt(0),16777619)>>>0;}
 const rand=()=>{value=(Math.imul(value,1664525)+1013904223)>>>0;return value/4294967296;};
 const n=tier==='R5'?5:tier==='R4'?4:tier==='R3'?3:Math.floor(rand()*3);
 const a=Array(n).fill(1);while(a.length<5)a.push(2+Math.floor(rand()*5));for(let i=a.length-1;i>0;i--){const j=Math.floor(rand()*(i+1));[a[i],a[j]]=[a[j],a[i]];}return a;
}
function actionOnce(node,callback,timeout=50000){return new Promise(resolve=>{
 let settled=false;const timer=setTimeout(()=>end(true),timeout);
 function end(automatic=false){if(settled)return;settled=true;clearTimeout(timer);node.disabled=true;resolve(callback(automatic));}
 node.onclick=()=>{gameHaptic();gameSound('tap');end(false);};
});}
async function playDice(tier,sessionId){
 const faces=diceResult(tier,sessionId);
 const v=arena('MOON DICE · 五颗幸运骰子',`<div class="yt-dice-shaker"><div class="yt-shaker-shine"></div><span>YE·TIPSY</span><small>GOOD LUCK</small></div><div class="yt-dice-surface" id="ytDiceSurface"><div class="dice-collection">${[1,2,3,4,5].map(diceElement).join('')}</div></div><button type="button" id="ytShake" class="button button-primary wide yt-play-main-button">摇动骰盅 <span>⚄</span></button>`,'轻点骰盅，摇出属于你的数字');
 const shaker=v.querySelector('.yt-dice-shaker'),button=v.querySelector('#ytShake');
 await actionOnce(button,()=>null);button.textContent='正在摇骰…';shaker.classList.add('is-shaking');v.querySelectorAll('.dice-cube').forEach((d,i)=>{d.classList.add('spin');d.style.animationDelay=(i*75)+'ms';});
 foot('骰子正在滚动…');await sleep(1800);shaker.classList.add('is-lifted');await sleep(650);
 const row=v.querySelector('.dice-collection');row.innerHTML=faces.map(diceElement).join('');row.classList.add('yt-dice-landed');
 const count=faces.filter(n=>n===1).length;foot(`摇出 ${count} 颗「1」 · 已记录本局点数`);gameHaptic(50);gameSound('stop');await sleep(950);
 return {headline:`${count} 颗「1」`,kicker:'LUCKY DICE RESULT',detail:`五颗骰子已停稳 · ${count} / 5 颗「1」`,visual:`<div class="yt-result-dice">${faces.map(diceElement).join('')}</div>`,rule:'每颗骰子的结果对应公开的奖励档位，中奖概率只由本游戏的独立奖池决定。',score:count};
}
const cardFortunes=['好运，是你敢选的那一刻。','今晚，惊喜留给勇敢的你。','一张好牌，送给此刻的你。','缘分已经为你翻开一页。'];
async function playPick(isCard){
 const count=isCard?4:3;
 const markup=Array.from({length:count},(_,i)=>isCard?`<button class="foil-card yt-pick-card" data-pick="${i}" aria-label="选择第${i+1}张牌"><span>✳</span><small>YETIPSY</small><em>0${i+1}</em></button>`:`<button class="gift-box yt-pick-box" data-pick="${i}" aria-label="选择第${i+1}个礼盒"><span>✦</span><em>0${i+1}</em></button>`).join('');
 const v=arena(isCard?'MYSTERY CARD · 命运翻牌':'MYSTERY BOX · 惊喜盲盒',`<div class="yt-pick-intro">${isCard?'你会选中哪一张命运牌？':'挑选今晚属于你的神秘礼盒。'}</div><div class="game-picks yt-game-picks">${markup}</div><div id="ytPickSignature" class="yt-pick-signature"></div>`,'只有一次选择 · 点击其中一个');
 const buttons=[...v.querySelectorAll('[data-pick]')];
 const selected=await new Promise(resolve=>{
  let done=false;const timeout=setTimeout(()=>onPick(Math.floor(Math.random()*count),true),50000);
  function onPick(n,auto=false){if(done)return;done=true;clearTimeout(timeout);buttons.forEach((b,i)=>{b.disabled=true;if(i===n)b.classList.add('selected');else b.classList.add('dimmed');});foot(auto?'已为你自动打开一个选择':'你的选择已经锁定');gameHaptic(40);gameSound('tick');resolve(n);}
  buttons.forEach((b,i)=>b.onclick=()=>onPick(i));
 });
 await sleep(600);
 const selectedButton=buttons[selected];
 if(isCard){selectedButton.classList.add('yt-flipped');v.querySelector('#ytPickSignature').innerHTML=`<span>✳</span><b>${esc(cardFortunes[selected])}</b>`;foot('命运卡片已翻开 · 解读今日签语');}
 else {selectedButton.classList.add('yt-open-box');v.querySelector('#ytPickSignature').innerHTML='<span>✧</span><b>一份惊喜，已经被你唤醒。</b>';foot('礼盒开启 · 星光已经点亮');}
 await sleep(1500);
 const signature=isCard?cardFortunes[selected]:'礼盒已开启，惊喜等待你拆封。';
 return {headline:isCard?`第 ${selected+1} 张 · 命运卡`:`第 ${selected+1} 号 · 神秘礼盒`,kicker:isCard?'YOUR FORTUNE CARD':'YOUR MYSTERY BOX',detail:signature,visual:`<div class="yt-result-symbol">${isCard?'✳':'✧'}</div><span class="yt-result-serial">0${selected+1} / 0${count}</span>`,rule:'选号和签语是游戏互动，奖励在本游戏独立奖池中随机抽出。幸运等级作为个人纪录。',score:null};
}
async function reactionRound(v,round){
 const button=v.querySelector('#reactionTap');const roundEl=v.querySelector('#ytReactionRound');roundEl.textContent=`ROUND ${round} / 3`;button.classList.remove('go','too-soon','yt-result-tapped');button.disabled=false;button.textContent='WAIT…';foot(`第 ${round} 回合 · 变绿才点击`);
 return await new Promise(resolve=>{
  let done=false,greenAt=0;
  const timer=setTimeout(()=>{if(done)return;greenAt=performance.now();button.classList.add('go');button.textContent='TAP NOW!';gameSound('tick');},1050+Math.random()*1550);
  const expire=setTimeout(()=>finish(null,'TIME OUT'),7800);
  function finish(value,label){if(done)return;done=true;clearTimeout(timer);clearTimeout(expire);button.disabled=true;button.classList.add('yt-result-tapped');button.textContent=label;foot(label==='FALSE START'?'抢跑！下一回合再试':label==='TIME OUT'?'超时！下一回合再试':`本回合反应 ${value} ms`);gameHaptic(30);gameSound('stop');resolve(value);}
  button.onclick=()=>greenAt?finish(Math.max(1,Math.round(performance.now()-greenAt)),`${Math.round(performance.now()-greenAt)} ms`):finish(null,'FALSE START');
 });
}
async function playReaction(){
 const v=arena('REACTION LAB · 三回合',`<div id="ytReactionRound" class="yt-round-count">READY / 3</div><div class="yt-reaction-ring"><button id="reactionTap" class="reaction-button" type="button" disabled>READY?</button></div><div class="yt-round-history" id="ytReactionScores"><span>01 —</span><span>02 —</span><span>03 —</span></div><button id="ytBeginReaction" class="button button-primary wide yt-play-main-button">开始挑战</button>`,'三回合中取最佳成绩 · 按钮变绿才点击');
 await actionOnce(v.querySelector('#ytBeginReaction'),()=>null);v.querySelector('#ytBeginReaction').remove();const results=[];
 for(let i=1;i<=3;i++){const score=await reactionRound(v,i);results.push(score);v.querySelector('#ytReactionScores').children[i-1].textContent=`0${i} ${score==null?'—':score+'ms'}`;if(i<3)await sleep(1100);}
 const valid=results.filter(x=>x!==null),best=valid.length?Math.min(...valid):null;
 return {headline:best===null?'挑战完成':`${best} ms`,kicker:'YOUR BEST REACTION',detail:best===null?'三回合完成 · 继续练习会更准':best<=220?'极限反应，漂亮！':best<=380?'出手很快，继续保持！':'稳稳发挥，完成三回合。',visual:`<div class="yt-result-ranks">${results.map((s,i)=>`<div><span>ROUND 0${i+1}</span><strong>${s==null?'—':s+' ms'}</strong></div>`).join('')}</div>`,rule:'反应时间仅用于个人最佳纪录与娱乐排行榜；实际奖励由服务器随机抽取，与速度无关。',score:best};
}
async function stopRound(v,round){
 const track=v.querySelector('.bar-track'),marker=v.querySelector('.bar-marker'),btn=v.querySelector('#stopBtn');
 v.querySelector('#ytBarRound').textContent=`ROUND ${round} / 3`;foot(`第 ${round} 回合 · 在中央金色区按 STOP`);
 btn.disabled=false;btn.textContent=`STOP · 第 ${round} 次`;marker.style.left='0%';
 const start=performance.now();let raf=0,position=0,done=false;return await new Promise(resolve=>{
  function tick(now){if(done)return;const phase=((now-start)/(1550-(round-1)*230))%2;position=phase<=1?phase:2-phase;marker.style.left=`${position*100}%`;raf=requestAnimationFrame(tick);}
  function finish(){if(done)return;done=true;cancelAnimationFrame(raf);clearTimeout(timeout);btn.disabled=true;const score=Math.max(0,Math.round((1-Math.abs(.5-position)*2)*100));btn.textContent=`${score}% ACCURACY`;foot(`第 ${round} 回合 · 精准度 ${score}%`);track.classList.toggle('yt-perfect',score>=90);gameHaptic(35);gameSound('stop');resolve(score);}
  raf=requestAnimationFrame(tick);btn.onclick=finish;const timeout=setTimeout(finish,6500);
 });
}
async function playStopBar(){
 const v=arena('STOP THE BAR · 三回合',`<div class="yt-round-count" id="ytBarRound">READY / 3</div><div class="yt-bar-container"><div class="bar-track"><div class="bar-target"></div><div class="bar-marker" id="marker"></div></div><div class="yt-bar-ticks"><span>0</span><span>PERFECT</span><span>100</span></div></div><button class="button button-primary wide yt-play-main-button" id="stopBtn" type="button" disabled>READY</button><button class="button button-outline wide" id="ytBeginBar">开始三次挑战</button><div class="yt-round-history" id="ytBarScores"><span>01 —</span><span>02 —</span><span>03 —</span></div>`,'按 STOP 停在中央金色目标区');
 await actionOnce(v.querySelector('#ytBeginBar'),()=>null);v.querySelector('#ytBeginBar').remove();const scores=[];
 for(let i=1;i<=3;i++){const s=await stopRound(v,i);scores.push(s);v.querySelector('#ytBarScores').children[i-1].textContent=`0${i} ${s}%`;if(i<3){await sleep(1050);v.querySelector('.bar-track').classList.remove('yt-perfect');}}
 const best=Math.max(...scores);
 return {headline:`${best}%`,kicker:'BEST ACCURACY',detail:best>=95?'PERFECT STOP！稳得漂亮。':best>=75?'离中心非常接近！':'三次挑战完成，下次再来刷新记录。',visual:`<div class="yt-result-ranks">${scores.map((s,i)=>`<div><span>ROUND 0${i+1}</span><strong>${s}%</strong></div>`).join('')}</div>`,rule:'精准度仅用于个人最佳纪录与娱乐排行榜；实际奖励由服务器随机抽取，与精准度无关。',score:best};
}

const rankSlugs=['moon-dice','mystery-card','mystery-box','reaction-test','stop-the-bar'];
const gameNames={'moon-dice':'幸运骰子','mystery-card':'神秘翻牌','mystery-box':'神秘礼盒','reaction-test':'反应挑战','stop-the-bar':'精准挑战'};
const diceLabels={R5:'5 颗「1」',R4:'4 颗「1」',R3:'3 颗「1」',R0:'0–2 颗「1」'};
const fortuneLabels={R5:'幸运等级 ★★★★★',R4:'幸运等级 ★★★★',R3:'幸运等级 ★★★',R0:'幸运等级 ★'};
const rankNumber=(slug,score)=>score==null?'—':slug==='reaction-test'?`${Number(score)} ms`:slug==='stop-the-bar'?`${Number(score)}%`:slug==='moon-dice'?`${Number(score)} 颗「1」`:`${Number(score)} ★`;
function personalResultLine(slug,row){const best=rankNumber(slug,row.personal_best);const rank=row.personal_rank?' · 当前第 '+row.personal_rank+' 名':'';return '你的历史最佳：'+best+' · 已玩 '+Number(row.played_count||0)+' 次'+rank;}
function updateGameRecordMessage(slug,row){
 const el=$('ytResultRecord');if(!el)return;
 if(['mystery-card','mystery-box'].includes(slug))return; // Don't reveal reward tier early.
 el.classList.remove('hide');el.textContent=personalResultLine(slug,row);
}
async function loadGameRules(pass,game){
 const data=await pinRequest('rules','','','',{campaign_id:pass.campaign_id,slug:game.slug});
 const el=$('ytDynamicRules');if(!el||!el.isConnected)return;
 const rows=data.rules||[];el.replaceChildren();
 const title=document.createElement('strong');title.textContent=game.slug==='moon-dice'?'骰子结果与奖励':'本游戏可能获得的奖励';el.append(title);
 if(!rows.length){const p=document.createElement('p');p.textContent='目前没有可领取的奖励，请联系员工。';el.append(p);return;}
 const groups=new Map();for(const r of rows){const key=game.slug==='moon-dice'?r.result_key:r.reward_name;if(!groups.has(key))groups.set(key,[]);groups.get(key).push(r);}
 for(const [key,list] of groups){const row=document.createElement('div');row.className='yt-game-rule-row';const label=document.createElement('span');label.textContent=game.slug==='moon-dice'?(diceLabels[key]||'本期奖励'):'✧';const reward=document.createElement('b');reward.textContent=list.map(x=>x.reward_name).join(' / ');row.append(label,reward);el.append(row);}
 const foot=document.createElement('p');foot.className='tiny-help';foot.textContent=game.slug==='moon-dice'?'每个结果档位的出现权重由 Owner 为幸运骰子单独设置；此处不公开概率。':'本游戏独立随机抽奖，成绩只用于最佳纪录与娱乐排行榜，不保证对应奖品。';el.append(foot);
}
async function showMyRecords(){
 if(!state.user)return toast('请登录会员后查看历史纪录',true);
 showSheet('我的最佳纪录','PERSONAL BESTS');sheetHtml('<div class="sheet-content yt-rank-shell"><div id="ytMyRecordRows" class="yt-rank-rows">正在加载你的纪录…</div><button type="button" id="ytOpenBoardFromRecords" class="button button-primary wide">打开排行榜 ↗</button><div id="ytRankConsent"></div><p class="tiny-help">技巧成绩为娱乐纪录，不能作为奖品兑换条件。排行榜昵称默认隐藏。</p></div>');
 $('ytOpenBoardFromRecords').onclick=()=>showLeaderboard().catch(e=>toast(errorText(e),true));
 const records=await db.rpc('yt_my_game_records');
 const items=unpack(records)||[];const box=$('ytMyRecordRows');if(!box)return;box.replaceChildren();
 for(const slug of rankSlugs){const r=items.find(x=>x.game_slug===slug);const row=document.createElement('div');row.className='yt-rank-item';row.innerHTML=`<div><strong>${esc(gameNames[slug])}</strong><small>${r?.played_count?'已玩 '+Number(r.played_count)+' 次'+(r.personal_rank?' · 第 '+r.personal_rank+' 名':''):'暂无纪录'}</small></div><b>${esc(rankNumber(slug,r?.best_score))}</b>`;box.append(row);}
 await renderRankPreference(items);
}
async function renderRankPreference(items=null){
 const wrapper=$('ytRankConsent');if(!wrapper)return;
 const r=items??(unpack(await db.rpc('yt_my_game_records'))||[]);
 const visible=!!r.some(x=>x.nickname_visible===true);
 wrapper.innerHTML=`<label class="yt-rank-consent"><input id="ytRankShowName" type="checkbox" ${visible?'checked':''}/> 在排行榜显示我的会员昵称</label><p class="tiny-help">不勾选时，排行榜显示「神秘玩家」；不会显示手机号或生日。</p>`;
 const cb=$('ytRankShowName');cb.onchange=async()=>{cb.disabled=true;try{unpack(await db.rpc('yt_set_leaderboard_nickname',{p_visible:cb.checked}));toast(cb.checked?'已允许展示昵称':'已切换成匿名上榜');}catch(e){cb.checked=!cb.checked;toast(errorText(e),true);}finally{cb.disabled=false;}};
}
async function showLeaderboard(selected='moon-dice'){
 if(!state.user)return toast('请登录会员后查看排行榜',true);
 showSheet('游戏排行榜','YETIPSY · HALL OF FAME');
 sheetHtml('<div class="sheet-content yt-rank-shell"><p class="yt-rank-headline">每款游戏独立排行 · 记录历史最佳成绩</p><div id="ytRankTabs" class="yt-rank-tabs"></div><div id="ytBoardIntro" class="yt-rank-subtitle"></div><div id="ytBoardRows" class="yt-rank-rows"></div><button id="ytBoardMyRecords" type="button" class="button button-outline wide">查看我的最佳纪录 ↗</button><p class="tiny-help">幸运游戏按最好的一次结果排名；反应挑战越快越好，精准挑战越高越好。技巧分数是手机端娱乐成绩，不决定奖品，且尚未具备防作弊认证。</p></div>');
 $('ytBoardMyRecords').onclick=()=>showMyRecords().catch(e=>toast(errorText(e),true));
 const tabs=$('ytRankTabs');for(const slug of rankSlugs){const btn=document.createElement('button');btn.type='button';btn.className='yt-rank-tab';btn.dataset.slug=slug;btn.textContent=gameNames[slug];btn.onclick=()=>loadLeaderboard(slug);tabs.append(btn);}
 await loadLeaderboard(rankSlugs.includes(selected)?selected:'moon-dice');
}
async function loadLeaderboard(slug){
 for(const btn of document.querySelectorAll('#ytRankTabs button'))btn.classList.toggle('active',btn.dataset.slug===slug);
 const box=$('ytBoardRows'),intro=$('ytBoardIntro');if(!box||!intro)return;
 box.textContent='正在加载排行榜…';intro.textContent='TOP 20 · '+gameNames[slug];
 try{
 const items=unpack(await db.rpc('yt_game_leaderboard',{p_slug:slug,p_limit:20}))||[];
 if(!box.isConnected)return;box.replaceChildren();
 if(!items.length){box.innerHTML='<div class="yt-rank-empty">还没有玩家留下纪录。第一名，等你来！</div>';return;}
 for(const row of items){const item=document.createElement('div');item.className='yt-rank-item'+(row.is_me?' self':'');item.innerHTML=`<span class="yt-rank-position">${row.rank_no<=3?['🥇','🥈','🥉'][row.rank_no-1]:String(row.rank_no).padStart(2,'0')}</span><div><strong>${esc(row.display_name)}</strong><small>已玩 ${Number(row.played_count)} 次${row.is_me?' · 这是你':''}</small></div><b>${esc(rankNumber(slug,row.best_score))}</b>`;box.append(item);}
 }catch(e){if(box?.isConnected)box.textContent='排行榜暂时加载失败：'+errorText(e);}
}
function fireworks(){const wrap=document.createElement('div');wrap.className='game-confetti yt-silk-confetti';for(let i=0;i<34;i++){const dot=document.createElement('i');dot.style.left=(Math.random()*100)+'%';dot.style.animationDelay=(Math.random()*.55)+'s';dot.style.background=i%4===0?'#fff4d5':i%3?'#e3c190':'#a88650';wrap.append(dot);}return wrap;}
function showGameResult(game,result){
 showSheet('你的本局成绩','YOUR GAME RESULT');
 const name=titles[game.slug]?.[0]||game.title;
 sheetHtml(`<div class="sheet-content yt-result-page">${stageMeta('03','RESULT RECORDED')}<div class="yt-result-top"><span>${esc(symbols[game.slug]||'✦')} ${esc(name)}</span><span>COMPLETE ✓</span></div><div class="yt-result-stage"><div class="yt-result-halo"></div><div class="yt-eyebrow">${esc(result.kicker)}</div><div class="yt-result-big" id="ytResultBig">${esc(result.headline)}</div><div class="yt-result-caption">${esc(result.detail)}</div><div class="yt-result-visual">${result.visual}</div></div><div class="yt-result-rule">${esc(result.rule||'游戏结果已记录，奖励由服务器安全结算。')}</div><div id="ytResultRecord" class="yt-record-badge hide"></div><div class="yt-sealed-prize"><span class="yt-seal-icon">✧</span><div><strong>还有一份奖励，等你亲手打开。</strong><small>YOUR SECRET REWARD IS READY</small></div></div><button id="ytOpenResultReward" class="button button-primary wide yt-reveal-button" type="button" disabled>正在保存本局结果…</button><p id="ytResultSaveState" class="tiny-help yt-result-save" role="status" aria-live="polite">奖品名称暂时保密，保存成功后可点击揭晓。</p></div>`);
 attachSound();const big=$('ytResultBig');if(big){big.classList.add('yt-number-appear');}return $('ytOpenResultReward');
}
async function showGameWon(name,record=null,slug=null){
 showSheet('奖品已解锁','YETIPSY · SURPRISE REVEAL');
 sheetHtml(`<div class="sheet-content yt-reward-open"><div class="yt-reward-crown">✳</div><div class="yt-eyebrow">YOU GOT A REWARD</div><div class="yt-reward-gift" id="ytRevealGift"><span class="yt-reward-ray"></span><span class="yt-reward-burst">✧</span><b class="yt-reward-heading">恭喜你，今晚有好事发生。</b><div class="yt-reward-name">${esc(name)}</div><p>已自动存入你的会员奖励钱包</p></div><div id="ytRewardRecord" class="yt-record-badge hide"></div><button id="goWalletFromGame" class="button button-primary wide">打开我的奖励钱包 ↗</button><button id="ytRewardBoard" class="button button-outline wide hide">查看游戏排行榜 ↗</button><p class="tiny-help">请以钱包显示的开始与截止日期为准；到店出示动态 QR 即可核销。</p></div>`);
 const gift=$('ytRevealGift');requestAnimationFrame(()=>{gift.classList.add('yt-reward-revealed');gift.append(fireworks());});gameSound('win');gameHaptic([40,70,70]);
 $('goWalletFromGame').onclick=()=>{closeSheet();navigate('wallet');};if(record&&slug){const label=$('ytRewardRecord');label.classList.remove('hide');label.textContent=personalResultLine(slug,record);const board=$('ytRewardBoard');board.classList.remove('hide');board.onclick=()=>showLeaderboard(slug).catch(e=>toast(errorText(e),true));}
}
async function startGame(pass,g){
 if(state.gamePlaying)throw Error('游戏进行中，请勿重复点击');
 state.gamePlaying=true;let session=null,localResult=null,startedAt=0,unlocked=false;
 try{
  const rows=unpack(await db.rpc('yt_start_game',{p_pass:pass.id,p_game:g.id}));if(!rows?.length)throw Error('无法开启游戏');
  session=rows[0];state.activeSession=session;startedAt=performance.now();
  showSheet(titles[g.slug]?.[0]||g.title,'LET THE GAME BEGIN');
  if(g.slug==='moon-dice')localResult=await playDice(session.result_key,session.session_id);
  else if(g.slug==='mystery-card')localResult=await playPick(true);
  else if(g.slug==='mystery-box')localResult=await playPick(false);
  else if(g.slug==='reaction-test')localResult=await playReaction();
  else if(g.slug==='stop-the-bar')localResult=await playStopBar();
  else throw Error('游戏暂时不可用');
  const revealButton=showGameResult(g,localResult);
  // A game pass is consumed only once, after the server confirms settlement.
  // A visible result always precedes the prize reveal; no automatic winner popup.
  const settle=async()=>{
   if(unlocked)return;
   const wait=2050-(performance.now()-startedAt);if(wait>0)await sleep(wait);
   const rowsDone=unpack(await db.rpc('yt_finish_game_ranked',{p_session:session.session_id,p_score:localResult.score}));if(!rowsDone?.length)throw Error('奖品与成绩尚未成功存档');
   const record=rowsDone[0],awarded=record.reward_name||'Yetipsy Reward';unlocked=true;state.activeSession=null;
   const currentToast=$('toast');if(currentToast){currentToast.classList.remove('show');clearTimeout(toast.timer);}
   try{await Promise.all([wallet(true),refreshPasses()]);}catch(e){console.warn('Wallet refresh delayed',e);}
   const btn=$('ytOpenResultReward');if(btn){btn.disabled=false;btn.innerHTML='亲手拆开奖励 <span>↗</span>';btn.onclick=()=>showGameWon(awarded,record,g.slug).catch(e=>toast(errorText(e),true));}updateGameRecordMessage(g.slug,record);
   const status=$('ytResultSaveState');if(status)status.textContent='✓ 本局已结算并存入你的奖励钱包。点击按钮，揭晓今晚的惊喜。';
  };
  try{await settle();}catch(e){
   const btn=$('ytOpenResultReward');if(btn){btn.disabled=false;btn.textContent='重新保存并继续揭晓 ↻';btn.onclick=()=>pending(btn,settle).catch(e=>toast(errorText(e),true));}
   const status=$('ytResultSaveState');if(status)status.textContent='连接中断，本局结果已记录。点击重新保存，系统不会重复发奖。';
   toast(errorText(e),true);
  }
 }catch(e){
  if(session){showSheet('网络连接不稳定','RESUME PLAY');sheetHtml('<div class="sheet-content"><p>这张 Game Pass 的游戏会话已经保存在服务器。请稍等片刻，再确认领奖；重复请求不会重复发奖。</p><button id="resumeGame" class="button button-primary wide">恢复并确认奖励</button></div>');$('resumeGame').onclick=()=>pending($('resumeGame'),async()=>{const done=unpack(await db.rpc('yt_finish_game',{p_session:session.session_id}));if(!done?.length)throw Error('还无法结算，请稍后重试');state.activeSession=null;try{await Promise.all([wallet(true),refreshPasses()]);}catch{}await showGameWon(done[0].reward_name);}).catch(()=>{});}
  throw e;
 }finally{state.gamePlaying=false;}
}


async function loadMyLoyalty(){
 if(!state.user)return;
 try{state.loyalty=unpack(await db.rpc('yt_loyalty_member_summary'));renderMyLoyalty();}
 catch(e){console.warn('Loyalty temporarily unavailable:',errorText(e));}
}
function renderMyLoyalty(){
 const l=state.loyalty;if(!l)return;
 const cards=['ytLoyaltyWallet'];
 for(const id of cards){const target=$(id);if(!target)continue;target.classList.remove('hide');target.replaceChildren();
  const h=document.createElement('div');h.className='yt-loyalty-head';h.innerHTML='<strong>MY REWARDS CLUB</strong><span>会员积分 · 好友推荐</span>';target.append(h);
  const p=document.createElement('div');p.className='yt-loyalty-points';p.innerHTML='<span>可用积分</span><b>'+Number(l.points_balance||0).toLocaleString('en-MY')+' P</b>';
  target.append(p);
  const row=document.createElement('div');row.className='yt-loyalty-code';
  const label=document.createElement('span');label.textContent='我的好友码';row.append(label);
  const code=document.createElement('b');code.textContent=l.referral_code||'—';row.append(code);target.append(row);
  const desc=document.createElement('p');desc.className='tiny-help';desc.textContent=l.referral_enabled?'邀请好友注册可领取活动好礼；实际奖励与兑换规则以活动设置为准。':'好友推荐活动尚未开放，好友码已经为你保留。';target.append(desc);
  if(l.referral_enabled){const b=document.createElement('button');b.type='button';b.className='button button-outline wide';b.textContent='复制我的好友邀请链接 ↗';b.onclick=()=>{const u=new URL('./',location.href);u.search='';u.searchParams.set('invite',l.referral_code);copy(u.href);};target.append(b);}
  if(id==='ytLoyaltyWallet'){
    const history=document.createElement('div');history.className='yt-loyalty-history';const hh=document.createElement('strong');hh.textContent='最近积分记录';history.append(hh);
    const items=l.points_history||[];
    if(!items.length){const e=document.createElement('p');e.className='tiny-help';e.textContent='目前尚未获得积分。';history.append(e);}
    for(const item of items.slice(0,15)){const line=document.createElement('p');line.textContent=(item.direction==='earn'?'+':'−')+Number(item.points).toLocaleString('en-MY')+' P · '+fmt(item.created_at);history.append(line);}
    target.append(history);
  }
 }
}
async function choosePassReward(pass){
 if(!state.user)throw Error('请先登录会员账号');
 if(!pass||pass.status!=='claimed')throw Error('这张 Game Pass 已失效或使用过');
 let quote=null;
 try{quote=unpack(await db.rpc('yt_point_pass_quote',{p_pass:pass.id}));}catch(e){console.warn('Points quote unavailable',e);}
 if(!quote?.eligible){return chooseGame(pass);}
 showSheet('今晚选哪一种？','GAME OR POINTS · ONE CHOICE');
 sheetHtml('<div class="sheet-content yt-loyalty-choice"><h2>一张 Game Pass，一次惊喜。</h2><p>你的有效消费 RM '+Number(quote.spend_amount_rm||0).toFixed(2)+'，可以选择玩游戏领取随机奖品，或直接抽取积分。</p><div class="yt-choice-cap">本次积分上限：<b>'+Number(quote.max_points).toLocaleString('en-MY')+' P</b><small>按 Owner 设定的最高 '+Number(quote.max_percent)+'% 价值上限计算。实际随机获得的积分可能较少。</small></div><button id="ytChooseGame" type="button" class="button button-primary wide">玩小游戏 · 抽奖品 ↗</button><button id="ytChoosePoints" type="button" class="button button-outline wide">不玩游戏 · 随机领积分 ↗</button><p class="tiny-help">只能选择一次，选择积分后不可再玩游戏；积分暂不支持兑换或购物。</p></div>');
 $('ytChooseGame').onclick=()=>pending($('ytChooseGame'),()=>chooseGame(pass)).catch(()=>{});
 $('ytChoosePoints').onclick=()=>pending($('ytChoosePoints'),async()=>{
  if(!confirm('确认用这次 Game Pass 兑换随机积分？确认后将不能再玩游戏。'))return;
  const result=unpack(await db.rpc('yt_claim_random_points',{p_pass:pass.id}));
  if(!result?.length)throw Error('积分暂时无法入账，请稍后再试');
  await refreshPasses();await loadMyLoyalty();
  showSheet('积分已经到账','POINTS SAVED');
  sheetHtml('<div class="sheet-content"><div class="game-arena"><span class="game-result-star">✳</span><div class="game-result-name">+'+Number(result[0].points_awarded).toLocaleString('en-MY')+' POINTS</div><div class="game-result-sub">本次最高 '+Number(result[0].limit_points)+' P · 当前余额 '+Number(result[0].new_balance).toLocaleString('en-MY')+' P</div></div><button id="ytPointsWallet" class="button button-primary wide" type="button">查看我的积分钱包 ↗</button></div>');
  $('ytPointsWallet').onclick=()=>{closeSheet();navigate('wallet');};
 }).catch(()=>{});
}

async function existingGamePass(){await refreshPasses();const p=state.passes.find(p=>p.status==='claimed'&&millis(p.expires_at)>Date.now());if(!p)throw Error('还没有游戏机会，请先扫描员工二维码');await choosePassReward(p);}
async function prizeBoard(){
  // This public endpoint returns only titles,玩法 and award terms; not prize weights or odds.
  const response=await pinRequest('prizes');
  const board=response.prizes||[];
  state.board=board;
  showSheet('奖品与玩法','PRIZES & HOW TO PLAY');
  if(!board.length){sheetHtml('<div class="empty-state">当前暂无开放的活动奖品。</div>');return;}
  const groups=new Map();
  for(const row of board){
    const key=row.campaign_name+' · '+row.game_slug;
    if(!groups.has(key))groups.set(key,[]);
    groups.get(key).push(row);
  }
  const root=document.createElement('div');root.className='sheet-content';
  const intro=document.createElement('p');intro.textContent='本页仅介绍游戏玩法、可获得的奖品和兑换规则。实际发奖结果以服务器结算及会员钱包为准。';root.append(intro);
  for(const rows of groups.values()){
    const group=rows[0],box=document.createElement('div');box.className='prize-group';
    const title=document.createElement('div');title.className='prize-head';
    const game=document.createElement('b');game.textContent=group.game_title;
    const event=document.createElement('span');event.textContent=group.campaign_name;
    title.append(game,event);box.append(title);
    const how=document.createElement('p');how.className='soft-text';how.textContent='怎么玩：'+(group.how_to_play||'领取 Game Pass 后参与游戏，完成后奖励自动存入钱包。');box.append(how);
    const list=document.createElement('div');
    for(const reward of rows){
      const line=document.createElement('div');line.className='prize-row';
      const content=document.createElement('div');
      const name=document.createElement('strong');name.textContent=reward.reward_name;
      const details=document.createElement('small');details.textContent=[reward.description,reward.redeem_rules].filter(Boolean).join(' · ')||'兑换规则以奖励详情为准';
      content.append(name,details);line.append(content);list.append(line);
    }
    box.append(list);root.append(box);
  }
  const notice=document.createElement('p');notice.className='soft-text';notice.textContent='奖品及玩法以活动当时公布的规则为准；奖励的可用日期与有效期请查看钱包。';root.append(notice);
  $('sheetBody').append(root);
}

function openWorkspace(which){if(which==='owner'&&!isOwner())return toast('没有 Owner 权限',true);if(which==='staff'&&!isStaff())return toast('没有 Staff 权限',true);
 $('mainView').classList.add('hide');$('authView').classList.add('hide');$('workspaceView').classList.remove('hide');$('workspaceHeading').textContent=which==='owner'?'Owner 工作台':'员工工作台';$('workspaceOverline').textContent=which==='owner'?'OWNER CONSOLE':'STAFF OPERATIONS';$('workChip').textContent=which.toUpperCase();$('staffTools').classList.toggle('hide',which!=='staff');$('ownerTools').classList.toggle('hide',which!=='owner');window.scrollTo(0,0);
 if(which==='staff')loadStaffCampaigns().catch(e=>toast(errorText(e),true));else loadOwner().catch(e=>toast(errorText(e),true));}
function showStaffRedeem(){$('staffRedeemPanel').classList.remove('hide');$('staffGeneratePanel').classList.add('hide');$('staffResetPanel').classList.add('hide');}
function showStaffGenerate(){$('staffGeneratePanel').classList.remove('hide');$('staffRedeemPanel').classList.add('hide');$('staffResetPanel').classList.add('hide');}
function showStaffReset(){$('staffResetPanel').classList.remove('hide');$('staffRedeemPanel').classList.add('hide');$('staffGeneratePanel').classList.add('hide');}
async function loadStaffCampaigns(){const rows=unpack(await db.from('campaigns').select('id,name,starts_at,ends_at,active').eq('active',true));const c=$('staffCampaign');c.replaceChildren();for(const r of rows)c.add(new Option(r.name,r.id));if(!rows.length)toast('目前还没有开放的活动',true);}
async function staffIssuePass(){const campaign=$('staffCampaign').value;if(!campaign)throw Error('请先在 Owner 开放一个活动');const mins=Number($('staffExpiry').value);if(!Number.isInteger(mins)||mins<1||mins>60)throw Error('有效分钟必须为 1–60');const op='game-pass:'+campaign+':'+mins;let saved=null;try{saved=JSON.parse(requestStore.get('v11:pair:'+op)||'null')}catch{}
 if(!saved){saved={raw:uuid(),req:uuid()};requestStore.set('v11:pair:'+op,JSON.stringify(saved));}
 const {raw,req}=saved;const rows=unpack(await db.rpc('yt_issue_pass',{p_campaign:campaign,p_request:req,p_token:raw,p_minutes:mins}));if(!rows?.length)throw Error('生成失败，请重试');requestStore.remove('v11:pair:'+op);
 await showCodeSheet('扫码领取 Game Pass',`扫码后进入 Yetipsy Play，完成登录即可选择游戏。凭证 ${mins} 分钟内有效。`,newLink('claim',raw));}
async function lookupRedeem(){const raw=$('staffRedeemInput').value.trim();const tok=tokenDetails(raw).token;const rows=unpack(await db.rpc('yt_lookup_redeem',{p_token:tok}));$('staffLookupBox').classList.remove('hide');if(!rows?.length){$('staffLookupBox').textContent='找不到这份奖励或二维码已失效';state.currentRedemption=null;return;}
 const row=rows[0];state.currentRedemption=row.valid?tok:null;$('staffLookupBox').replaceChildren();const p=document.createElement('p');p.textContent=`${row.reward_name} · ${row.valid?'可核销':'不可核销 / 未到时间 / 已过期'}`;$('staffLookupBox').append(p);
 if(row.valid){const b=document.createElement('button');b.className='button button-primary wide';b.textContent='确认核销这份奖励';b.onclick=()=>pending(b,staffConfirmRedeem);$('staffLookupBox').append(b);}}
async function staffConfirmRedeem(){if(!state.currentRedemption)throw Error('没有可核销凭证');const token=state.currentRedemption,req=retryId('redeem:'+token);const rows=unpack(await db.rpc('yt_redeem',{p_token:token,p_request:req}));if(!rows?.length)throw Error('核销失败，请重试');requestStore.remove('v11:redeem:'+token);state.currentRedemption=null;$('staffRedeemInput').value='';$('staffLookupBox').innerHTML=`<b>✓ 核销完成</b><p>${esc(rows[0].reward_name)}</p><p>Receipt REF: ${esc(rows[0].receipt_id.slice(0,8).toUpperCase())}</p><p>${esc(fmt(rows[0].redeemed_at))}</p>`;toast('核销记录已写入 Supabase');}

let homeCarousel=null,bannerManager=null;
async function manageBanners(){if(!isOwner())throw Error('owner_only');if(!bannerManager)bannerManager=createBannerManager({db,root:$('ownerBannersPanel'),notify:(message,bad)=>toast(message,bad),onPublished:()=>homeCarousel?.refresh()});await bannerManager.load();}
function ownTab(name){for(const [a,id] of [['issue','ownerIssueTab'],['campaigns','ownerCampaignTab'],['team','ownerTeamTab'],['insights','ownerInsightsTab'],['banners','ownerBannerTab']])$(id).classList.toggle('hide',a!==name);for(const b of document.querySelectorAll('[data-worktab]'))b.classList.toggle('active',b.dataset.worktab===name);if(name==='banners')manageBanners().catch(e=>toast(errorText(e),true));if(name==='insights')loadInsights().catch(e=>toast(errorText(e),true));}
function selectRestore(el,rows,fn){const old=el.value;el.replaceChildren();rows.forEach(item=>el.add(new Option(fn(item),item.id)));if(rows.some(x=>x.id===old))el.value=old;}
async function loadOwner(){if(!isOwner())return;const [profiles,rewards,campaigns,games,staffRoles]=await Promise.all([
 db.from('profiles').select('id,display_name,phone').order('created_at',{ascending:false}).limit(200),
 db.from('rewards').select('id,name,description,category,validity_days,active').eq('active',true).order('created_at',{ascending:false}).limit(400),
 db.from('campaigns').select('id,name,starts_at,ends_at,active').order('created_at',{ascending:false}).limit(100),
 db.from('games').select('id,slug,title,mode,active').eq('active',true).order('slug'),
 db.from('staff_roles').select('user_id,role,active')
 ]);
 state.rewards=unpack(rewards);state.campaigns=unpack(campaigns);state.ownerGames=unpack(games);state.customers=unpack(profiles);state.staffRoles=unpack(staffRoles);const names=x=>x.name;
 selectRestore($('issueReward'),state.rewards,names);selectRestore($('directCustomer'),state.customers,x=>(x.display_name||x.phone||'Customer')+(x.phone?' · '+x.phone:''));selectRestore($('ownerCampaign'),state.campaigns,x=>(x.active?'● ':'○ ')+x.name);renderStaffAccess();await loadCampaignDetail();}
function renderStaffAccess(){
 const ownerIds=new Set(state.staffRoles.filter(s=>s.role==='owner').map(s=>s.user_id));
 selectRestore($('staffMember'),state.customers.filter(p=>p.id!==state.user?.id&&!ownerIds.has(p.id)),x=>(x.display_name||'Yetipsy Member')+' · '+(x.phone||x.id.slice(0,8)));
 const root=$('staffRoleList');root.replaceChildren();
 for(const role of state.staffRoles.filter(s=>s.role==='staff')){
  const person=state.customers.find(p=>p.id===role.user_id);
  const row=document.createElement('div');row.className='team-row';
  const identity=document.createElement('div');identity.innerHTML=`<strong>${esc(person?.display_name||'Member')}</strong><small>${esc(person?.phone||'—')} · ${role.active?'已启用':'已停用'}</small>`;
  const btn=document.createElement('button');btn.className='button button-outline';btn.textContent=role.active?'停用':'重新启用';
  btn.onclick=()=>pending(btn,async()=>{
   if(!confirm(`确认${role.active?'停用':'恢复'}这个 Staff 账户？`))return;
   unpack(await db.rpc('yt_owner_staff_access',{p_user:role.user_id,p_active:!role.active}));
   await loadOwner();toast('员工权限已更新');
  }).catch(()=>{});
  row.append(identity,btn);root.append(row);
 }
 if(!root.children.length)root.innerHTML='<p class="soft-text">当前还没有 Staff 账户。</p>';
}
async function grantStaff(){const who=$('staffMember').value;if(!who)throw Error('没有可以授权的已注册会员');if(!confirm('确认把该账户设为 Staff？'))return;unpack(await db.rpc('yt_owner_staff_access',{p_user:who,p_active:true}));toast('Staff 权限已启用');await loadOwner();}
function datetimeMY(value){return value?value+':00+08:00':null;}
function inputDatetime(date){return new Intl.DateTimeFormat('sv-SE',{timeZone:MY_TZ,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false}).format(date).replace(' ','T');}
function initialiseOfferDates(){if(!$('offerUntil').value){$('offerFrom').value=inputDatetime(new Date());$('offerUntil').value=inputDatetime(new Date(Date.now()+7*86400000));}}
async function createCustomReward(ev){ev.preventDefault();const btn=ev.submitter;
 await pending(btn,async()=>{const from=$('rewardStart').value,until=$('rewardEnd').value,df=$('rewardDailyFrom').value,du=$('rewardDailyUntil').value;if(Boolean(df)!==Boolean(du))throw Error('每日时段必须同时输入开始和结束');const name=$('rewardTitle').value.trim();if(!name)throw Error('请输入奖品名称');const id=unpack(await db.rpc('yt_create_reward_v11',{
 p_name:name,p_description:$('rewardDesc').value.trim(),p_category:$('rewardCategory').value,
 p_validity:Number($('rewardValidity').value),p_next_day:$('rewardNextDay').checked,
 p_use_from:datetimeMY(from),p_use_until:datetimeMY(until),p_daily_from:df||null,p_daily_until:du||null}));
 $('newRewardForm').reset();$('rewardNextDay').checked=true;await loadOwner();$('issueReward').value=id;toast('奖品已建立，可立即发给顾客或生成领取码');});}
async function ownerOffer(){const reward=$('issueReward').value;if(!reward)throw Error('请先创建或选择奖品');const start=datetimeMY($('offerFrom').value),end=datetimeMY($('offerUntil').value);if(!end)throw Error('请设置领取截止时间');const n=Number($('offerTotal').value),per=Number($('offerPerUser').value);const raw=uuid();const offer=unpack(await db.rpc('yt_create_offer_v5',{p_reward:reward,p_token:raw,p_from:start,p_until:end,p_max:n,p_per_user:per}));const name=state.rewards.find(r=>r.id===reward)?.name||'Yetipsy Reward';await showCodeSheet('领取这份专属好礼',`${name} · 每账户最多 ${per} 次 · 总共 ${n} 份；截止 ${fmt(end)}。`,newLink('gift',raw),true,offer.expires_at,offer.display_code,'gift');}
async function ownerDirectIssue(){const reward=$('issueReward').value,customer=$('directCustomer').value;if(!reward||!customer)throw Error('请先选择奖励与顾客');if(!confirm('确定将这份奖励直接发到顾客钱包？'))return;const req=retryId('direct:'+customer+':'+reward);const id=unpack(await db.rpc('yt_send_reward',{p_customer:customer,p_reward:reward,p_request:req}));if(!id)throw Error('发奖失败');requestStore.remove('v11:direct:'+customer+':'+reward);toast('发放成功，顾客钱包已入账');}
async function loadCampaignDetail(){if(!isOwner())return;const campaignId=$('ownerCampaign').value;const item=state.campaigns.find(x=>x.id===campaignId);if(!item){$('gameToggles').replaceChildren();$('poolEditor').replaceChildren();return;}$('ownerCampaignActive').checked=item.active;
 const [assigned,pool]=await Promise.all([
 db.from('campaign_games').select('game_id').eq('campaign_id',campaignId),
 db.from('reward_pool_entries').select('id,game_id,result_key,reward_id,weight,max_total,max_daily,issued_total,issued_today,issued_day').eq('campaign_id',campaignId).order('result_key')
 ]);
 if($('ownerCampaign').value!==campaignId)return;state.assigned=unpack(assigned).map(x=>x.game_id);state.pool=unpack(pool);
 const root=$('gameToggles');root.replaceChildren();for(const g of state.ownerGames){const row=document.createElement('label');row.className='toggle-entry';const cb=document.createElement('input');cb.type='checkbox';cb.checked=state.assigned.includes(g.id);cb.onchange=async()=>{cb.disabled=true;try{unpack(await db.rpc('yt_owner_set_game',{p_campaign:campaignId,p_game:g.id,p_enabled:cb.checked}));toast('游戏开放状态已更新');await loadCampaignDetail();}catch(e){cb.checked=!cb.checked;toast(errorText(e),true);}finally{cb.disabled=false;}};const txt=document.createElement('span');txt.textContent=(symbols[g.slug]||'✦')+'  '+g.title;row.append(txt,cb);root.append(row);}
 selectRestore($('poolGame'),state.ownerGames,x=>x.title);renderPoolEditor();}
function renderPoolEditor(){const root=$('poolEditor');root.replaceChildren();const game=$('poolGame').value,entries=state.pool.filter(x=>x.game_id===game);let total=entries.reduce((s,x)=>s+(x.weight||0),0);
 if(!entries.length){root.innerHTML='<p>当前游戏没有奖池。</p>';return;}
 for(const x of entries){const row=document.createElement('div');row.className='pool-row';const label=document.createElement('div');label.className='pool-row-head';const title=document.createElement('strong');title.className='pool-name';title.textContent=x.result_key+' · '+(state.rewards.find(r=>r.id===x.reward_id)?.name||'Reward');const rate=document.createElement('span');rate.className='pool-rate';rate.textContent=(100*x.weight/Math.max(total,1)).toFixed(2)+'%';label.append(title,rate);row.append(label);
 const rewardSelect=document.createElement('select');for(const r of state.rewards)rewardSelect.add(new Option(r.name,r.id));rewardSelect.value=x.reward_id;row.append(rewardSelect);
 const fields=document.createElement('div');fields.className='form-row';const nums=[['权重',x.weight,1,10000],['总上限（留空不限制）',x.max_total??'',0,100000],['每日上限（留空不限制）',x.max_daily??'',0,100000]];for(const [labelText,value,min,max] of nums){const box=document.createElement('div');const label=document.createElement('label');label.textContent=labelText;const input=document.createElement('input');input.type='number';input.min=String(min);input.max=String(max);input.value=String(value);box.append(label,input);fields.append(box);}row.append(fields);const inputs=fields.querySelectorAll('input');const save=document.createElement('button');save.className='button button-outline wide';save.textContent='保存这一项';save.onclick=()=>pending(save,async()=>{
 const convert=(node)=>node.value.trim()===''?null:Number(node.value);unpack(await db.rpc('yt_owner_set_pool_v11',{p_entry:x.id,p_reward:rewardSelect.value,p_weight:Number(inputs[0].value),p_max_total:convert(inputs[1]),p_max_daily:convert(inputs[2])}));toast('奖池设置已更新');await loadCampaignDetail();});row.append(save);root.append(row);}
}
async function saveCampaign(){const campaign=$('ownerCampaign').value;if(!campaign)throw Error('请选择活动');unpack(await db.rpc('yt_owner_set_campaign',{p_campaign:campaign,p_active:$('ownerCampaignActive').checked}));toast('活动状态已保存');await Promise.all([loadOwner(),loadStaffCampaigns()]);}
async function cloneCampaign(){const source=$('ownerCampaign').value,name=$('cloneName').value.trim();if(!source||!name)throw Error('请输入新活动名称');const id=unpack(await db.rpc('yt_owner_clone_campaign',{p_source:source,p_name:name}));$('cloneName').value='';await loadOwner();$('ownerCampaign').value=id;await loadCampaignDetail();toast('新活动已建立（默认关闭）');}
async function loadInsights(){if(!isOwner())return;const values=[['profiles','statCustomers'],['game_passes','statPasses'],['user_rewards','statRewards'],['redemptions','statRedeems']];await Promise.all(values.map(async ([table,id])=>{const r=await db.from(table).select('id',{count:'exact',head:true});if(r.error)throw r.error;$(id).textContent=Number(r.count||0).toLocaleString('en-MY');}));}

async function authToken(){const {data,error}=await db.auth.getSession();if(error||!data.session?.access_token)throw Error('登录已失效，请重新登录');return data.session.access_token;}
async function staffPrepareReset(ev){ev.preventDefault();const btn=ev.submitter;
 await pending(btn,async()=>{
  if(!isStaff())throw Error('仅限员工操作');
  if(!$('onsiteConfirmed').checked)throw Error('请先完成顾客本人及额外身份核对');
  const phone=normalizePhone($('staffResetCountry').value,$('staffResetPhone').value);
  const data=await pinRequest('reset_prepare',phone,'','',{birthday:$('staffResetBirthday').value,onsite_confirmed:true,bearer:await authToken()});
  $('staffResetForm').reset();
  await showCodeSheet('请顾客扫码设置新 PIN','5 分钟内有效，顾客自行设置；员工无法查看 PIN。',newLink('reset',data.token),false);
 });
}
async function showResetFlow(raw){
 const info=tokenDetails(raw);showSheet('设置新 PIN','YETIPSY · ACCOUNT RECOVERY');
 sheetHtml('<div class="sheet-content"><p>员工已完成现场核验。请由顾客本人输入新的 6 位 PIN。</p><form id="resetCompleteForm"><label>新的 6 位 PIN</label><input id="resetPin" type="password" inputmode="numeric" maxlength="6" required placeholder="● ● ● ● ● ●"/><label>确认新 PIN</label><input id="resetPinAgain" type="password" inputmode="numeric" maxlength="6" required/><button class="button button-primary wide" type="submit">确认修改 PIN ↗</button></form></div>');
 $('resetCompleteForm').onsubmit=ev=>{ev.preventDefault();pending(ev.submitter,async()=>{
  if($('resetPin').value!==$('resetPinAgain').value)throw Error('两次 PIN 不一致');
  await pinRequest('reset_finish','',$('resetPin').value,'',{token:info.token});
  const u=new URL(location.href);u.searchParams.delete('reset');history.replaceState(null,'',u.href);
  await closeSheet();shell(false);changeAuthMode('phone');toast('PIN 重设成功，请使用手机号和新 PIN 登录');
 }).catch(()=>{});};
}
async function changeMyPin(){
 if(!state.profile?.phone)throw Error('只有手机号注册会员可以在此修改 PIN');
 showSheet('修改登录 PIN','YOUR ACCOUNT · SECURITY');
 sheetHtml('<div class="sheet-content"><p>请先确认你当前的 PIN，然后设置新 PIN。</p><form id="myPinForm"><label>当前 PIN</label><input id="oldPin" type="password" inputmode="numeric" maxlength="6" required/><label>新 PIN</label><input id="newPin" type="password" inputmode="numeric" maxlength="6" required/><label>再输入一次新 PIN</label><input id="newPinConfirm" type="password" inputmode="numeric" maxlength="6" required/><button type="submit" class="button button-primary wide">保存新 PIN</button></form></div>');
 $('myPinForm').onsubmit=e=>{e.preventDefault();pending(e.submitter,async()=>{
  if($('newPin').value!==$('newPinConfirm').value)throw Error('两次新 PIN 不一致');
  await pinRequest('change_pin',state.profile.phone,$('newPin').value,'',{old_pin:$('oldPin').value,bearer:await authToken()});
  await db.auth.signOut();state.user=null;state.role=null;await closeSheet();shell(false);changeAuthMode('phone');toast('PIN 已修改，请使用新 PIN 重新登录');
 }).catch(()=>{});};
}
function bindEvents(){
 $('phoneCheckForm').addEventListener('submit',submitPhone);$('authForm').addEventListener('submit',submitAuth);$('authBack').onclick=()=>changeAuthMode('phone');
 $('togglePin').onclick=()=>{const field=$('pin');field.type=field.type==='password'?'text':'password';$('togglePin').textContent=field.type==='password'?'显示':'隐藏';};
 for(const b of document.querySelectorAll('[data-page]'))b.onclick=()=>navigate(b.dataset.page);
 $('homeRewardClaim').onclick=openRewardClaim;$('authRewardClaim').onclick=openRewardClaim;
 $('heroScan').onclick=()=>openScanner('claim');$('accountChangePin').onclick=()=>changeMyPin().catch(e=>toast(errorText(e),true));$('privacyNotice').onclick=()=>{showSheet('会员隐私与资料用途','YETIPSY PLAY');sheetHtml('<div class="sheet-content"><p>我们收集手机号码、昵称、完整出生日期和会员活动记录，用于账户登录、会员资料、会员福利、奖品发放及员工协助重设 PIN。手机号目前不通过短信验证。</p><p>PIN 由服务器保护，员工无法查看。生日不会在公开奖品榜或其他顾客页面展示。奖励及核销操作会保留必要记录。</p><p>注册不要求额外勾选同意，也不会自动订阅营销消息。需要更正资料、查询处理方式或删除安排，请到 Yetipsy 联系店主。</p></div>');};$('openExistingPass').onclick=()=>existingGamePass().catch(e=>toast(errorText(e),true));
 $('homePrizes').onclick=()=>prizeBoard().catch(e=>toast(errorText(e),true));$('accountPrizes').onclick=()=>prizeBoard().catch(e=>toast(errorText(e),true));$('publicBoardFromAuth').onclick=()=>prizeBoard().catch(e=>toast(errorText(e),true));
 $('homeLeaderboard').onclick=()=>showLeaderboard().catch(e=>toast(errorText(e),true));$('accountLeaderboard').onclick=()=>showLeaderboard().catch(e=>toast(errorText(e),true));$('accountRecords').onclick=()=>showMyRecords().catch(e=>toast(errorText(e),true));$('homeWallet').onclick=()=>navigate('wallet');$('walletRefresh').onclick=()=>wallet().catch(e=>toast(errorText(e),true));$('accountScan').onclick=()=>openScanner('claim');
 $('accountStaff').onclick=()=>openWorkspace('staff');$('accountOwner').onclick=()=>openWorkspace('owner');
 $('workspaceBack').onclick=()=>navigate('account');
 $('signOut').onclick=async()=>{if(!confirm('确认退出 Yetipsy Play？'))return;await closeSheet();const {error}=await db.auth.signOut();if(error)return toast(error.message,true);state.user=null;state.profile=null;state.role=null;shell(false);changeAuthMode('login');toast('已安全退出');};
 $('sheetClose').onclick=()=>{if(state.gamePlaying)return toast('游戏正在进行，请完成后再离开',true);closeSheet();};
 $('sheetBackdrop').onclick=e=>{if(e.target===$('sheetBackdrop')&&!state.gamePlaying)closeSheet();};
 document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!state.gamePlaying&&!$('sheetBackdrop').classList.contains('hide'))closeSheet();});
 $('staffResetOpen').onclick=showStaffReset;$('staffResetForm').onsubmit=e=>staffPrepareReset(e).catch(()=>{});$('staffGenerateOpen').onclick=showStaffGenerate;$('staffRedeemOpen').onclick=showStaffRedeem;
 $('staffScanRedemption').onclick=()=>openScanner('redeem');
 $('staffGenerate').onclick=e=>pending(e.currentTarget,staffIssuePass).catch(()=>{});
 $('staffRedeemCheck').onclick=e=>pending(e.currentTarget,lookupRedeem).catch(()=>{});
 for(const b of document.querySelectorAll('[data-worktab]'))b.onclick=()=>ownTab(b.dataset.worktab);
 $('newRewardForm').onsubmit=ev=>createCustomReward(ev).catch(()=>{});
 for(const b of document.querySelectorAll('[data-issue]'))b.onclick=()=>{const qr=b.dataset.issue==='qr';$('offerFields').classList.toggle('hide',!qr);$('directIssueFields').classList.toggle('hide',qr);for(const el of document.querySelectorAll('[data-issue]'))el.classList.toggle('active',el===b);};
 $('createOffer').onclick=e=>pending(e.currentTarget,ownerOffer).catch(()=>{});$('directIssue').onclick=e=>pending(e.currentTarget,ownerDirectIssue).catch(()=>{});
 $('ownerCampaign').onchange=()=>loadCampaignDetail().catch(e=>toast(errorText(e),true));$('poolGame').onchange=renderPoolEditor;
 $('saveCampaign').onclick=e=>pending(e.currentTarget,saveCampaign).catch(()=>{});$('cloneCampaign').onclick=e=>pending(e.currentTarget,cloneCampaign).catch(()=>{});
 $('ownerOpenPrizes').onclick=()=>prizeBoard().catch(e=>toast(errorText(e),true));
 $('reloadInsights').onclick=e=>pending(e.currentTarget,loadInsights).catch(()=>{});$('staffAccessGrant').onclick=e=>pending(e.currentTarget,grantStaff).catch(()=>{});
}
async function boot(){bindEvents();homeCarousel=createHomeCarousel({db,root:$('homeCarousel')});if(configured)homeCarousel.refresh().catch(()=>{});changeAuthMode('phone');initialiseOfferDates();if(!configured){$('authError').textContent='配置缺失，请联系店主';shell(false);return;}
 const {data:{session}}=await db.auth.getSession();
 if(session){try{await initialize();}catch(e){console.error('Initialization:',e);toast('连接失败：'+errorText(e),true);}}else shell(false);
 db.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT'){state.user=null;state.role=null;state.profile=null;shell(false);changeAuthMode('phone');}});
  const qs=new URL(location.href).searchParams;
  const invite=(qs.get('invite')||'').toUpperCase();
  if(/^YT[A-Z0-9]{8}$/.test(invite)){state.referralDraft=invite;$('referralCode').value=invite;}
  if(state.user)loadMyLoyalty().catch(()=>{});
 if(qs.has('reset')){try{await showResetFlow(qs.get('reset'));}catch(e){toast(errorText(e),true);}}
 else if(qs.has('claim')||qs.has('gift')){
  const kind=qs.has('claim')?'claim':'gift';try{await previewClaim(qs.get(kind),kind);}catch(e){toast(errorText(e),true);}
 }
 if('serviceWorker'in navigator&&location.protocol==='https:'&&location.pathname.includes('/play-v12/'))navigator.serviceWorker.register('./sw.js').catch(()=>{});
}
boot().catch(e=>{console.error('Boot:',e);shell(false);$('authError').textContent='系统暂时无法启动：'+errorText(e);});

