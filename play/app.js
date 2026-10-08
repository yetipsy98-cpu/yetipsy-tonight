import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';

const $ = id => document.getElementById(id);
const show = (id, visible) => $(id).classList.toggle('hide', !visible);
const escapeHTML = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const uuid = () => crypto.randomUUID();
const config = window.YETIPSY_PLAY_CONFIG || {};
const ready = /^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(config.url || '') && /^sb_publishable_/.test(config.publishableKey || '');
const db = ready ? createClient(config.url, config.publishableKey, {auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}) : null;
const formatTime = d => d ? new Intl.DateTimeFormat('zh-MY',{timeZone:'Asia/Kuala_Lumpur',dateStyle:'medium',timeStyle:'short'}).format(new Date(d)) : '—';
let user = null, role = null, games = [], rewards = [], selectedRewardToken = null, activeGame = null, lastPassLink = '', lastRedeemLink = '', tokenTimer = null;
let refreshBusy = false;
let ownerCampaigns=[],ownerGames=[],ownerEntries=[],ownerAssignedGames=[];

function alertUser(text, error=false) {
  const box=$('toast');box.textContent=text;box.style.borderColor=error?'#b4564b':'#957044';
  box.classList.add('visible');setTimeout(()=>box.classList.remove('visible'),4500);
}
function result(x){if(x.error)throw Error(x.error.message || '服务器请求失败');return x.data;}
async function guarded(button, task){if(button.disabled)return;button.disabled=true;try{await task();}catch(e){alertUser(e.message||'操作失败',true);}finally{button.disabled=false;}}
function switchTab(tab){document.querySelectorAll('.tab-page').forEach(el=>el.classList.toggle('hide',el.id!==tab));document.querySelectorAll('[data-tab]').forEach(el=>el.classList.toggle('active',el.dataset.tab===tab));}
function tokenFrom(text, name='claim') {
  let raw=String(text||'').trim();
  try{const url=new URL(raw);raw=url.searchParams.get(name)||url.searchParams.get('claim')||url.searchParams.get('redeem')||'';}catch{}
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(raw))throw Error('请输入完整的二维码链接或兑换码');
  return raw;
}
// Some in-app browsers block sessionStorage. Keep an in-memory fallback so staff actions never freeze.
const volatileRequests=new Map();
const safeSession={
 getItem(key){try{return sessionStorage.getItem(key)??volatileRequests.get(key)??null;}catch{return volatileRequests.get(key)??null;}},
 setItem(key,value){volatileRequests.set(key,value);try{sessionStorage.setItem(key,value);}catch{}},
 removeItem(key){volatileRequests.delete(key);try{sessionStorage.removeItem(key);}catch{}}
};
function request(kind, signature){const key='ytplay:req:'+kind;const old=safeSession.getItem(key);if(old){try{const parsed=JSON.parse(old);if(parsed.signature===signature)return parsed;}catch{}}
 const data={id:uuid(),token:uuid(),signature};safeSession.setItem(key,JSON.stringify(data));return data;}
function clearRequest(kind){safeSession.removeItem('ytplay:req:'+kind);}
async function qr(canvas, value){if(window.QRCode?.toCanvas){canvas.hidden=false;await window.QRCode.toCanvas(canvas,value,{width:220,margin:1,errorCorrectionLevel:'M'});}else{canvas.hidden=true;alertUser('二维码库暂时未加载，可以复制下方链接。',true);}}
function blank(el,message){el.innerHTML=`<div class="item muted">${escapeHTML(message)}</div>`;}
function isOwner(){return role==='owner';}function isStaff(){return role==='staff'||role==='owner';}
function sameOriginLink(query, token){const url=new URL(location.href);url.hash='';url.search='';url.searchParams.set(query,token);return url.toString();}

