import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';

const $=id=>document.getElementById(id);
const urlConfig=window.YETIPSY_PLAY_CONFIG||{};
const configured=/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(urlConfig.url||'')&&/^sb_publishable_/.test(urlConfig.publishableKey||'');
const db=configured?createClient(urlConfig.url,urlConfig.publishableKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}}):null;
const EDGE_URL=(urlConfig.url||'')+'/functions/v1/yt-pin-auth';
const MY_TZ='Asia/Kuala_Lumpur';
const state={user:null,role:null,profile:null,view:'home',games:[],passes:[],wallet:[],rewards:[],campaigns:[],ownerGames:[],pool:[],assigned:[],busy:false,refreshing:false,activeSession:null,currentRedemption:null,currentOffer:null,board:[],staffRoles:[],handleToken:null,loginMode:'phone',checkedPhone:null,pendingClaim:null,gamePlaying:false};
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
function errorText(e){const s=String(e?.message||e||'操作失败');const map={owner_only:'仅限 Owner 操作',staff_only:'仅限员工操作',not_authenticated:'登录已失效，请重新登录',pass_invalid_or_claimed:'游戏码无效、已领取或已过期',offer_unavailable:'奖励已领完、尚未开放或已到期',offer_not_found:'找不到这个奖励领取码',account_claim_limit:'你已经达到这个活动的领取次数',reward_no_valid_window:'奖品的可用时间设置有冲突',reward_not_redeemable:'奖励尚未到可兑换时间，或已经过期',outside_redeem_hours:'不在奖品允许兑换的营业时段',reward_pool_empty_or_sold_out:'奖池库存已用完',invalid_credentials:'手机号或 PIN 不正确',too_many_attempts:'尝试次数过多，请 15 分钟后再试',already_registered:'该号码已注册，请直接登录',invalid_pin:'请输入 6 位数字 PIN',weak_pin:'PIN 太容易猜，请换一个',invalid_phone:'请输入正确的手机号码',request_conflict:'请刷新后重试'};return map[s]||s.replaceAll('_',' ');}
function shell(showMain){$('authView').classList.toggle('hide',showMain);$('mainView').classList.toggle('hide',!showMain);$('workspaceView').classList.add('hide');}
function navigate(page='home'){state.view=page;shell(true);for(const e of document.querySelectorAll('.page'))e.classList.toggle('hide',e.id!==page+'Page');for(const e of document.querySelectorAll('[data-page]'))e.classList.toggle('active',e.dataset.page===page);window.scrollTo({top:0,behavior:'smooth'});if(page==='wallet')wallet().catch(e=>toast(errorText(e),true));if(page==='home')updateHome();if(page==='account')drawProfile();}
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
 $('confirmPinGroup').classList.toggle('hide',!signup);
 $('consentGroup').classList.toggle('hide',!signup);
 $('nickname').required=signup;$('birthday').required=signup;$('pinConfirm').required=signup;$('accepted').required=signup;
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
   if(!$('accepted').checked)throw Error('请阅读并同意会员条款和隐私说明');
   extras={birthday:$('birthday').value,accepted:true,marketing:$('marketing').checked};
  }
  const data=await pinRequest(state.loginMode,phone,pin,$('nickname').value.trim(),extras);
  const {error}=await db.auth.setSession({access_token:data.access_token,refresh_token:data.refresh_token});
  if(error)throw error;
  $('pin').value='';$('pinConfirm').value='';
  await initialize();toast(signup?'欢迎加入 Yetipsy Play ✳':'欢迎回来 ✳');
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
function updateHome(){const valid=state.passes.filter(p=>p.status==='claimed'&&millis(p.expires_at)>Date.now());$('homePassCount').textContent=`${valid.length} 次待使用机会`;$('openExistingPass').classList.toggle('hide',!valid.length);$('homeGreetingSub').textContent=state.profile?.display_name?'嗨，'+state.profile.display_name+' · 今晚玩点新的？':'YETIPSY PLAY · 轻松享受此刻';}
async function refreshPasses(){if(!state.user)return;state.passes=unpack(await db.from('game_passes').select('id,status,claimed_at,expires_at,campaign_id,created_at').eq('customer_id',state.user.id).order('created_at',{ascending:false}).limit(50));updateHome();}
async function loadGames(){state.games=unpack(await db.from('games').select('id,slug,title,mode,active').eq('active',true).order('slug'));}
async function wallet(silent=false){if(!state.user)return;const items=unpack(await db.from('user_rewards').select('id,status,created_at,redeem_after,expires_at,redeemed_at,rewards(name,description,category,daily_start_local,daily_end_local)').eq('customer_id',state.user.id).order('created_at',{ascending:false}).limit(100));state.wallet=items;renderWallet();if(!silent)updateHome();}
const iconFor=category=>({drink:'♧',voucher:'◇',gift:'✳',event:'✦',custom:'◈'})[category]||'✦';
function renderWallet(){const root=$('walletItems');root.replaceChildren();const usable=state.wallet.filter(x=>x.status==='available'&&millis(x.redeem_after)<=Date.now()&&millis(x.expires_at)>Date.now());$('availableRewards').textContent=usable.length;
 if(!state.wallet.length){root.innerHTML='<div class="empty-state"><span class="empty-symbol">✦</span>这里还没有奖励。<br/>扫码玩游戏，或领取店主送出的好礼。</div>';return;}
 for(const r of state.wallet){const expires=millis(r.expires_at)<=Date.now(),early=millis(r.redeem_after)>Date.now(),redeemed=r.status==='redeemed';const available=r.status==='available'&&!expires&&!early;const card=document.createElement('div');card.className='reward-item';const status=redeemed?'已核销':expires?'已过期':r.status==='revoked'?'已作废':early?'未到使用时间':'可兑换';card.innerHTML=`<div class="reward-icon">${iconFor(r.rewards?.category)}</div><div><span class="chip ${available?'ok':redeemed?'off':''}">${status}</span><h3>${esc(r.rewards?.name||'Reward')}</h3><p>${esc(r.rewards?.description||'到店出示凭证由员工核销')}</p><p>开始：${esc(fmt(r.redeem_after))}<br/>截止：${esc(fmt(r.expires_at))}</p>${r.rewards?.daily_start_local?`<p>每日可用：${esc(r.rewards.daily_start_local.slice(0,5))} – ${esc(r.rewards.daily_end_local.slice(0,5))}</p>`:''}</div>`;
 if(available){const btn=document.createElement('button');btn.className='button button-outline';btn.textContent='▣ 生成兑奖二维码 / 条形码';btn.onclick=()=>pending(btn,()=>showRewardQR(r));card.append(btn);}root.append(card);}
}
function showSheet(title,eyebrow='YETIPSY PLAY'){if(scannerRunning)stopScanner();$('sheetTitle').textContent=title;$('sheetEyebrow').textContent=eyebrow;$('sheetBody').replaceChildren();$('sheetBackdrop').classList.remove('hide');document.body.style.overflow='hidden';}
async function closeSheet(){await stopScanner();$('sheetBackdrop').classList.add('hide');document.body.style.overflow='';}
function sheetHtml(s){$('sheetBody').innerHTML=s;}
function sheetAction(id,label,callback,klass='button-primary'){const b=document.createElement('button');b.id=id;b.className='button '+klass+' wide';b.textContent=label;b.onclick=()=>pending(b,callback);$('sheetBody').append(b);return b;}
const loadScript=url=>new Promise((resolve,reject)=>{const el=document.createElement('script');el.src=url;el.async=true;el.onload=resolve;el.onerror=()=>reject(Error('资源暂时加载失败，您可以使用复制链接'));document.head.append(el);});
async function qrcode(canvas,text){if(!window.QRCode)qrLibPromise??=loadScript('https://cdn.jsdelivr.net/npm/qrcode@1.5.4/build/qrcode.min.js');await qrLibPromise;await window.QRCode.toCanvas(canvas,text,{width:220,margin:1,color:{dark:'#171b19',light:'#faf6e9'},errorCorrectionLevel:'M'});}
async function barcode(svg,text){if(!window.JsBarcode)barcodeLibPromise??=loadScript('https://cdn.jsdelivr.net/npm/jsbarcode@3.11.6/dist/JsBarcode.all.min.js');await barcodeLibPromise;window.JsBarcode(svg,text,{format:'CODE128',lineColor:'#1c2421',background:'#f2ecdf',width:1.1,height:51,displayValue:false,margin:3});}
function copy(text){navigator.clipboard?.writeText(text).then(()=>toast('已复制')).catch(()=>{const input=document.createElement('textarea');input.value=text;document.body.append(input);input.select();document.execCommand('copy');input.remove();toast('已复制');});}
async function showCodeSheet(title,subtitle,link,withBarcode=true,deadline=null){showSheet(title,'SCAN & CLAIM');sheetHtml(`<div class="sheet-content"><p>${esc(subtitle)}</p><div class="code-card"><b>YE·TIPSY</b><small style="display:block">PRESENT THIS CODE</small><canvas id="sheetQR" width="220" height="220"></canvas>${withBarcode?'<svg id="sheetBarcode" aria-label="可扫描条形码"></svg>':''}<div class="token-text" id="sheetToken"></div></div><button type="button" id="sheetCopy" class="button button-outline wide">复制领取链接 / 扫描内容</button>${deadline?'<p id="sheetCountdown" class="tiny-help"></p>':''}<p class="tiny-help">优先使用二维码；支持条形码的扫描设备也可以读取同一凭证。</p></div>`);$('sheetToken').textContent=link;const codeURL=new URL(link);const codeKey=[...codeURL.searchParams.keys()][0]||'claim';const codeRaw=codeURL.searchParams.get(codeKey)||link;const raw=codeKey+':'+codeRaw;try{await qrcode($('sheetQR'),link);}catch(e){$('sheetQR').style.display='none';toast('二维码素材加载失败，请复制链接',true);}if(withBarcode){try{await barcode($('sheetBarcode'),raw);}catch(e){$('sheetBarcode').classList.add('hide');}}
 $('sheetCopy').onclick=()=>copy(link);if(deadline){const tick=()=>{const el=$('sheetCountdown');if(!el||!el.isConnected){clearInterval(timer);return;}const secs=Math.max(0,Math.ceil((millis(deadline)-Date.now())/1000));el.textContent=secs?`动态二维码 ${secs} 秒后失效`:'已过期，需要重新生成';if(!secs)clearInterval(timer);};let timer=setInterval(tick,1000);tick();}}
