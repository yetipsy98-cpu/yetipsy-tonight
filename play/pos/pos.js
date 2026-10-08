import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';

// Yetipsy POS V1. Order creation and payment transitions always execute on Supabase.
// The browser never chooses product prices or changes a paid status directly.
const $=id=>document.getElementById(id);
const conf=window.YETIPSY_PLAY_CONFIG||{};
const portal=document.body.dataset.entry==='cashier'?'cashier':'work';
const usable=/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(conf.url||'')&&/^sb_publishable_/.test(conf.publishableKey||'');
const db=usable?createClient(conf.url,conf.publishableKey,{auth:{storageKey:portal==='cashier'?'yt-cashier-session-v2':'yt-work-session-v1',persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}}):null;
const workURL=(conf.url||'')+'/functions/v1/yt-work-auth';
const state={identity:null,catalog:[],cart:new Map(),currentTab:'create',
  active:[],paid:[],pending:[],seenPending:new Set(),seenInitialized:false,
  currentRequestId:null,refreshing:false,interval:null,noticeTimer:null,activeView:'login',
   series:[],editOrder:null,editCart:new Map(),redeemPending:null,scanStream:null,scanTimer:null};
const msgMap={staff_only:'需要有效员工账号',cashier_only:'需要 Cashier 权限',not_authenticated:'登录已过期，请重新登录',
  order_not_pending:'订单不在待接受状态',order_not_accepted:'订单必须先由 Cashier 接受',order_not_served:'请先完成出品，之后才能收款',
  product_unavailable:'这款产品已停止销售，请重新选择',order_too_large:'单笔订单金额或数量过大',
  invalid_line:'订单产品无效',invalid_order:'订单资料不正确',invalid_channel:'下单渠道无效',invalid_filter:'订单筛选条件无效',
  order_not_found:'找不到这张订单',request_conflict:'重复请求出现冲突，请重新开单',invalid_payment_method:'请选择正确的收款方式',
  order_cannot_cancel:'这张订单不能直接取消，已出品／已付款订单必须走人工处理流程',
  invalid_credentials:'账号或密码错误',owner_only:'只有 Owner 才能更改此设置',too_many_attempts:'错误尝试太多，请稍后再试',
  reason_required:'请填写至少两个字的取消／拒绝原因',
   order_edit_permission_required:'Owner 未开放改单权限',paid_or_served_order_locked:'已付款／已出品订单不能直接改单',order_changed_reload:'订单已被其他员工修改，请刷新后再试',
   invalid_order_revision:'改单必须填写原因并保留至少一个商品',order_benefit_already_assigned:'商品已产生权益，不能直接改单',
   order_not_paid:'请先结账后再生成权益',benefits_after_payment_only:'订单出品并收款后才能发游戏权益',series_not_configured:'请让 Owner 为此产品配置权益系列',
   series_rule_not_ready:'该系列的多次游戏／积分方案暂未开放，请 Owner 先确定规则',unit_already_issued:'该杯已经发过 QR，不能重复发送。可在当前设备找回原码',
   item_not_in_order:'产品不属于这张账单',unit_not_in_order:'找不到对应商品单位',invalid_benefit_request:'选择的商品、活动或领取时限不正确',
   token_invalid:'兑奖码过期或已核销',reward_unavailable:'奖品还不能兑换或已过期',role_mismatch:'请使用正确的 Cashier／Staff 登录入口'};
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const money=v=>'RM'+Number(v||0).toFixed(2);
const stamp=v=>v?new Intl.DateTimeFormat('zh-MY',{timeZone:'Asia/Kuala_Lumpur',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'}).format(new Date(v)):'—';
const unpack=r=>{if(r?.error)throw Error(r.error.message||r.error.code||'server_unavailable');return r.data};
const errorText=e=>{let s=String(e?.message||e||'server_unavailable');return msgMap[s]||s.replaceAll('_',' ')};
const isOwner=()=>state.identity?.can_owner===true;
const isCashier=()=>state.identity?.can_cashier===true;
function showNotice(message,bad=false,persist=false){const n=$('notice');n.textContent=message;n.classList.remove('hidden');n.classList.toggle('error',bad);clearTimeout(state.noticeTimer);if(!persist)state.noticeTimer=setTimeout(()=>n.classList.add('hidden'),6200);}
function busy(btn,fn){if(btn?.disabled)return Promise.resolve();if(btn)btn.disabled=true;return Promise.resolve().then(fn).catch(e=>{showNotice(errorText(e),true);throw e}).finally(()=>{if(btn)btn.disabled=false});}
async function getBearer(){const {data,error}=await db.auth.getSession();if(error||!data.session?.access_token)throw Error('not_authenticated');return data.session.access_token;}
async function work(action,data={},signed=false){const headers={'Content-Type':'application/json',apikey:conf.publishableKey};if(signed)headers.Authorization='Bearer '+await getBearer();const resp=await fetch(workURL,{method:'POST',headers,cache:'no-store',body:JSON.stringify({action,...data})});const res=await resp.json().catch(()=>({ok:false,error:'server_unavailable'}));if(!resp.ok||!res.ok)throw Error(res.error||'server_unavailable');return res;}
function resetLogin(){stopPolling();state.activeView='login';state.identity=null;$('signinForm').classList.remove('hidden');$('firstPasswordForm').classList.add('hidden');$('signin').classList.remove('hidden');$('dashboard').classList.add('hidden');$('logout').classList.add('hidden');$('accountName').textContent='WORK ACCOUNT';}
async function login(e){e.preventDefault();await busy($('signinBtn'),async()=>{
 const username=$('username').value.trim().toLowerCase(),password=$('password').value;
 const result=await work('login',{username,password});
  if(portal==='cashier'&&result.role!=='cashier')throw Error('role_mismatch');
  if(portal==='work'&&result.role==='cashier')throw Error('role_mismatch');
  const {error}=await db.auth.setSession({access_token:result.access_token,refresh_token:result.refresh_token});if(error)throw error;
 if(result.must_change_password){if(portal!=='cashier')throw Error('请先到 Owner／Staff 页面修改首次密码');$('signinForm').classList.add('hidden');$('firstPasswordForm').classList.remove('hidden');$('firstOldPassword').value=password;return;}
 $('password').value='';await launch();
});}
async function launch(){if(!usable){showNotice('尚未配置 /play/config.js 的 Supabase 连接',true,true);return;}
 const identity=unpack(await db.rpc('yt_pos_identity'));if(!identity)throw Error('staff_only');
  if(portal==='cashier'&&identity.role!=='cashier')throw Error('role_mismatch');
  if(portal==='work'&&identity.role==='cashier')throw Error('role_mismatch');
  state.identity=identity;state.activeView='dashboard';$('signin').classList.add('hidden');$('dashboard').classList.remove('hidden');$('logout').classList.remove('hidden');
 $('accountName').textContent=identity.username+' · '+(identity.role==='cashier'?'CASHIER':identity.can_cashier?'POS MANAGER':'STAFF');$('permissionPill').textContent=identity.can_owner?'OWNER':identity.role==='cashier'?'CASHIER':identity.can_cashier?'STAFF + CASHIER':'STAFF';
 $('cashierCreateChoice').classList.toggle('hidden',!isCashier());$('cashierDirect').checked=isCashier();
 $('createHint').textContent=isCashier()?'选择 Cashier 自开单即可自动接受；取消勾选将作为 Staff 单提交审核。':'Staff 点单后等待 Cashier 接受，自动进入对方的待审核队列。';
 buildNav();await Promise.all([loadCatalog(),refreshOrders(false)]);showTab(new URL(location.href).searchParams.get('tab')==='benefits'?'benefits':new URL(location.href).searchParams.get('tab')==='redeem'?'redeem':'create');startPolling();
}
async function changeCashierFirstPassword(e){e.preventDefault();const button=e.submitter;await busy(button,async()=>{
 const oldPw=$('firstOldPassword').value,newPw=$('firstNewPassword').value;
 if(newPw!==$('firstNewAgain').value)throw Error('两次输入的新密码不一致');
 const username=$('username').value.trim().toLowerCase();
 if(newPw.length<12||newPw.length>128||!/[A-Z]/.test(newPw)||!/[a-z]/.test(newPw)||!/\d/.test(newPw)||newPw.toLowerCase().includes(username))throw Error('新密码至少12位，需包含大小写字母及数字，不能含用户名');
 await work('password_change',{old_password:oldPw,new_password:newPw},true);
 await db.auth.signOut();$('firstPasswordForm').reset();$('password').value='';resetLogin();
 showNotice('新密码设置成功，请使用 Cashier 新密码重新登录');
 }).catch(()=>{});}

function buildNav(){const nav=$('nav');const tabs=[['create','+ 开单'],...(isCashier()?[['pending','待接受订单']]:[]),['orders','现场订单'],['history','结账记录'],['benefits','订单权益 QR'],['redeem','奖励核销'],...(isOwner()?[['admin','Owner 设置']]:[])];
 nav.replaceChildren();for(const [key,label] of tabs){const b=document.createElement('button');b.type='button';b.dataset.tab=key;b.textContent=label;b.onclick=()=>showTab(key);nav.append(b);}}
function showTab(tab){if(tab==='pending'&&!isCashier()||tab==='admin'&&!isOwner())return;state.currentTab=tab;
 for(const s of ['create','pending','orders','history','benefits','redeem','admin'])$('tab-'+s).classList.toggle('hidden',s!==tab);
 for(const b of $('nav').querySelectorAll('button'))b.classList.toggle('active',b.dataset.tab===tab);
 if(tab==='admin')loadAdmin().catch(e=>showNotice(errorText(e),true));
  if(tab==='benefits')loadBenefits().catch(e=>showNotice(errorText(e),true));
 if(tab==='pending'||tab==='orders'||tab==='history')refreshOrders(false).catch(e=>showNotice(errorText(e),true));}
async function loadCatalog(){const [products,series]=await Promise.all([db.rpc('yt_pos_catalog'),db.rpc('yt_pos_series_catalog')]);state.catalog=unpack(products)||[];state.series=unpack(series)||[];
 const category=$('categoryProduct');const chosen=category.value;category.replaceChildren(new Option('全部类别',''));
 const cats=[...new Set(state.catalog.filter(x=>x.active).map(x=>x.category))].sort();for(const c of cats)category.add(new Option(c,c));category.value=cats.includes(chosen)?chosen:'';
  const sel=$('productSeries');const value=sel.value;sel.replaceChildren(new Option('未配置系列（不发权益）',''));for(const row of state.series)sel.add(new Option(row.name+' · '+row.benefit_mode,row.id));sel.value=state.series.some(x=>x.id===value)?value:'';
  renderCatalog();renderCart();if(isOwner()){renderProductAdmin();renderSeriesAdmin();}}
function renderCatalog(){const root=$('catalog'),search=$('searchProduct').value.trim().toLowerCase(),category=$('categoryProduct').value;
 const list=state.catalog.filter(p=>p.active&&(!category||p.category===category)&&(!search||(`${p.name} ${p.category}`).toLowerCase().includes(search)));
 root.innerHTML=list.length?list.map(p=>`<button class="product" data-add="${esc(p.id)}" type="button"><strong>${esc(p.name)}</strong><small>${esc(p.category)}</small><b>${money(p.price_rm)}</b><em>+ 加入</em></button>`).join(''):'<div class="empty">没有符合条件的产品。Owner 可以先到「Owner 设置」创建菜单。</div>';}
function renderCart(){const root=$('cartRows');let count=0,total=0;
 const list=[];for(const [id,qty] of state.cart){const product=state.catalog.find(x=>x.id===id&&x.active);if(!product){state.cart.delete(id);continue;}count+=qty;total+=qty*Number(product.price_rm);
 list.push(`<div class="cart-row"><div><strong>${esc(product.name)}</strong><small>${money(product.price_rm)} × ${qty} = ${money(qty*Number(product.price_rm))}</small></div><div class="cart-tools"><button type="button" data-dec="${esc(id)}" aria-label="减少">−</button><b>${qty}</b><button type="button" data-inc="${esc(id)}" aria-label="增加">+</button></div></div>`);}
 root.innerHTML=list.length?list.join(''):'<div class="empty">请先选择产品。</div>';
 $('cartCount').textContent=count+' 件';$('cartTotal').textContent=money(total);$('createOrderBtn').disabled=count===0;}
function adjustCart(id,delta){const p=state.catalog.find(x=>x.id===id&&x.active);if(!p)return;const before=state.cart.get(id)||0,next=Math.max(0,Math.min(20,before+delta));if(next===0)state.cart.delete(id);else state.cart.set(id,next);renderCart();}
async function createOrder(){const btn=$('createOrderBtn');await busy(btn,async()=>{
 if(!state.cart.size)throw Error('请先选择产品');const rows=[...state.cart].map(([id,qty])=>({product_id:id,quantity:qty}));
 const cashier=isCashier()&&$('cashierDirect').checked;const channel=cashier?'cashier':'staff';
 const request=state.currentRequestId||crypto.randomUUID();state.currentRequestId=request;
 const data=unpack(await db.rpc('yt_pos_create_order',{
  p_request:request,p_table:$('tableInput').value.trim()||null,p_note:$('orderNote').value.trim()||null,
  p_items:rows,p_channel:channel
 }));
 state.currentRequestId=null;state.cart.clear();$('orderNote').value='';renderCart();
 showNotice(`${data.order_no} 创建成功 · ${cashier?'Cashier 已自动接受':'等待 Cashier 接受'}`);
 await refreshOrders(false);showTab('orders');
 }).catch(()=>{});}
function statusLabel(row){return row.payment_status==='paid'?'已付款':({pending:'等待 Cashier 接受',confirmed:'已接受 · 待出品',fulfilled:'已出品 · 待结账',cancelled:'已拒绝／取消'}[row.status]||row.status);}
function escapeAttr(s){return esc(s)}
function renderOrder(row,scope){const pay=row.payment_status==='paid',cancelled=row.status==='cancelled';
 const items=(row.items||[]).map(i=>`<div class="order-line"><span>${esc(i.quantity)} × ${esc(i.name)}</span><b>${money(Number(i.quantity)*Number(i.price_rm))}</b></div>`).join('');
 let controls='';
 if(scope==='pending'&&isCashier()&&row.status==='pending')controls=`<div class="action-row"><button type="button" class="primary" data-action="accept" data-order="${escapeAttr(row.id)}">接受订单 →</button><button type="button" class="danger" data-action="reject" data-order="${escapeAttr(row.id)}">拒绝</button></div>`;
 if(scope==='active'){
  if(row.status==='pending'&&isCashier())controls=`<div class="action-row"><button type="button" class="primary" data-action="accept" data-order="${escapeAttr(row.id)}">接受订单</button><button type="button" class="danger" data-action="reject" data-order="${escapeAttr(row.id)}">拒绝</button></div>`;
  if(row.status==='confirmed')controls=`<div class="action-row"><button type="button" class="primary" data-action="fulfilled" data-order="${escapeAttr(row.id)}">确认已完成出品</button>${isCashier()?`<button type="button" data-action="cancel" data-order="${escapeAttr(row.id)}">取消</button>`:''}</div>`;
  if(row.status==='fulfilled'&&isCashier())controls=`<div class="action-row"><select data-payment="${escapeAttr(row.id)}" aria-label="收款方式"><option value="foodcourt" selected>Foodcourt 食阁</option><option value="cash">Cash 现金</option><option value="duitnow">DuitNow QR</option><option value="card">Card 刷卡</option><option value="bank_transfer">Bank Transfer</option><option value="other">Other</option></select><button type="button" class="primary" data-action="paid" data-order="${escapeAttr(row.id)}">确认已收款</button></div>`;
 }
 return `<article class="order"><div class="order-head"><div><h3>#<span>${esc(row.order_no||'—')}</span> · ${esc(row.table_label||'Walk-in')}</h3><small>${esc(row.created_by_name||'Staff')} · ${stamp(row.created_at)}<br>消费先开单，收款最后确认</small><span class="order-status ${pay?'paid':cancelled?'cancelled':row.status==='pending'?'pending':''}">${statusLabel(row)}</span></div><div class="order-price">${money(row.amount_rm)}</div></div><div class="order-lines">${items}</div>${row.notes?`<small>备注：${esc(row.notes)}</small>`:''}${row.has_chit?'<small>▣ 已生成 Order Chit（待出品）</small>':''}${pay?`<small>✓ ${stamp(row.paid_at)} · ${esc(row.payment_method||'')}</small>`:''}${controls}<div class="receipt-actions"><button type="button" data-receipt="${escapeAttr(row.id)}">${pay?'查看 Receipt / PDF':'查看未付款账单'}</button>${!pay&&!cancelled&&['pending','confirmed'].includes(row.status)&&state.identity?.can_edit_orders?`<button type="button" data-edit="${escapeAttr(row.id)}">改单 · Audit</button>`:''}${pay?`<button type="button" data-benefits="${escapeAttr(row.id)}">为这单分配权益 ↗</button>`:''}</div></article>`;
}
function renderOrders(){const active=$('activeList'),pending=$('pendingList'),paid=$('paidList');
 active.innerHTML=state.active.length?state.active.map(row=>renderOrder(row,'active')).join(''):'<div class="empty">暂无需要处理的现场订单。</div>';
 paid.innerHTML=state.paid.length?state.paid.map(row=>renderOrder(row,'paid')).join(''):'<div class="empty">还没有已结账订单。</div>';
 pending.innerHTML=state.pending.length?state.pending.map(row=>renderOrder(row,'pending')).join(''):'<div class="empty">所有订单已接受，没有待处理的新单。</div>';
 $('pendingCount').textContent=String(state.pending.length);
 const n=state.pending.length;const banner=$('pendingBanner');banner.classList.toggle('hidden',!isCashier()||n===0);
 $('pendingBannerTitle').textContent=n>0?`${n} 笔订单等待 Cashier 接受`:'没有待审核订单';
 $('pendingBannerText').textContent=n?`新订单必须先审核，才能安排出品。`:'已处理完成';
}
function notifyPending(){if(!isCashier())return;const ids=new Set(state.pending.map(x=>x.id));
 if(state.seenInitialized){const newOrders=state.pending.filter(o=>!state.seenPending.has(o.id));if(newOrders.length){const o=newOrders[0];showNotice(`🔔 Cashier 收到 ${newOrders.length} 笔新单 · ${o.order_no}，请接受订单`,false,true);ping();}}
 state.seenPending=ids;state.seenInitialized=true;
}
function ping(){try{const C=window.AudioContext||window.webkitAudioContext;if(!C)return;const ctx=new C();const osc=ctx.createOscillator(),gain=ctx.createGain();osc.frequency.value=880;gain.gain.value=.04;osc.connect(gain);gain.connect(ctx.destination);osc.start();setTimeout(()=>{osc.stop();ctx.close();},130);}catch{}}
async function refreshOrders(silent=true){if(!state.identity||state.refreshing)return;state.refreshing=true;
 try{const calls=[db.rpc('yt_pos_orders',{p_scope:'active',p_limit:80}),db.rpc('yt_pos_orders',{p_scope:'paid',p_limit:50})];if(isCashier())calls.push(db.rpc('yt_pos_orders',{p_scope:'pending',p_limit:80}));const rows=await Promise.all(calls.map(unpackPromise));
 state.active=rows[0]||[];state.paid=rows[1]||[];state.pending=isCashier()?(rows[2]||[]):[];notifyPending();renderOrders();}
 catch(e){if(!silent)showNotice(errorText(e),true);}finally{state.refreshing=false;}}
const unpackPromise=async p=>unpack(await p);
async function orderAction(orderId,action,container){const btn=container;await busy(btn,async()=>{
 let reason=null,method=null;
 if(action==='reject'||action==='cancel'){reason=window.prompt('请填写拒绝／取消原因（必填）','客人取消');if(reason===null)return;if(reason.trim().length<2)throw Error('reason_required');}
 if(action==='paid'){const card=btn.closest('.order');method=card.querySelector('[data-payment]')?.value||'cash';if(!window.confirm('确认已经收到整张订单的款项？此动作只登记人工收款，不会实际扣款。'))return;}
 if(action==='fulfilled'&&!window.confirm('确认这些产品都已完成出品？'))return;
 const result=unpack(await db.rpc('yt_pos_action',{p_order:orderId,p_action:action,p_reason:reason,p_method:method}));
 showNotice(({accept:'已接受，订单进入制作队列',reject:'订单已拒绝',fulfilled:'已完成出品，等待结账',paid:'已经记录收款',cancel:'订单已取消'})[action]||'状态已更新');
 await refreshOrders(false);
 }).catch(()=>{});}
async function loadAdmin(){if(!isOwner())return;await Promise.all([loadCatalog(),loadRights()]);}
function renderProductAdmin(){if(!isOwner())return;const root=$('productAdminList');root.innerHTML=state.catalog.length?state.catalog.map(p=>`<div class="admin-entry"><div><strong>${esc(p.name)}</strong><small>${esc(p.category)} · ${money(p.price_rm)} · ${p.active?'可点单':'已停用'} · ${esc(p.series_name||'没有系列权益')}</small></div><button data-product="${esc(p.id)}" type="button">编辑</button></div>`).join(''):'<div class="empty">当前没有产品。请先新增菜单。</div>';}
async function saveProduct(e){e.preventDefault();await busy($('productForm').querySelector('[type=submit]'),async()=>{
 const id=$('productId').value||null;const price=Number($('productPrice').value);if(!Number.isFinite(price)||price<0||price>5000)throw Error('请输入正确产品价格');
 unpack(await db.rpc('yt_pos_owner_product_v2',{p_id:id,p_name:$('productName').value.trim(),p_category:$('productCategory').value.trim(),p_price:price,p_active:$('productActive').checked,p_sort:Number($('productSort').value),p_series:$('productSeries').value||null}));
 clearProduct();await loadCatalog();showNotice(id?'产品已更新':'产品已加入菜单');
 }).catch(()=>{});}
function editProduct(id){const p=state.catalog.find(x=>x.id===id);if(!p)return;showTab('admin');$('productId').value=p.id;$('productName').value=p.name;$('productCategory').value=p.category;$('productPrice').value=p.price_rm;$('productActive').checked=p.active;$('productSort').value=p.sort_order||100;$('productSeries').value=p.series_id||'';window.scrollTo({top:0,behavior:'smooth'});}
function clearProduct(){$('productForm').reset();$('productId').value='';$('productActive').checked=true;$('productSort').value=100;$('productSeries').value='';}
async function loadRights(){if(!isOwner())return;const staff=unpack(await db.rpc('yt_pos_staff_list'))||[];
 $('staffRights').innerHTML=staff.length?staff.map(x=>`<div class="admin-entry"><div><strong>${esc(x.username)}</strong><small>${x.active?'Active':'Disabled'} · ${x.role==='cashier'?'Cashier 独立账号':'Staff'}</small></div>${x.role==='cashier'?'<span>独立 Cashier 账号</span>':`<label class="checkline"><input type="checkbox" data-cashier="${esc(x.id)}" ${x.can_cashier?'checked':''} ${!x.active?'disabled':''}><span>收银权限</span></label><label class="checkline"><input type="checkbox" data-edit-staff="${esc(x.id)}" ${x.can_edit_orders?'checked':''} ${!x.active?'disabled':''}><span>改单权限</span></label>`}</div>`).join(''):'<div class="empty">还没有 Staff 账户。</div>';}
async function changeRight(id,allowed,input){await busy(input,async()=>{if(!window.confirm(`确认${allowed?'授予':'撤销'}这个员工的 Cashier 权限？`)){input.checked=!allowed;return;}unpack(await db.rpc('yt_pos_owner_cashier_access',{p_staff:id,p_allowed:allowed}));showNotice('员工权限已经更新');await loadRights();}).catch(()=>{input.checked=!allowed;});}
// POS V2 — server-enforced order revisions, per-unit QR benefits, receipts and redemption.
const friendlyDate=d=>d?stamp(d):'—';
const portalClientUrl=()=>new URL('../',import.meta.url);
function receiptHtml(r){
 const paid=r.payment_status==='paid';
 const items=(r.items||[]).map(i=>`<tr><td>${esc(i.item_name||'Drink')}<small>${Number(i.quantity)} × ${money(i.unit_price_rm)}</small></td><td>${money(i.line_total_rm)}</td></tr>`).join('');
 return `<!doctype html><html lang="zh-Hans"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(r.order_no)} ${paid?'Receipt':'Bill'}</title>
<style>@page{size:80mm auto;margin:5mm}html,body{font-family:Arial,'Noto Sans CJK SC',sans-serif;margin:0;background:#fff;color:#141414;font-size:11px}
.paper{max-width:80mm;padding:12px;margin:auto}h1{font-size:21px;margin:4px 0;text-align:center;letter-spacing:3px}
.kicker{text-align:center;letter-spacing:1.3px;font-size:10px}p{margin:4px 0}.meta{margin-top:12px;border-top:1px dashed #aaa;padding-top:8px}
table{border-collapse:collapse;width:100%;margin-top:12px}td{padding:7px 0;vertical-align:top;border-bottom:1px dashed #ddd}td:last-child{text-align:right;white-space:nowrap}td small{display:block;color:#777;margin-top:4px}
.total{font-size:16px;font-weight:700;text-align:right;border-top:1px solid #333;margin-top:12px;padding-top:8px}
.foot{text-align:center;font-size:9px;color:#777;line-height:1.5;margin-top:16px}.stamp{font-size:11px;font-weight:700;text-align:center;border:1px dashed #888;padding:8px;margin:12px 0}
.noprint{margin:10px auto;text-align:center}button{padding:10px 15px;background:#101010;color:white;border:none;border-radius:5px;cursor:pointer}
@media print{.noprint{display:none}.paper{padding:0}}@media screen{body{background:#e7e7e7}.paper{background:white;min-height:300px}}</style></head><body>
<div class="noprint"><button onclick="window.print()">打印 / 保存为 PDF</button></div><main class="paper"><h1>YE·TIPSY</h1><div class="kicker">KLUANG · ORDER DOCUMENT</div>
<div class="stamp">${paid?'PAYMENT RECEIPT · 已收款':'UNPAID BILL · 未付款（非收据）'}</div>
<div class="meta"><p><strong>#${esc(r.order_no||'—')}</strong></p><p>Table: ${esc(r.table_label||'Walk-in')}</p>
<p>Created: ${esc(friendlyDate(r.created_at))}</p><p>Cashier / Staff: ${esc(r.created_by||'—')}</p>
${paid?`<p>Paid: ${esc(friendlyDate(r.paid_at))}</p><p>Payment: ${esc((r.payment_method||'foodcourt').toUpperCase())}</p>`:''}
${r.notes?`<p>Notes: ${esc(r.notes)}</p>`:''}</div>
<table><thead><tr><td>ITEM</td><td>AMOUNT</td></tr></thead><tbody>${items}</tbody></table>
<div class="total">TOTAL ${money(r.amount_rm)}</div>
<div class="foot">Yetipsy internal order record · Foodcourt payment may be collected by venue cashier.\n<br>This is not a tax invoice unless separately issued by the merchant.\n<br>Thank you for visiting!</div></main></body></html>`;
}
async function viewReceipt(orderId){
 const win=window.open('about:blank','_blank');
 if(!win)throw Error('浏览器挡住了新窗口。请允许弹出窗口以查看或另存为 PDF');
 win.document.write('<p style="font-family:sans-serif">正在准备 Receipt / Bill…</p>');
 try{
  const data=unpack(await db.rpc('yt_pos_receipt',{p_order:orderId}));
  win.document.open();win.document.write(receiptHtml(data));win.document.close();
  win.focus();showNotice('已打开订单单据，可选择浏览器「打印」→「保存为 PDF」');
 }catch(e){win.close();throw e;}
}
async function changeEditRight(id,allowed,input){await busy(input,async()=>{
 if(!window.confirm(`确认${allowed?'开放':'关闭'}这位 Staff 的改单权限？所有修改会保留 Audit 记录。`)){input.checked=!allowed;return;}
 unpack(await db.rpc('yt_pos_owner_edit_access',{p_staff:id,p_allowed:allowed}));
 showNotice('改单权限更新成功');await loadRights();
}).catch(()=>{input.checked=!allowed});}
function renderSeriesAdmin(){if(!isOwner())return;
 const root=$('seriesList');root.innerHTML=state.series.length?state.series.map(s=>`<div class="admin-entry"><div><strong>${esc(s.name)}</strong>
 <small>${esc(s.benefit_mode)} · ${Number(s.game_plays||0)} 次 · ${s.active?'已开放':'关闭'}${s.game_plays>1?' · 多次权益待开发':''}</small></div>
 <button type="button" data-series="${esc(s.id)}">编辑</button></div>`).join(''):'<div class="empty">还没有系列。先建立 CLASSIC / TOWER 等分类并设置权益。</div>';
}
function editSeries(id){const s=state.series.find(x=>x.id===id);if(!s)return;
 showTab('admin');$('seriesId').value=s.id;$('seriesName').value=s.name;$('seriesMode').value=s.benefit_mode;
 $('seriesPlays').value=s.game_plays??0;$('seriesPointPercent').value=s.point_percent??'';
 $('seriesSplit').checked=!!s.can_split;$('seriesActive').checked=!!s.active;
 $('seriesName').scrollIntoView({block:'center',behavior:'smooth'});
}
async function saveSeries(event){event.preventDefault();const btn=$('seriesForm').querySelector('[type=submit]');await busy(btn,async()=>{
 const mode=$('seriesMode').value,plays=Number($('seriesPlays').value);
 if(mode!=='pending'&&mode!=='none'&&plays>1 && !window.confirm('目前顾客每张 QR 只提供 1 次游戏。你可以保存多次规则，但发码前还需要升级。继续保存？'))return;
 unpack(await db.rpc('yt_pos_owner_series',{
  p_id:$('seriesId').value||null,p_name:$('seriesName').value.trim(),p_mode:mode,p_plays:plays,
  p_point_percent:$('seriesPointPercent').value===''?null:Number($('seriesPointPercent').value),
  p_split:$('seriesSplit').checked,p_active:$('seriesActive').checked
 }));$('seriesForm').reset();$('seriesId').value='';await loadCatalog();showNotice('系列规则已保存');
}).catch(()=>{});}

async function loadBenefits(){
 if(!state.identity)return;
 const existing=$('benefitOrderSelect').value;
 const list=unpack(await db.rpc('yt_pos_orders',{p_scope:'paid',p_limit:120}))||[];
 state.paid=list;
 const select=$('benefitOrderSelect');select.replaceChildren(new Option('请选择已付款订单',''));
 for(const r of list)select.add(new Option(`#${r.order_no} · ${r.table_label||'Walk-in'} · ${money(r.amount_rm)}`,r.id));
 if(list.some(x=>x.id===existing))select.value=existing;
 await loadBenefitCampaigns();
 if(select.value)await loadSelectedPaidUnits();else $('benefitUnits').innerHTML='<div class="empty">没有已付款订单可分配。</div>';
}
async function loadBenefitCampaigns(){
 const selected=$('benefitCampaign').value;
 const r=unpack(await db.from('campaigns').select('id,name,active').eq('active',true).order('created_at',{ascending:false}))||[];
 const sel=$('benefitCampaign');sel.replaceChildren(new Option('请选择活动',''));
 for(const c of r)sel.add(new Option(c.name,c.id));
 if(r.some(x=>x.id===selected))sel.value=selected;
}
async function loadSelectedPaidUnits(){
 const id=$('benefitOrderSelect').value,root=$('benefitUnits');root.replaceChildren();
 if(!id){root.innerHTML='<div class="empty">请选择已付款订单。</div>';return;}
 const result=unpack(await db.rpc('yt_pos_paid_units',{p_order:id}));
 state.benefitOrder=result;
 if(!result.units?.length){root.innerHTML='<div class="empty">这个订单没有可以处理的单杯权益。</div>';return;}
 for(const unit of result.units){
  const ready=unit.series_active&&['games','choose'].includes(unit.benefit_mode)&&Number(unit.game_plays)===1;
  const issued=!!unit.game_pass_id;
  const expired=issued&&unit.pass_status==='issued'&&!!unit.pass_expires_at&&Date.parse(unit.pass_expires_at)<=Date.now();
  const claimed=issued&&(unit.pass_status==='claimed'||unit.pass_status==='used'||unit.assigned);
  const key='yt-pos-v2-unit:'+unit.order_item_id+':'+unit.unit_number;
  let original=null;try{original=JSON.parse(sessionStorage.getItem(key)||'null')}catch{}
  const recover=issued&&!expired&&!claimed&&original;
  const card=document.createElement('div');card.className='order-note';
  const summary=document.createElement('div');summary.innerHTML=`<strong>${esc(unit.product_name)} · 第 ${unit.unit_number} 份</strong><small>单杯 ${money(unit.unit_price_rm)} · ${esc(unit.series_name||'未分配系列')}</small><small>${issued?'✓ 已生成 QR':ready?'可生成':'Owner 尚未配置可用权益规则'}</small>`;
  const btn=document.createElement('button');btn.type='button';btn.className='primary';
  btn.dataset.issueUnit='1';btn.dataset.item=unit.order_item_id;btn.dataset.unit=String(unit.unit_number);
  btn.textContent=claimed?'已领取':recover?'重新显示 QR':expired?'过期重发 QR':issued?'已发出':ready?'生成专属 QR':'不可发';
  btn.disabled=claimed||(issued&&!recover&&!expired)||(!issued&&!ready);
  card.append(summary,btn);root.append(card);
 }
}
let qrLibraryWait=null;
async function qrLibrary(){
 if(window.QRCode?.CorrectLevel)return true;
 if(!qrLibraryWait)qrLibraryWait=(async()=>{
  for(const src of ['https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js',
    'https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js']){
   try{await new Promise((resolve,reject)=>{const t=document.createElement('script');t.src=src;t.onload=resolve;t.onerror=reject;document.head.append(t)});
    if(window.QRCode?.CorrectLevel)return true;}catch(e){console.warn('QR asset unavailable',src);}
  }return false;
 })();return qrLibraryWait;
}
async function showUnitQR(token,pass,unit){
 const root=$('benefitQR');root.classList.remove('hidden');root.replaceChildren();
 const url=portalClientUrl();url.searchParams.set('claim',token);
 const title=document.createElement('h3');title.textContent=`${unit.product_name} · 第 ${unit.unit_number} 份 QR`;
 const text=document.createElement('p');text.className='muted';text.textContent=`${money(unit.unit_price_rm)} · 每份独立领取，扫码后进入 Yetipsy Play。`;
 const square=document.createElement('div');square.className='qr-screen';
 const link=document.createElement('a');link.href=url.href;link.className='qr-link';link.textContent=url.href;link.target='_blank';link.rel='noreferrer';
 const copyBtn=document.createElement('button');copyBtn.type='button';copyBtn.className='quiet';copyBtn.textContent='复制领取链接';copyBtn.onclick=()=>navigator.clipboard?.writeText(url.href).then(()=>showNotice('已复制'));
 const badge=document.createElement('p');badge.className='help';badge.textContent='正在与服务器验证 QR…';
 root.append(title,text,square,link,copyBtn,badge);
 let shown=false;if(await qrLibrary()){new window.QRCode(square,{text:url.href,width:206,height:206,colorDark:'#1d251f',colorLight:'#ffffff',correctLevel:window.QRCode.CorrectLevel.M});shown=true;}
 if(!shown)square.textContent='QR 图片暂不可用，可以复制上面的顾客领取链接。';
 try{const response=await fetch(conf.url+'/functions/v1/yt-pin-auth',{
   method:'POST',headers:{'Content-Type':'application/json','apikey':conf.publishableKey},
   body:JSON.stringify({action:'preview',kind:'claim',token}),cache:'no-store'
  });const data=await response.json();
  badge.textContent=data.ok&&data.preview?.valid?'✓ 服务器已确认二维码当前可以领取':
   '⚠ 服务器暂未确认此码可领取。请勿发给顾客，可能已领取或失效。';
 }catch{badge.textContent='⚠ 领取码尚未通过实时网络核验，请先检查网络连接。';}
 root.scrollIntoView({behavior:'smooth',block:'center'});
}
async function issuePaidUnit(itemId,unitNumber,button){const orderId=$('benefitOrderSelect').value;
 if(!orderId)throw Error('请先选择已付款订单');
 const unit=state.benefitOrder?.units?.find(x=>x.order_item_id===itemId&&x.unit_number===unitNumber);
 if(!unit)throw Error('商品已更新，请刷新');
 const key='yt-pos-v2-unit:'+itemId+':'+unitNumber;
 let pair=null;try{pair=JSON.parse(sessionStorage.getItem(key)||'null')}catch{}
 if(unit.game_pass_id&&pair?.raw&&unit.pass_status==='issued'&&unit.pass_expires_at&&Date.parse(unit.pass_expires_at)>Date.now()){await showUnitQR(pair.raw,null,unit);return;}
 if(unit.game_pass_id&&unit.pass_status==='issued'&&unit.pass_expires_at&&Date.parse(unit.pass_expires_at)<=Date.now()){pair=null;try{sessionStorage.removeItem(key)}catch{}}
 await busy(button,async()=>{
  const campaign=$('benefitCampaign').value;
  const mins=Number($('benefitExpiry').value);
  if(!campaign)throw Error('请先选择活动');
  if(!Number.isInteger(mins)||mins<1||mins>60)throw Error('QR 有效分钟为 1–60');
  if(!pair){pair={raw:crypto.randomUUID(),request:crypto.randomUUID()};sessionStorage.setItem(key,JSON.stringify(pair));}
  const rows=unpack(await db.rpc('yt_pos_issue_unit_pass',{
   p_order:orderId,p_item:itemId,p_unit:unitNumber,p_campaign:campaign,
   p_token:pair.raw,p_request:pair.request,p_minutes:mins
  }));
  if(!rows?.length)throw Error('服务器未发出领取码');
  await showUnitQR(pair.raw,rows[0],unit);
  await loadSelectedPaidUnits();
  showNotice(`已按订单产品生成 Game Pass · ${unit.product_name}`);
 }).catch(()=>{});
}
function parseRedeemToken(raw){const text=String(raw||'').trim();let token=text;
 const match=text.match(/^redeem:([0-9a-f-]{36})$/i);if(match)token=match[1];
 else {try{const u=new URL(text);if(u.searchParams.has('redeem'))token=u.searchParams.get('redeem');else if(u.searchParams.has('claim')||u.searchParams.has('gift'))throw Error('请扫描钱包「兑奖 QR」，不是领取码');}catch(e){if(e.message?.includes('请扫描'))throw e;}}
 if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(token))throw Error('凭证格式不正确');
 return token.toLowerCase();
}
async function lookupPOSRedeem(){
 const token=parseRedeemToken($('redeemToken').value);state.redeemPending=null;
 const rows=unpack(await db.rpc('yt_lookup_redeem',{p_token:token}))||[];
 const root=$('redeemCheck');root.replaceChildren();
 if(!rows.length){root.innerHTML='<div class="empty">找不到这个兑奖码。</div>';return;}
 const row=rows[0];const info=document.createElement('p');
 info.textContent=`${row.reward_name} · ${row.valid?'✓ 可兑换':'× 无效、未到可兑时间或已核销'} · 有效至 ${friendlyDate(row.expires_at)}`;
 root.append(info);if(row.valid){state.redeemPending=token;
 const btn=document.createElement('button');btn.dataset.confirmRedeem='1';btn.className='primary';btn.type='button';btn.textContent='确认顾客已兑换这份奖励';root.append(btn);}
}
async function confirmPOSRedeem(btn){await busy(btn,async()=>{
 const token=state.redeemPending;if(!token)throw Error('请先检查兑奖 QR');
 if(!window.confirm('确认交付这份奖励并核销？每张奖券只能使用一次。'))return;
 const key='yt-pos-redeem:'+token;
 let request=sessionStorage.getItem(key);if(!request){request=crypto.randomUUID();sessionStorage.setItem(key,request);}
 const rows=unpack(await db.rpc('yt_redeem',{p_token:token,p_request:request}));
 if(!rows?.length)throw Error('核销未完成，请重试');sessionStorage.removeItem(key);
 state.redeemPending=null;$('redeemToken').value='';
 $('redeemCheck').innerHTML=`<div class="order-note"><div><strong>✓ 核销完成</strong><small>${esc(rows[0].reward_name)} · ${friendlyDate(rows[0].redeemed_at)}</small></div></div>`;
 showNotice('奖品已核销，并记录到 Supabase');
}).catch(()=>{});}
function stopRedeemCamera(){
 if(state.scanTimer){clearInterval(state.scanTimer);state.scanTimer=null;}
 if(state.scanStream){for(const track of state.scanStream.getTracks())track.stop();state.scanStream=null;}
 $('redeemVideo').classList.add('hidden');
}
async function startRedeemCamera(){
 if(state.scanStream){stopRedeemCamera();return;}
 if(!navigator.mediaDevices?.getUserMedia||typeof BarcodeDetector==='undefined')throw Error('当前浏览器不支持相机扫码，请粘贴兑奖二维码内容');
 const stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:'environment'}});
 state.scanStream=stream;const video=$('redeemVideo');video.srcObject=stream;video.classList.remove('hidden');await video.play();
 const detector=new BarcodeDetector({formats:['qr_code']});
 state.scanTimer=setInterval(async()=>{
  if(!state.scanStream)return;
  try{const codes=await detector.detect(video);if(codes.length){$('redeemToken').value=codes[0].rawValue;stopRedeemCamera();await lookupPOSRedeem();}}catch(e){console.warn('Barcode scan:',e)}
 },700);
}
function closeEditDialog(){state.editOrder=null;$('editOverlay').classList.add('hidden');}
function renderEditRows(){const root=$('editLineList');root.replaceChildren();let total=0;
 for(const [key,line] of state.editCart){const p=state.catalog.find(x=>x.id===line.product_id&&x.active);if(!p)continue;total+=Number(p.price_rm)*line.quantity;
  const row=document.createElement('div');row.className='order-note';
  const select=document.createElement('select');select.dataset.editProduct=key;
  for(const prod of state.catalog.filter(x=>x.active))select.add(new Option(prod.name+' · '+money(prod.price_rm),prod.id));select.value=line.product_id;
  const qty=document.createElement('input');qty.type='number';qty.min=0;qty.max=20;qty.value=line.quantity;qty.dataset.editQty=key;qty.style.maxWidth='65px';
  row.append(select,qty);root.append(row);
 }$('editSum').textContent=money(total);
}
function editDialogChange(input){const key=input.dataset.editQty||input.dataset.editProduct;const line=state.editCart.get(key);if(!line)return;
 if(input.dataset.editQty){const v=Number(input.value);if(!Number.isInteger(v)||v<0||v>20)throw Error('数量应为 0–20');if(v===0)state.editCart.delete(key);else line.quantity=v;}
 else line.product_id=input.value;
 renderEditRows();
}
async function openEditDialog(id){const row=state.active.find(x=>x.id===id);if(!row)throw Error('请先刷新现场订单');
 if(!state.identity.can_edit_orders)throw Error('order_edit_permission_required');
 state.editOrder=row;state.editCart=new Map((row.items||[]).map((i,n)=>['line-'+n,{product_id:i.product_id,quantity:i.quantity}]));
 $('editTable').value=row.table_label||'';$('editNote').value=row.notes||'';$('editReason').value='';
 $('editTitle').textContent=`改单 · ${row.order_no}`;renderEditRows();$('editOverlay').classList.remove('hidden');
}
async function submitEditOrder(e){e.preventDefault();const btn=$('editForm').querySelector('[type=submit]');await busy(btn,async()=>{
 if(!state.editOrder)throw Error('请先选择订单');
 const counts=new Map();for(const v of state.editCart.values()){if(!v.quantity)continue;counts.set(v.product_id,(counts.get(v.product_id)||0)+v.quantity);}
 const items=[...counts].map(([product_id,quantity])=>({product_id,quantity}));
 if(items.length===0)throw Error('请保留至少一个商品');
 if(!window.confirm('确认更改这张未付款订单？系统会记录改单原因、前后金额与操作人。'))return;
 const result=unpack(await db.rpc('yt_pos_edit_order',{
  p_order:state.editOrder.id,p_items:items,p_reason:$('editReason').value.trim(),
  p_table:$('editTable').value.trim()||null,p_note:$('editNote').value.trim()||null,
  p_expected_updated:state.editOrder.updated_at
 }));
 closeEditDialog();await refreshOrders(false);
 showNotice(result.must_be_reaccepted?'改单成功，订单已回到 Cashier 待审核队列':'改单成功，Audit 已记录');
}).catch(()=>{});}