async function wallet(){
 if(!user)return;
 const items=result(await db.from('user_rewards').select('id,status,created_at,redeem_after,expires_at,rewards(name,description)').eq('customer_id',user.id).order('created_at',{ascending:false}).limit(100));
 const el=$('walletList');el.replaceChildren();if(!items.length)return blank(el,'还没有奖励。玩游戏或由 Owner 发放后，会自动显示在这里。');
 for(const item of items){const expired=Date.parse(item.expires_at)<=Date.now(),tooEarly=Date.parse(item.redeem_after)>Date.now();const redeemable=item.status==='available'&&!expired&&!tooEarly;
  const state=item.status==='redeemed'?'已核销':expired?'已过期':item.status==='revoked'?'已作废':tooEarly?'次日起可兑换':'可兑换';
  const card=document.createElement('div');card.className='item';
  card.innerHTML=`<span class="chip">${escapeHTML(state)}</span><b>${escapeHTML(item.rewards?.name||'Reward')}</b><div class="meta">获得：${escapeHTML(formatTime(item.created_at))}</div><div class="meta">有效期：${escapeHTML(formatTime(item.expires_at))}</div>`;
  if(redeemable){const button=document.createElement('button');button.textContent='出示 60 秒兑奖二维码';button.onclick=()=>guarded(button,()=>makeRedeem(item.id));card.append(button);}
  el.append(card);
 }
}
async function makeRedeem(award){const raw=uuid();const deadline=result(await db.rpc('yt_make_redeem',{p_award:award,p_token:raw}));
 lastRedeemLink=sameOriginLink('redeem',raw);show('redeemCustomerResult',true);$('redeemUrl').textContent=lastRedeemLink;await qr($('redeemQr'),lastRedeemLink);
 clearInterval(tokenTimer);const tick=()=>{const seconds=Math.max(0,Math.ceil((Date.parse(deadline)-Date.now())/1000));$('redeemCountdown').textContent=seconds?`兑奖二维码 ${seconds} 秒后过期`:'已过期，请重新生成';if(!seconds)clearInterval(tokenTimer);};tick();tokenTimer=setInterval(tick,1000);
 $('redeemCustomerResult').scrollIntoView({behavior:'smooth',block:'center'});
}
async function loadGames(){games=result(await db.from('games').select('id,slug,title,mode,active').eq('active',true).order('slug'));}
async function passes(){
 if(!user)return;const items=result(await db.from('game_passes').select('id,status,claimed_at,expires_at,campaign_id').eq('customer_id',user.id).order('created_at',{ascending:false}).limit(40));
 const root=$('passList');root.replaceChildren();if(!items.length)return blank(root,'还没有 Game Pass，让员工生成一个二维码给你扫码。');
 for(const p of items){const usable=p.status==='claimed' && new Date(p.expires_at)>new Date();const el=document.createElement('div');el.className='item';
  el.innerHTML=`<span class="chip">${usable?'可玩':p.status==='used'?'已完成':p.status==='claimed'?'已过期':escapeHTML(p.status)}</span><b>Game Pass</b><div class="meta">领取：${escapeHTML(formatTime(p.claimed_at))}</div><div class="meta">有效期：${escapeHTML(formatTime(p.expires_at))}</div>`;
  if(usable){const b=document.createElement('button');b.textContent='选择游戏';b.onclick=()=>chooseGame(p);el.append(b);}
  root.append(el);
 }
}
async function chooseGame(pass){const assigned=result(await db.from('campaign_games').select('game_id').eq('campaign_id',pass.campaign_id));const allowed=new Set(assigned.map(x=>x.game_id));
 const available=games.filter(g=>allowed.has(g.id)&&['chance','skill'].includes(g.mode));const area=$('gameArea');area.replaceChildren();show('gameArea',true);
 const h=document.createElement('h3');h.textContent='CHOOSE YOUR GAME';area.append(h);
 const grid=document.createElement('div');grid.className='game-choices';area.append(grid);
 for(const g of available){const b=document.createElement('button');b.className='game-choice';b.innerHTML=`<strong>${({ 'moon-dice':'🎲','mystery-card':'🃏','mystery-box':'🎁','reaction-test':'⚡','stop-the-bar':'🎯' }[g.slug]||'🎮')}</strong><span>${escapeHTML(g.title)}</span>`;
  b.onclick=()=>guarded(b,()=>startGame(pass,g));grid.append(b);}
 if(!available.length)blank(area,'这个活动目前没有开放的游戏。');area.scrollIntoView({behavior:'smooth',block:'start'});
}
const die=['','⚀','⚁','⚂','⚃','⚄','⚅'];
function faces(tier){let n=tier==='R5'?5:tier==='R4'?4:tier==='R3'?3:Math.floor(Math.random()*3);const arr=[...Array(n)].map(()=>1);while(arr.length<5)arr.push(2+Math.floor(Math.random()*5));return arr.sort(()=>Math.random()-.5);}
function animation(g,tier){const v=$('gameVisual');v.replaceChildren();v.className='game-visual active';
 if(g.slug==='moon-dice'){const dice=faces(tier);v.innerHTML='<div class="rolling-dice">'+dice.map(()=>'<span>⚄</span>').join('')+'</div><div class="stage-caption">SHAKING…</div>';
   return()=>{v.innerHTML='<div class="rolling-dice revealed">'+dice.map(x=>`<span>${die[x]}</span>`).join('')+'</div><div class="stage-caption">${dice.filter(x=>x===1).length} × ⚀</div>';};
 }
 v.innerHTML='<div class="mystery-reveal"><div>✦</div><div>'+(g.slug==='mystery-card'?'🃏':'🎁')+'</div><div>UNLOCKING…</div></div>';
 return()=>{v.innerHTML='<div class="mystery-reveal revealed"><div>✦</div><div>🎉</div><div>REWARD UNLOCKED</div></div>';};
}
// Skill scores are strictly an interactive display; the reward is determined server-side.
// No network calls occur while either skill animation is running.
function playSkill(g){
 const stage=$('gameVisual');stage.replaceChildren();stage.className='game-visual active';
 const wrap=document.createElement('div');wrap.className='skill-stage';stage.append(wrap);
 if(g.slug==='reaction-test'){
   wrap.innerHTML='<div class="skill-label" id="skillSignal">WAIT FOR GREEN</div><button class="skill-tap" type="button" id="skillTap">WAIT…</button><div class="meta">变成绿色时，立即点击！</div>';
   const signal=wrap.querySelector('#skillSignal'),tap=wrap.querySelector('#skillTap');
   let greenAt=0,done=false;
   return new Promise(resolve=>{
     let alarm=null,guard=null;
     const finish=message=>{if(done)return;done=true;clearTimeout(alarm);clearTimeout(guard);tap.disabled=true;signal.textContent=message;resolve(message);};
     alarm=setTimeout(()=>{if(done)return;greenAt=performance.now();tap.textContent='TAP!';tap.classList.add('go');signal.textContent='NOW!';},1300+Math.random()*1800);
     guard=setTimeout(()=>finish('TIME OUT'),9500);
     tap.onclick=()=>{if(!greenAt){finish('FALSE START · 抢跑');return;}finish(Math.round(performance.now()-greenAt)+' ms');};
   });
 }
 if(g.slug==='stop-the-bar'){
   wrap.innerHTML='<div class="skill-label">STOP AT THE CENTER</div><div class="skill-track"><div class="skill-target"></div><div class="skill-marker" id="skillMarker"></div></div><button class="secondary skill-stop" type="button" id="skillStop">STOP!</button><div class="meta">瞄准中间，考验你的反应！</div>';
   const marker=wrap.querySelector('#skillMarker'),stop=wrap.querySelector('#skillStop');
   const start=performance.now();let done=false,frame=0,position=.0;
   return new Promise(resolve=>{
     const animate=t=>{if(done)return;const phase=((t-start)/1500)%2;position=phase<=1?phase:2-phase;marker.style.left=(position*100)+'%';frame=requestAnimationFrame(animate);};
     frame=requestAnimationFrame(animate);
     const finish=()=>{if(done)return;done=true;cancelAnimationFrame(frame);stop.disabled=true;const accuracy=Math.max(0,Math.round((1-Math.abs(position-.5)*2)*100));resolve('ACCURACY '+accuracy+'%');};
     stop.onclick=finish;setTimeout(finish,8500);
   });
 }
 throw Error('这个游戏尚未开放');
}
async function startGame(pass,g){if(activeGame)return;const stage=$('gameArea');stage.querySelectorAll('button').forEach(b=>b.disabled=true);
 try{
  const rows=result(await db.rpc('yt_start_game',{p_pass:pass.id,p_game:g.id}));if(!rows?.length)throw Error('无法开启游戏');const started=rows[0];activeGame=started;
  show('gameStage',true);$('gameTitle').textContent=g.title;$('gameStatus').textContent='游戏正在进行，动画会在本机完成';
  const began=performance.now();
  if(g.mode==='skill'){
    const skillScore=await playSkill(g);
    $('gameStatus').textContent=skillScore+' · 挑战分数仅供娱乐，奖品由服务器独立抽取';
  }else{
    const reveal=animation(g,started.result_key);
    await new Promise(resolve=>setTimeout(resolve,2800));reveal();
  }
  const minWait=Math.max(0,2150-(performance.now()-began));if(minWait)await new Promise(r=>setTimeout(r,minWait));
  $('gameStatus').textContent='正在安全保存游戏奖励…';
  const resultRows=result(await db.rpc('yt_finish_game',{p_session:started.session_id}));if(!resultRows?.length)throw Error('未收到奖励，请按恢复按钮重新提交');
  $('gameStatus').innerHTML=`<b>🎉 ${escapeHTML(resultRows[0].reward_name)}</b><div class="meta">已自动存入 My Rewards</div>`;
  show('gameRetry',false);activeGame=null;await Promise.all([wallet(),passes()]);
 }catch(e){alertUser(e.message,true);$('gameStatus').textContent='游戏记录已保留，请点击恢复提交。';show('gameRetry',true);}
 finally{stage.querySelectorAll('button').forEach(b=>b.disabled=false);}
}
async function retryGame(){if(!activeGame)return;const rows=result(await db.rpc('yt_finish_game',{p_session:activeGame.session_id}));
 if(!rows?.length)throw Error('尚未能完成，请保持网络后重试');$('gameStatus').textContent=`奖励已保存：${rows[0].reward_name}`;activeGame=null;show('gameRetry',false);await Promise.all([passes(),wallet()]);}

