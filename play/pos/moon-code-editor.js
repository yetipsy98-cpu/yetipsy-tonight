
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const labels={R5:'断片指南 · 任一杯',R4:'微醺特调 · 任一杯',R3:'彩虹 Shot ×1',R0:'RM5 抵扣券'};
const stateLabels={available:'可使用',reserved:'已锁定在订单',redeemed:'已核销'};
export function createMoonCodeEditor({db,root,isOwner,notice}){
 let saving=false;let records=[];
 const today=()=>new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Kuala_Lumpur',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
 function mount(){
  root.innerHTML='<article class="card"><p class="kicker">MOON GAME · LEGACY CODES</p><h2>手动录入旧 Moon 兑换码</h2>'+
   '<p class="muted">不用顾客注册。把顾客原本收到的 YT-MOON-XXXXXXXX 逐张输入即可；旧系统已经兑换的代码请勾选，防止重复使用。</p>'+
   '<form id="moonCodeForm" class="stack"><label>旧兑换码<input id="moonCodeInput" required autocomplete="off" maxlength="32" autocapitalize="characters" spellcheck="false" placeholder="YT-MOON-A1B2C3D4"></label>'+
   '<label>奖励类型<select id="moonKind"><option value="R5">R5 · 断片指南任一杯</option><option value="R4">R4 · 微醺特调任一杯</option><option value="R3">R3 · 彩虹 Shot</option><option value="R0">R0 · RM5 Voucher</option></select></label>'+
   '<div class="pair"><label>原领取日期<input id="moonIssued" type="date" required></label><label>有效期至<input id="moonUntil" type="date" required></label></div>'+
   '<label class="checkline"><input id="moonAlreadyUsed" type="checkbox"> 这张旧码已经在 Moon 系统核销过（只存档，不可再次兑奖）</label>'+
   '<label>内部备注（选填）<input id="moonNote" maxlength="300" placeholder="例如：已通过 WhatsApp 通知"></label>'+
   '<button id="moonAddButton" type="submit" class="main-button">保存这张兑换码</button><p id="moonFormStatus" role="status"></p></form></article>'+
   '<article class="card"><div class="block-head"><div><h3>已经录入的兑换码</h3><p class="muted" id="moonCount"></p></div><button id="moonReload" class="quiet" type="button">刷新</button></div><div id="moonList"></div></article>';
  root.querySelector('#moonIssued').value=today();
  root.querySelector('#moonUntil').value='2026-11-11';
  root.querySelector('#moonCodeForm').onsubmit=submit;
  root.querySelector('#moonReload').onclick=()=>load().catch(e=>notice(e.message,true));
 }
 function list(){
  root.querySelector('#moonCount').textContent=records.length+' 张（最近最多显示 500 张）';
  root.querySelector('#moonList').innerHTML=records.length?records.map(r=>'<div class="admin-entry"><div><strong>'+esc(r.code)+'</strong><small>'+esc(labels[r.kind]||r.kind)+' · '+esc(stateLabels[r.status]||r.status)+' · 有效至 '+esc(r.until)+'</small></div><span>'+esc(r.status==='redeemed'?'已使用':r.status==='reserved'?'订单已锁码':'有效')+'</span></div>').join(''):'<p class="empty">还没有手动录入的旧 Moon 兑换码。</p>';
 }
 async function load(){
  if(!isOwner())throw Error('owner_only');
  // Render the form before the asynchronous RPC. Without mount() the drawer
  // is empty, and list() throws when it tries to access #moonCount.
  if(!root.querySelector('#moonCodeForm'))mount();
  const listRoot=root.querySelector('#moonList'),status=root.querySelector('#moonFormStatus');
  try{
   const res=await db.rpc('yt_moon_owner_list');if(res.error)throw res.error;
   records=Array.isArray(res.data)?res.data:[];list();
  }catch(error){
   if(listRoot)listRoot.innerHTML='<p class="empty">兑换码列表暂时无法读取。表单已加载，可以点击「刷新」重试。</p>';
   if(status)status.textContent='读取历史记录失败：'+(error.message||'请稍后重试');
   throw error;
  }
 }
 async function submit(e){
  e.preventDefault();if(saving||!isOwner())return;
  saving=true;const button=root.querySelector('#moonAddButton'),status=root.querySelector('#moonFormStatus');
  button.disabled=true;status.textContent='正在保存…';
  const raw=root.querySelector('#moonCodeInput').value;
  const normalized=raw.replace(/[^a-z0-9]/gi,'').toUpperCase();
  if(!/^(YTMOON)?[A-Z0-9]{8}$/.test(normalized)){status.textContent='请输入原始 YT-MOON-XXXXXXXX 兑换码';saving=false;button.disabled=false;return;}
  try{
   const result=await db.rpc('yt_moon_owner_add',{p_code:raw,p_kind:root.querySelector('#moonKind').value,p_issued:root.querySelector('#moonIssued').value,p_until:root.querySelector('#moonUntil').value,p_used:root.querySelector('#moonAlreadyUsed').checked,p_note:root.querySelector('#moonNote').value.trim()});
   if(result.error)throw result.error;
   const code=result.data?.code||raw;status.textContent='已保存 '+code+'，可以继续输入下一张。';
   root.querySelector('#moonCodeInput').value='';root.querySelector('#moonCodeInput').focus();
   root.querySelector('#moonAlreadyUsed').checked=false;root.querySelector('#moonNote').value='';
   notice('已登记 '+code);
   await load();
  }catch(error){
   const translations={moon_duplicate_code:'这张兑换码已经登记，不会重复建立。',moon_invalid_details:'奖励种类或日期不正确。',moon_invalid_code:'兑换码格式不正确。'};
   const msg=translations[error.message]||error.message||'保存失败';status.textContent=msg;notice(msg,true);
  }finally{saving=false;button.disabled=false;}
 }
 return{load,clear(){records=[];}};
}