function startPolling(){stopPolling();state.interval=setInterval(()=>{if(state.activeView==='dashboard')refreshOrders(true)},6500);}
function stopPolling(){if(state.interval){clearInterval(state.interval);state.interval=null;}}
function bind(){
 $('signinForm').addEventListener('submit',e=>login(e).catch(()=>{}));
  $('firstPasswordForm').onsubmit=changeCashierFirstPassword;$('firstPasswordBack').onclick=()=>{db.auth.signOut().finally(resetLogin);};
 $('logout').onclick=async()=>{stopPolling();if(db)await db.auth.signOut();resetLogin();};
 $('searchProduct').oninput=renderCatalog;$('categoryProduct').onchange=renderCatalog;
 $('catalog').onclick=e=>{const btn=e.target.closest('[data-add]');if(btn)adjustCart(btn.dataset.add,1);};
 $('cartRows').onclick=e=>{const btn=e.target.closest('[data-dec],[data-inc]');if(btn)adjustCart(btn.dataset.dec||btn.dataset.inc,btn.dataset.inc?1:-1);};
 $('createOrderBtn').onclick=()=>createOrder();
 $('cashierDirect').onchange=()=>{$('createHint').textContent=$('cashierDirect').checked?'Cashier 自己开单自动接受、不生成额外 Order Chit。':'按 Staff 下单：必须等待 Cashier 接受后才能出品。';};
 $('refreshPending').onclick=()=>refreshOrders(false);$('refreshOrders').onclick=()=>refreshOrders(false);$('refreshHistory').onclick=()=>refreshOrders(false);
 $('jumpPending').onclick=()=>showTab('pending');
 document.body.addEventListener('click',e=>{const b=e.target.closest('button[data-action][data-order]');if(b)orderAction(b.dataset.order,b.dataset.action,b);});
 $('productForm').onsubmit=saveProduct;$('clearProduct').onclick=clearProduct;
 $('productAdminList').onclick=e=>{const b=e.target.closest('[data-product]');if(b)editProduct(b.dataset.product);};
 $('staffRights').onchange=e=>{const cashier=e.target.closest('input[data-cashier]');if(cashier)changeRight(cashier.dataset.cashier,cashier.checked,cashier);const edit=e.target.closest('input[data-edit-staff]');if(edit)changeEditRight(edit.dataset.editStaff,edit.checked,edit);};
  $('seriesForm').onsubmit=saveSeries;
  $('seriesList').onclick=e=>{const b=e.target.closest('[data-series]');if(b)editSeries(b.dataset.series);};
  $('benefitOrderSelect').onchange=()=>loadSelectedPaidUnits().catch(e=>showNotice(errorText(e),true));
  $('refreshBenefits').onclick=()=>loadBenefits().catch(e=>showNotice(errorText(e),true));
  $('benefitUnits').onclick=e=>{const b=e.target.closest('[data-issue-unit]');if(b)issuePaidUnit(b.dataset.item,Number(b.dataset.unit),b).catch(()=>{});};
  $('redeemLookup').onclick=()=>lookupPOSRedeem().catch(e=>showNotice(errorText(e),true));
  $('redeemScanCamera').onclick=()=>startRedeemCamera().catch(e=>showNotice(errorText(e),true));
  $('redeemCheck').onclick=e=>{const b=e.target.closest('[data-confirm-redeem]');if(b)confirmPOSRedeem(b).catch(()=>{});};
  document.body.addEventListener('click',e=>{const receipt=e.target.closest('[data-receipt]');if(receipt)viewReceipt(receipt.dataset.receipt).catch(e=>showNotice(errorText(e),true));
   const edit=e.target.closest('[data-edit]');if(edit)openEditDialog(edit.dataset.edit).catch(e=>showNotice(errorText(e),true));
   const benefit=e.target.closest('[data-benefits]');if(benefit){showTab('benefits');$('benefitOrderSelect').value=benefit.dataset.benefits;loadSelectedPaidUnits().catch(err=>showNotice(errorText(err),true));}});
  $('editClose').onclick=closeEditDialog;$('editForm').onsubmit=submitEditOrder;
  $('editLineList').onchange=event=>{const inp=event.target.closest('[data-edit-qty],[data-edit-product]');if(inp)editDialogChange(inp);};
  $('editAddProduct').onclick=()=>{const p=state.catalog.find(p=>p.active);if(p){state.editCart.set(crypto.randomUUID(),{product_id:p.id,quantity:1});renderEditRows();}};
 document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible'&&state.activeView==='dashboard')refreshOrders(true);});
}
async function boot(){bind();if(!usable){resetLogin();showNotice('请检查 /play/config.js，POS 尚未连上 Supabase',true,true);return;}
 const {data,error}=await db.auth.getSession();if(!error&&data?.session){try{await launch();return;}catch(e){showNotice('请重新登录工作账号：'+errorText(e),true);}}
 resetLogin();}
boot().catch(e=>{resetLogin();showNotice(errorText(e),true,true);});