async function loadStaff(){if(!isStaff())return;const items=result(await db.from('campaigns').select('id,name,starts_at,ends_at').eq('active',true));
 $('campaign').replaceChildren();for(const c of items)$('campaign').add(new Option(c.name,c.id));if(!items.length)alertUser('还没有开放的活动',true);
}
async function loadOwnerMetrics(){
 if(!isOwner())return;
 const tables=[['profiles','ownerCustomers'],['game_passes','ownerPasses'],['user_rewards','ownerRewards'],['redemptions','ownerRedemptions']];
 const results=await Promise.all(tables.map(async ([table,id])=>{
   const {count,error}=await db.from(table).select('id',{count:'exact',head:true});
   if(error)throw error;
   return [id,count??0];
 }));
 for(const [id,count] of results)$(id).textContent=new Intl.NumberFormat('en-MY').format(count);
}
async function loadOwner(){
 if(!isOwner())return;
 const prevCampaign=$('ownerCampaign').value;
 const [customers,rewardList,campaignList,gameList]=await Promise.all([
  db.from('profiles').select('id,display_name,phone').order('created_at',{ascending:false}).limit(200),
  db.from('rewards').select('id,name').eq('active',true).order('created_at',{ascending:false}),
  db.from('campaigns').select('id,name,active,starts_at,ends_at').order('created_at',{ascending:false}),
  db.from('games').select('id,slug,title,active').eq('active',true).order('slug')]);
 const p=result(customers),r=result(rewardList);rewards=r;ownerCampaigns=result(campaignList);ownerGames=result(gameList);
 $('issueCustomer').replaceChildren();$('issueReward').replaceChildren();$('ownerCampaign').replaceChildren();
 for(const customer of p)$('issueCustomer').add(new Option(customer.display_name||customer.phone||'Customer '+customer.id.slice(0,8),customer.id));
 for(const award of r)$('issueReward').add(new Option(award.name,award.id));
 for(const c of ownerCampaigns)$('ownerCampaign').add(new Option((c.active?'🟢 ':'⚫ ')+c.name,c.id));
 if(ownerCampaigns.some(c=>c.id===prevCampaign))$('ownerCampaign').value=prevCampaign;
 await loadCampaignDetail();
}
async function loadCampaignDetail(){
 if(!isOwner())return;
 const campaignId=$('ownerCampaign').value;
 if(!campaignId)return;
 const campaign=ownerCampaigns.find(c=>c.id===campaignId);
 if(!campaign)return;
 const [gameMap,poolRows]=await Promise.all([
  db.from('campaign_games').select('game_id').eq('campaign_id',campaignId),
  db.from('reward_pool_entries').select('id,game_id,result_key,reward_id,weight').eq('campaign_id',campaignId)
 ]);
 if($('ownerCampaign').value!==campaignId)return;
 ownerAssignedGames=result(gameMap).map(x=>x.game_id);ownerEntries=result(poolRows);
 $('ownerActive').checked=campaign.active;
 const gameRoot=$('ownerGameSettings');gameRoot.replaceChildren();
 for(const g of ownerGames){
   const lab=document.createElement('label');lab.className='owner-game-row';
   const cb=document.createElement('input');cb.type='checkbox';cb.checked=ownerAssignedGames.includes(g.id);
   const name=document.createElement('span');name.textContent=g.title;
   cb.onchange=async()=>{
     const want=cb.checked;cb.disabled=true;
     try{result(await db.rpc('yt_owner_set_game',{p_campaign:campaignId,p_game:g.id,p_enabled:want}));alertUser('已更新开放游戏');await loadCampaignDetail();}
     catch(e){cb.checked=!want;alertUser(e.message||'更改失败',true);}
     finally{cb.disabled=false;}
   };
   lab.append(cb,name);gameRoot.append(lab);
 }
 const previous=$('ownerPoolGame').value;$('ownerPoolGame').replaceChildren();
 for(const g of ownerGames)$('ownerPoolGame').add(new Option(g.title,g.id));
 if(ownerGames.some(x=>x.id===previous))$('ownerPoolGame').value=previous;
 renderOwnerPool();
}
function renderOwnerPool(){
 const game=$('ownerPoolGame').value,root=$('ownerPoolRows');root.replaceChildren();
 const sorted=ownerEntries.filter(e=>e.game_id===game).sort((a,b)=>a.result_key.localeCompare(b.result_key));
 for(const entry of sorted){
   const row=document.createElement('div');row.className='owner-pool-row';
   const label=document.createElement('b');label.textContent=entry.result_key;
   const select=document.createElement('select');select.setAttribute('aria-label','奖品 '+entry.result_key);
   for(const r of rewards)select.add(new Option(r.name,r.id));select.value=entry.reward_id;
   const weight=document.createElement('input');weight.type='number';weight.min='1';weight.max='10000';weight.value=entry.weight;weight.setAttribute('aria-label','权重 '+entry.result_key);
   const btn=document.createElement('button');btn.textContent='保存';btn.className='mini';
   btn.onclick=()=>guarded(btn,async()=>{
     result(await db.rpc('yt_owner_set_pool',{p_entry:entry.id,p_reward:select.value,p_weight:Number(weight.value)}));
     alertUser('奖励池已保存');await loadCampaignDetail();
   });
   row.append(label,select,weight,btn);root.append(row);
 }
 if(!sorted.length)blank(root,'此游戏尚无奖励池。请复制含有奖池的活动。');
}
function showIdentity(ok){show('setup',!ready);show('auth',ready&&!ok);show('dashboard',ready&&ok);show('logout',ok);$('connection').textContent=!ready?'待配置':ok?'已连接':'需要登入';}
async function init(){if(!ready)return showIdentity(false);const {data:{user:current},error}=await db.auth.getUser();if(error&&error.name!=='AuthSessionMissingError')console.warn('Auth:',error.message);
 user=current||null;if(!user){role=null;showIdentity(false);return;}
 const r=result(await db.from('staff_roles').select('role').eq('user_id',user.id).eq('active',true).maybeSingle());role=r?.role||null;
 showIdentity(true);$('accountText').textContent=user.email||user.phone||'Yetipsy Member';$('roleTitle').textContent=isOwner()?'OWNER ACCESS':isStaff()?'STAFF ACCESS':'CUSTOMER ACCESS';
 document.querySelectorAll('[data-tab="staff"]').forEach(el=>el.classList.toggle('hide',!isStaff()));document.querySelectorAll('[data-tab="owner"]').forEach(el=>el.classList.toggle('hide',!isOwner()));
 if(refreshBusy)return;refreshBusy=true;
 try{await Promise.all([wallet(),loadGames(),passes(),...(isStaff()?[loadStaff()]:[]),...(isOwner()?[loadOwner(),loadOwnerMetrics()]:[])]);}finally{refreshBusy=false;}
 const q=new URL(location.href).searchParams;
 if(q.get('redeem')&&isStaff()){$('redeemToken').value=q.get('redeem');switchTab('staff');}
 else if(q.get('claim')){$('claimToken').value=q.get('claim');switchTab('passes');}
 else switchTab('wallet');
}
$('loginForm').addEventListener('submit',event=>{event.preventDefault();guarded(event.submitter,async()=>{
 const callback=new URL(location.href);callback.hash='';const {error}=await db.auth.signInWithOtp({email:$('email').value.trim(),options:{emailRedirectTo:callback.href,shouldCreateUser:true}});
 if(error)throw error;$('authMessage').textContent='验证邮件已发送，请打开邮箱点击登录链接。';});});