async function showRewardQR(reward){const code=uuid();const deadline=unpack(await db.rpc('yt_make_redeem',{p_award:reward.id,p_token:code}));const link=newLink('redeem',code);await showCodeSheet('出示奖励凭证',reward.rewards?.name||'Yetipsy Reward',link,true,deadline);}
function tokenDetails(raw){const s=String(raw||'').trim();let kind='claim',token=s;const prefixed=s.match(/^(gift|claim|redeem):([0-9a-f-]{36})$/i);if(prefixed){kind=prefixed[1].toLowerCase();token=prefixed[2];}
 try{const url=new URL(s);for(const k of ['claim','gift','redeem']){if(url.searchParams.has(k)){kind=k;token=url.searchParams.get(k);break;}}}catch{}
 if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(token))throw Error('无效的二维码或条形码，请扫描完整凭证');return {kind,token};}
const requestStore={get(key){try{return sessionStorage.getItem(key)}catch{return null}},set(key,v){try{sessionStorage.setItem(key,v)}catch{}},remove(key){try{sessionStorage.removeItem(key)}catch{}}};
function retryId(key){let prev=requestStore.get('v11:'+key);if(prev)return prev;prev=uuid();requestStore.set('v11:'+key,prev);return prev;}
async function previewClaim(raw,assumed=null){
 const info=tokenDetails(raw);if(assumed)info.kind=assumed;
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
async function redeemScanValue(raw,assumed){const info=tokenDetails(raw);if(assumed)info.kind=assumed;
 if(!state.user){state.pendingClaim=info;shell(false);changeAuthMode('phone');return;}

 if(info.kind==='redeem'){if(!isStaff())throw Error('兑奖二维码需由 Staff 扫描');openWorkspace('staff');showStaffRedeem();$('staffRedeemInput').value=info.token;await lookupRedeem();return;}
 if(info.kind==='gift'){
  const key='gift:'+info.token,req=retryId(key);const rows=unpack(await db.rpc('yt_claim_offer',{p_token:info.token,p_request:req}));if(!rows?.length)throw Error('奖励领取失败');requestStore.remove('v11:'+key);stripLink('gift');await wallet(true);await showSimpleSuccess('领取成功',rows[0].reward_name||'礼物已放进奖励钱包','奖励可在「我的奖励」里查看使用时间。');return;
 }
 const claimedId=unpack(await db.rpc('yt_claim_pass',{p_token:info.token}));stripLink('claim');await refreshPasses();toast('游戏机会已经领取 ✳');const p=state.passes.find(x=>x.id===claimedId&&x.status==='claimed'&&millis(x.expires_at)>Date.now());if(p)await chooseGame(p);else toast('游戏机会已入账，请到首页选择游戏',true);
}
function stripLink(kind){const u=new URL(location.href);u.searchParams.delete(kind);history.replaceState(null,'',u.href);}
async function manualClaimSubmit(){const raw=$('scanManual').value.trim();await redeemScanValue(raw);}
async function openScanner(mode='claim'){
 showSheet(mode==='redeem'?'扫描兑奖凭证':'扫一扫，开启惊喜','SCAN CODE');
 sheetHtml(`<div class="sheet-content"><div class="scan-frame" id="cameraFrame"><div class="scan-placeholder"><span>▣</span>准备启动相机…</div></div><p class="scan-helper">可扫描 Yetipsy QR / CODE128 条形码。首次使用请允许相机访问。</p><div class="sheet-sep"></div><label for="scanManual">扫描不方便？粘贴领取链接或凭证</label><input id="scanManual" placeholder="粘贴二维码链接 / Token"/><button type="button" id="scanSubmit" class="button button-outline wide">确认领取 / 核销查询</button></div>`);
 $('scanSubmit').onclick=()=>pending($('scanSubmit'),async()=>{const raw=$('scanManual').value;if(!raw.trim())throw Error('请输入凭证');await stopScanner();await (mode==='redeem'?redeemScanValue(raw,'redeem'):previewClaim(raw));});
 if(!window.Html5Qrcode){try{await loadScript('https://cdn.jsdelivr.net/npm/html5-qrcode@2.3.8/html5-qrcode.min.js');}catch(e){$('cameraFrame').innerHTML='<div class="scan-placeholder"><span>▣</span>相机组件加载失败，请粘贴链接</div>';return;}}
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
async function chooseGame(pass){await loadGames();const ids=unpack(await db.from('campaign_games').select('game_id').eq('campaign_id',pass.campaign_id)).map(x=>x.game_id);const available=state.games.filter(g=>ids.includes(g.id));if(!available.length)throw Error('该活动暂时没有开放的游戏');showSheet('选择你的游戏','ONE PASS · ONE GAME');const body=$('sheetBody');const root=document.createElement('div');root.className='sheet-content';root.innerHTML='<p>你已拥有一次游戏机会。选定游戏后才会正式开始；每个 Game Pass 只能使用一次。</p><div class="choice-grid" id="gameChoices"></div>';
 for(const g of available){const b=document.createElement('button');b.className='choice-card';b.innerHTML=`<span class="symbol">${symbols[g.slug]||'✦'}</span><strong>${esc(titles[g.slug]?.[0]||g.title)}</strong><small>${esc(titles[g.slug]?.[1]||'YETIPSY PLAY')}</small>`;b.onclick=()=>pending(b,()=>startGame(pass,g));root.querySelector('#gameChoices').append(b);}body.append(root);}
function diceElement(n){const patterns={1:[5],2:[1,9],3:[1,5,9],4:[1,3,7,9],5:[1,3,5,7,9],6:[1,3,4,6,7,9]};return `<div class="dice-cube">${(patterns[n]||[]).map(i=>`<i class="pip p${i}"></i>`).join('')}</div>`;}
function diceResult(tier){const n=tier==='R5'?5:tier==='R4'?4:tier==='R3'?3:Math.floor(Math.random()*3);const a=Array(n).fill(1);while(a.length<5)a.push(2+Math.floor(Math.random()*5));for(let i=a.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[a[i],a[j]]=[a[j],a[i]];}return a;}
function arena(label,visual,foot=''){const body=$('sheetBody');body.innerHTML=`<div class="sheet-content"><div class="game-arena"><div class="arena-label">${esc(label)}</div><div id="gameVisual">${visual}</div><div class="game-foot" id="gameFoot">${esc(foot)}</div></div><p class="tiny-help" id="gameProgress">游戏动画在设备本地运行，结果由服务器安全保存。</p></div>`;return $('gameVisual');}
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function playDice(tier){const faces=diceResult(tier);const v=arena('MOON DICE · 五颗幸运骰子',`<div class="dice-collection">${[1,2,3,4,5].map(diceElement).join('')}</div>`,'杯中一摇，好事发生');v.querySelectorAll('.dice-cube').forEach(el=>el.classList.add('spin'));
 await sleep(2500);v.innerHTML=`<div class="dice-collection">${faces.map(diceElement).join('')}</div>`;$('gameFoot').textContent=`出现 ${faces.filter(n=>n===1).length} 颗「1」 · 完成`;}
async function playPick(isCard){const msg=isCard?'PICK ONE CARD':'CHOOSE YOUR BOX';let elements='';for(let i=0;i<3;i++)elements+=isCard?`<button class="foil-card" data-pick="${i}"><span>✳</span><small>YETIPSY</small></button>`:`<button class="gift-box" data-pick="${i}"><span>✦</span></button>`;
 const v=arena(msg,`<div class="game-picks">${elements}</div>`,'挑一张，打开你的惊喜');await new Promise(resolve=>{let done=false;const timer=setTimeout(()=>finish(-1),30000);function finish(n){if(done)return;done=true;clearTimeout(timer);v.querySelectorAll('[data-pick]').forEach((b,i)=>{b.disabled=true;if(i===n)b.classList.add(isCard?'reveal':'selected');});$('gameFoot').textContent=n<0?'自动揭晓你的礼物':'解锁成功 · 幸运已开启';setTimeout(resolve,800);}v.querySelectorAll('[data-pick]').forEach((b,i)=>b.onclick=()=>finish(i));});}
async function playReaction(){const v=arena('REACTION TEST',`<button id="reactionTap" class="reaction-button" type="button">WAIT…</button>`,'看到绿色时立即点击，不要抢跑');const b=v.querySelector('button');const measurement=await new Promise(resolve=>{let done=false,greenAt=0;const timer=setTimeout(()=>{if(done)return;greenAt=performance.now();b.classList.add('go');b.textContent='TAP NOW!';},1300+Math.random()*1700);const max=setTimeout(()=>end('TIME OUT'),9500);function end(text){if(done)return;done=true;clearTimeout(timer);clearTimeout(max);b.disabled=true;resolve(text);}b.onclick=()=>greenAt?end(Math.round(performance.now()-greenAt)+' ms'):end('FALSE START');});$('gameFoot').textContent=measurement+' · 仅供娱乐';}
async function playStopBar(){const v=arena('STOP THE BAR',`<div class="bar-track"><div class="bar-target"></div><div class="bar-marker" id="marker"></div></div><button class="button button-outline" id="stopBtn" type="button" style="margin-top:22px;min-width:180px">STOP!</button>`,'把金色光标停在最中间');const marker=v.querySelector('#marker'),btn=v.querySelector('#stopBtn');const start=performance.now();let raf=0,position=0;const score=await new Promise(resolve=>{let done=false;function tick(now){if(done)return;let phase=((now-start)/1700)%2;position=phase<=1?phase:2-phase;marker.style.left=(position*100)+'%';raf=requestAnimationFrame(tick);}function end(){if(done)return;done=true;cancelAnimationFrame(raf);clearTimeout(timeout);btn.disabled=true;resolve(Math.max(0,Math.round((1-Math.abs(.5-position)*2)*100)));}raf=requestAnimationFrame(tick);btn.onclick=end;const timeout=setTimeout(end,9500);});$('gameFoot').textContent=`ACCURACY ${score}% · 奖励独立抽取`;}
function fireworks(){const wrap=document.createElement('div');wrap.className='game-confetti';for(let i=0;i<26;i++){const dot=document.createElement('i');dot.style.left=(Math.random()*100)+'%';dot.style.animationDelay=(Math.random()*.55)+'s';dot.style.background=i%3?'#e3c190':'#f8efe2';wrap.append(dot);}return wrap;}
async function showGameWon(name){showSheet('好事已经发生','REWARD UNLOCKED');sheetHtml(`<div class="sheet-content"><div class="game-arena" id="wonArena"><span class="game-result-star">✳</span><div class="game-result-name">${esc(name)}</div><div class="game-result-sub">奖励已存进你的钱包</div></div><button class="button button-primary wide" id="goWalletFromGame">查看我的奖励 ↗</button><p class="tiny-help">以奖励钱包里的开始、截止时间为准，到店出示动态 QR 核销。</p></div>`);$('wonArena').append(fireworks());$('goWalletFromGame').onclick=()=>{closeSheet();navigate('wallet');};}
async function startGame(pass,g){if(state.gamePlaying)throw Error('游戏进行中，请勿重复点击');state.gamePlaying=true;let session=null;
 try{
  const rows=unpack(await db.rpc('yt_start_game',{p_pass:pass.id,p_game:g.id}));if(!rows?.length)throw Error('无法开启游戏');session=rows[0];state.activeSession=session;
  showSheet(titles[g.slug]?.[0]||g.title,'LET THE GAME BEGIN');
  if(g.slug==='moon-dice')await playDice(session.result_key);
  else if(g.slug==='mystery-card')await playPick(true);
  else if(g.slug==='mystery-box')await playPick(false);
  else if(g.slug==='reaction-test')await playReaction();
  else if(g.slug==='stop-the-bar')await playStopBar();
  else throw Error('游戏暂时不可用');
  $('gameProgress').innerHTML='<span class="spinner" style="display:inline-block;vertical-align:middle"></span> 正在确认并保存你的奖励…';
  const rowsDone=unpack(await db.rpc('yt_finish_game',{p_session:session.session_id}));if(!rowsDone?.length)throw Error('奖励暂未存档，请点击恢复');
  state.activeSession=null;await Promise.all([wallet(true),refreshPasses()]);await showGameWon(rowsDone[0].reward_name);
 }catch(e){if(session){showSheet('网络连接不稳定','RESUME PLAY');sheetHtml('<div class="sheet-content"><p>游戏记录保存在服务器。你可以继续提交，不会重复扣除游戏机会或重复发奖。</p><button id="resumeGame" class="button button-primary wide">恢复并领取奖励</button></div>');$('resumeGame').onclick=()=>pending($('resumeGame'),async()=>{const done=unpack(await db.rpc('yt_finish_game',{p_session:session.session_id}));if(!done?.length)throw Error('还无法结算，请稍后重试');state.activeSession=null;await Promise.all([wallet(true),refreshPasses()]);await showGameWon(done[0].reward_name);});}throw e;}
 finally{state.gamePlaying=false;}
}
async function existingGamePass(){await refreshPasses();const p=state.passes.find(p=>p.status==='claimed'&&millis(p.expires_at)>Date.now());if(!p)throw Error('还没有游戏机会，请先扫描员工二维码');await chooseGame(p);}
async function prizeBoard(){const board=unpack(await db.rpc('yt_prize_board'));state.board=board||[];showSheet('奖品公示','REWARD DISCLOSURE');if(!board?.length){sheetHtml('<div class="empty-state">当前还没有开放的活动奖池。</div>');return;}const groups=new Map();for(const row of board){const key=row.campaign_name+' · '+row.game_slug;if(!groups.has(key))groups.set(key,[]);groups.get(key).push(row);}const root=document.createElement('div');root.className='sheet-content';root.innerHTML='<p>下列为当前开放活动的奖品及按服务器设置计算的概率。库存或活动设置变化时，概率也可能变化。</p>';
 for(const [name,rows] of groups){const box=document.createElement('div');box.className='prize-group';box.innerHTML=`<div class="prize-head"><b>${esc(rows[0].game_title)}</b><span>${esc(rows[0].campaign_name)}</span></div>`;
 for(const r of rows){const line=document.createElement('div');line.className='prize-row';line.innerHTML=`<div><strong>${esc(r.reward_name)}</strong><small>${esc(r.description||r.redeem_rules||'兑换规则以奖品详情为准')}</small></div><span class="prize-rate">${Number(r.probability).toFixed(2)}%</span>`;box.append(line);}root.append(box);}const note=document.createElement('p');note.textContent='中奖奖励会自动进入钱包，实际可用日期以具体奖励为准。';root.append(note);$('sheetBody').append(root);}

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

function ownTab(name){for(const [a,id] of [['issue','ownerIssueTab'],['campaigns','ownerCampaignTab'],['team','ownerTeamTab'],['insights','ownerInsightsTab']])$(id).classList.toggle('hide',a!==name);for(const b of document.querySelectorAll('[data-worktab]'))b.classList.toggle('active',b.dataset.worktab===name);if(name==='insights')loadInsights().catch(e=>toast(errorText(e),true));}
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
async function ownerOffer(){const reward=$('issueReward').value;if(!reward)throw Error('请先创建或选择奖品');const start=datetimeMY($('offerFrom').value),end=datetimeMY($('offerUntil').value);if(!end)throw Error('请设置领取截止时间');const n=Number($('offerTotal').value),per=Number($('offerPerUser').value);const raw=uuid();unpack(await db.rpc('yt_create_offer',{p_reward:reward,p_token:raw,p_from:start,p_until:end,p_max:n,p_per_user:per}));const name=state.rewards.find(r=>r.id===reward)?.name||'Yetipsy Reward';await showCodeSheet('领取这份专属好礼',`${name} · 每账户最多 ${per} 次 · 总共 ${n} 份；截止 ${fmt(end)}。`,newLink('gift',raw));}
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
 $('heroScan').onclick=()=>openScanner('claim');$('accountChangePin').onclick=()=>changeMyPin().catch(e=>toast(errorText(e),true));$('privacyNotice').onclick=()=>{showSheet('会员隐私与资料用途','YETIPSY PLAY');sheetHtml('<div class="sheet-content"><p>我们收集手机号码、昵称、完整出生日期和会员活动记录，用于账户登录、年龄检查、会员福利、奖品发放及现场身份核验。手机号目前不通过短信验证。</p><p>PIN 由服务器保护，员工无法查看。生日不会在公开奖品榜或其他顾客页面展示。奖励及核销操作会保留必要记录。</p><p>营销消息为自愿选项，可向店主申请修改。需要更正资料或查询删除安排，请到 Yetipsy 联系店主。</p><p>继续注册表示你已阅读本说明。</p></div>');};$('openExistingPass').onclick=()=>existingGamePass().catch(e=>toast(errorText(e),true));
 $('homePrizes').onclick=()=>prizeBoard().catch(e=>toast(errorText(e),true));$('accountPrizes').onclick=()=>prizeBoard().catch(e=>toast(errorText(e),true));$('publicBoardFromAuth').onclick=()=>prizeBoard().catch(e=>toast(errorText(e),true));
 $('homeWallet').onclick=()=>navigate('wallet');$('walletRefresh').onclick=()=>wallet().catch(e=>toast(errorText(e),true));$('accountScan').onclick=()=>openScanner('claim');
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
async function boot(){bindEvents();changeAuthMode('phone');initialiseOfferDates();if(!configured){$('authError').textContent='配置缺失，请联系店主';shell(false);return;}
 const {data:{session}}=await db.auth.getSession();
 if(session){try{await initialize();}catch(e){console.error('Initialization:',e);toast('连接失败：'+errorText(e),true);}}else shell(false);
 db.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT'){state.user=null;state.role=null;state.profile=null;shell(false);changeAuthMode('phone');}});
 const qs=new URL(location.href).searchParams;
 if(qs.has('reset')){try{await showResetFlow(qs.get('reset'));}catch(e){toast(errorText(e),true);}}
 else if(qs.has('claim')||qs.has('gift')){
  const kind=qs.has('claim')?'claim':'gift';try{await previewClaim(qs.get(kind),kind);}catch(e){toast(errorText(e),true);}
 }
 if('serviceWorker'in navigator&&location.protocol==='https:'&&location.pathname.includes('/play-v12/'))navigator.serviceWorker.register('./sw.js').catch(()=>{});
}
boot().catch(e=>{console.error('Boot:',e);shell(false);$('authError').textContent='系统暂时无法启动：'+errorText(e);});