$('logout').onclick=async()=>{const {error}=await db.auth.signOut();if(error)return alertUser(error.message,true);role=null;user=null;showIdentity(false);};
document.querySelectorAll('[data-tab]').forEach(btn=>btn.onclick=()=>switchTab(btn.dataset.tab));
$('refreshWallet').onclick=()=>wallet().catch(e=>alertUser(e.message,true));
$('refreshOwner').onclick=()=>loadOwnerMetrics().catch(e=>alertUser(e.message,true));
$('ownerCampaign').onchange=()=>loadCampaignDetail().catch(e=>alertUser(e.message,true));
$('ownerPoolGame').onchange=renderOwnerPool;
$('ownerSaveCampaign').onclick=event=>guarded(event.currentTarget,async()=>{
 const active=$('ownerActive').checked;
 result(await db.rpc('yt_owner_set_campaign',{p_campaign:$('ownerCampaign').value,p_active:active}));
 alertUser(active?'活动已开放':'活动已暂停');await Promise.all([loadOwner(),loadStaff()]);
});
$('ownerCloneForm').onsubmit=event=>{event.preventDefault();guarded(event.submitter,async()=>{
 const campaignId=result(await db.rpc('yt_owner_clone_campaign',{p_source:$('ownerCampaign').value,p_name:$('ownerCloneName').value.trim()}));
 $('ownerCloneName').value='';await loadOwner();$('ownerCampaign').value=campaignId;await loadCampaignDetail();
 alertUser('已复制为关闭状态的新活动，确认内容后再开放');
});};
$('refreshPasses').onclick=()=>passes().catch(e=>alertUser(e.message,true));
$('claimForm').onsubmit=event=>{event.preventDefault();guarded(event.submitter,async()=>{
 result(await db.rpc('yt_claim_pass',{p_token:tokenFrom($('claimToken').value,'claim')}));$('claimToken').value='';
 const u=new URL(location.href);u.searchParams.delete('claim');history.replaceState(null,'',u.href);
 alertUser('Game Pass 已经进入你的账户！');await passes();});};
$('passForm').onsubmit=event=>{event.preventDefault();guarded(event.submitter,async()=>{
 const payload=$('campaign').value+':'+$('passExpiry').value;const req=request('pass',payload);
 const data=result(await db.rpc('yt_issue_pass',{p_campaign:$('campaign').value,p_request:req.id,p_token:req.token,p_minutes:Number($('passExpiry').value)}));
 if(!data?.length)throw Error('创建失败');lastPassLink=sameOriginLink('claim',req.token);show('passResult',true);$('passLink').textContent=lastPassLink;
 await qr($('passQr'),lastPassLink);clearRequest('pass');alertUser('游戏二维码已生成');});};
$('lookupForm').onsubmit=event=>{event.preventDefault();guarded(event.submitter,async()=>{
 const raw=tokenFrom($('redeemToken').value,'redeem');const rows=result(await db.rpc('yt_lookup_redeem',{p_token:raw}));
 if(!rows?.length)throw Error('查无此兑奖码');selectedRewardToken=rows[0].valid?raw:null;
 show('lookupResult',true);$('lookupDetails').textContent=`${rows[0].reward_name} · ${rows[0].valid?'可核销':'不可核销 / 已过期 / 已使用'}`;
 $('confirmRedeem').disabled=!rows[0].valid;});};
$('confirmRedeem').onclick=event=>{if(!selectedRewardToken)return;guarded(event.currentTarget,async()=>{
 const token=selectedRewardToken;const req=request('redeem',token);
 const rows=result(await db.rpc('yt_redeem',{p_token:token,p_request:req.id}));
 if(!rows?.length)throw Error('服务器没有返回兑奖回执');clearRequest('redeem');selectedRewardToken=null;
 $('lookupDetails').textContent=`✓ 已核销：${rows[0].reward_name} · REF ${rows[0].receipt_id.slice(0,8).toUpperCase()}`;
 $('confirmRedeem').disabled=true;alertUser('已核销并保存到数据库');await wallet();});};
$('rewardForm').onsubmit=event=>{event.preventDefault();guarded(event.submitter,async()=>{
 result(await db.rpc('yt_create_reward',{p_name:$('rewardName').value,p_description:'',p_validity:Number($('rewardDays').value),p_next_day:$('nextDay').checked}));
 $('rewardName').value='';alertUser('奖励已创建');await loadOwner();});};
$('issueForm').onsubmit=event=>{event.preventDefault();guarded(event.submitter,async()=>{
 if(!confirm('确认发放此奖励？'))return;
 const signature=$('issueCustomer').value+':'+$('issueReward').value;const req=request('issue',signature);
 result(await db.rpc('yt_send_reward',{p_customer:$('issueCustomer').value,p_reward:$('issueReward').value,p_request:req.id}));
 clearRequest('issue');alertUser('奖励已发放');await wallet();});};
$('gameRetry').onclick=event=>guarded(event.currentTarget,retryGame);
$('copyPass').onclick=()=>navigator.clipboard.writeText(lastPassLink).then(()=>alertUser('已复制')).catch(()=>alertUser('复制失败',true));
$('copyRedeem').onclick=()=>navigator.clipboard.writeText(lastRedeemLink).then(()=>alertUser('已复制')).catch(()=>alertUser('复制失败',true));
if(ready){db.auth.onAuthStateChange(event=>{if(['SIGNED_IN','SIGNED_OUT','INITIAL_SESSION','TOKEN_REFRESHED'].includes(event))setTimeout(()=>init().catch(e=>alertUser(e.message,true)),0);});
 init().catch(e=>alertUser('连接错误：'+e.message,true));if('serviceWorker'in navigator)navigator.serviceWorker.register('./sw.js').catch(()=>{});}
else showIdentity(false);
