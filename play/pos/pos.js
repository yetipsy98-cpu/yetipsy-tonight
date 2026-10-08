import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';

// Yetipsy POS V1. Order creation and payment transitions always execute on Supabase.
// The browser never chooses product prices or changes a paid status directly.
const $=id=>document.getElementById(id);
const conf=window.YETIPSY_PLAY_CONFIG||{};
const usable=/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(conf.url||'')&&/^sb_publishable_/.test(conf.publishableKey||'');
const db=usable?createClient(conf.url,conf.publishableKey,{auth:{storageKey:'yt-work-session-v1',persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}}):null;
const workURL=(conf.url||'')+'/functions/v1/yt-work-auth';
const state={identity:null,catalog:[],cart:new Map(),currentTab:'create',
  active:[],paid:[],pending:[],seenPending:new Set(),seenInitialized:false,
  currentRequestId:null,refreshing:false,interval:null,noticeTimer:null,activeView:'login'};
const msgMap={staff_only:'需要有效员工账号',cashier_only:'需要 Cashier 权限',not_authenticated:'登录已过期，请重新登录',
  order_not_pending:'订单不在待接受状态',order_not_accepted:'订单必须先由 Cashier 接受',order_not_served:'请先完成出品，之后才能收款',
  product_unavailable:'这款产品已停止销售，请重新选择',order_too_large:'单笔订单金额或数量过大',
  invalid_line:'订单产品无效',invalid_order:'订单资料不正确',invalid_channel:'下单渠道无效',invalid_filter:'订单筛选条件无效',
  order_not_found:'找不到这张订单',request_conflict:'重复请求出现冲突，请重新开单',invalid_payment_method:'请选择正确的收款方式',
  order_cannot_cancel:'这张订单不能直接取消，已出品／已付款订单必须走人工处理流程',
  invalid_credentials:'账号或密码错误',owner_only:'只有 Owner 才能更改此设置',too_many_attempts:'错误尝试太多，请稍后再试',
  reason_required:'请填写至少两个字的取消／拒绝原因'};
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
async function work(action,data={}){const resp=await fetch(workURL,{method:'POST',headers:{'Content-Type':'application/json',apikey:conf.publishableKey},cache:'no-store',body:JSON.stringify({action,...data})});const res=await resp.json().catch(()=>({ok:false,error:'server_unavailable'}));if(!resp.ok||!res.ok)throw Error(res.error||'server_unavailable');return res;}
function resetLogin(){stopPolling();state.activeView='login';state.identity=null;$('signin').classList.remove('hidden');$('dashboard').classList.add('hidden');$('logout').classList.add('hidden');$('accountName').textContent='WORK ACCOUNT';}
async function login(e){e.preventDefault();await busy($('signinBtn'),async()=>{
 const username=$('username').value.trim().toLowerCase(),password=$('password').value;
 const result=await work('login',{username,password});
 if(result.must_change_password)throw Error('请先到原本的 Staff／Owner 工作台更换临时密码');
 const {error}=await db.auth.setSession({access_token:result.access_token,refresh_token:result.refresh_token});if(error)throw error;
 $('password').value='';await launch();
});}
async function launch(){if(!usable){showNotice('尚未配置 /play/config.js 的 Supabase 连接',true,true);return;}
 const identity=unpack(await db.rpc('yt_pos_identity'));if(!identity)throw Error('staff_only');
 state.identity=identity;state.activeView='dashboard';$('signin').classList.add('hidden');$('dashboard').classList.remove('hidden');$('logout').classList.remove('hidden');
 $('accountName').textContent=identity.username+' · '+(identity.can_cashier?'CASHIER':'STAFF');$('permissionPill').textContent=identity.can_owner?'OWNER + CASHIER':identity.can_cashier?'CASHIER':'STAFF';
 $('cashierCreateChoice').classList.toggle('hidden',!isCashier());$('cashierDirect').checked=isCashier();
 $('createHint').textContent=isCashier()?'选择 Cashier 自开单即可自动接受；取消勾选将作为 Staff 单提交审核。':'Staff 点单后等待 Cashier 接受，自动进入对方的待审核队列。';
 buildNav();await Promise.all([loadCatalog(),refreshOrders(false)]);showTab('create');startPolling();
}
function buildNav(){const nav=$('nav');const tabs=[['create','+ 开单'],...(isCashier()?[['pending','待接受订单']]:[]),['orders','现场订单'],['history','结账记录'],...(isOwner()?[['admin','Owner 设置']]:[])];
 nav.replaceChildren();for(const [key,label] of tabs){const b=document.createElement('button');b.type='button';b.dataset.tab=key;b.textContent=label;b.onclick=()=>showTab(key);nav.append(b);}}
function showTab(tab){if(tab==='pending'&&!isCashier()||tab==='admin'&&!isOwner())return;state.currentTab=tab;
 for(const s of ['create','pending','orders','history','admin'])$('tab-'+s).classList.toggle('hidden',s!==tab);
 for(const b of $('nav').querySelectorAll('button'))b.classList.toggle('active',b.dataset.tab===tab);
 if(tab==='admin')loadAdmin().catch(e=>showNotice(errorText(e),true));
 if(tab==='pending'||tab==='orders'||tab==='history')refreshOrders(false).catch(e=>showNotice(errorText(e),true));}
async function loadCatalog(){const products=unpack(await db.rpc('yt_pos_catalog'))||[];state.catalog=Array.isArray(products)?products:[];
 const category=$('categoryProduct');const chosen=category.value;category.replaceChildren(new Option('全部类别',''));
 const cats=[...new Set(state.catalog.filter(x=>x.active).map(x=>x.category))].sort();for(const c of cats)category.add(new Option(c,c));category.value=cats.includes(chosen)?chosen:'';
 renderCatalog();renderCart();if(isOwner())renderProductAdmin();}
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
  if(row.status==='fulfilled'&&isCashier())controls=`<div class="action-row"><select data-payment="${escapeAttr(row.id)}" aria-label="收款方式"><option value="cash">Cash 现金</option><option value="duitnow">DuitNow QR</option><option value="card">Card 刷卡</option><option value="bank_transfer">Bank Transfer</option><option value="other">Other</option></select><button type="button" class="primary" data-action="paid" data-order="${escapeAttr(row.id)}">确认已收款</button></div>`;
 }
 return `<article class="order"><div class="order-head"><div><h3>#<span>${esc(row.order_no||'—')}</span> · ${esc(row.table_label||'Walk-in')}</h3><small>${esc(row.created_by_name||'Staff')} · ${stamp(row.created_at)}<br>消费先开单，收款最后确认</small><span class="order-status ${pay?'paid':cancelled?'cancelled':row.status==='pending'?'pending':''}">${statusLabel(row)}</span></div><div class="order-price">${money(row.amount_rm)}</div></div><div class="order-lines">${items}</div>${row.notes?`<small>备注：${esc(row.notes)}</small>`:''}${row.has_chit?'<small>▣ 已生成 Order Chit（待出品）</small>':''}${pay?`<small>✓ ${stamp(row.paid_at)} · ${esc(row.payment_method||'')}</small>`:''}${controls}</article>`;
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
function renderProductAdmin(){if(!isOwner())return;const root=$('productAdminList');root.innerHTML=state.catalog.length?state.catalog.map(p=>`<div class="admin-entry"><div><strong>${esc(p.name)}</strong><small>${esc(p.category)} · ${money(p.price_rm)} · ${p.active?'可点单':'已停用'}</small></div><button data-product="${esc(p.id)}" type="button">编辑</button></div>`).join(''):'<div class="empty">当前没有产品。请先新增菜单。</div>';}
async function saveProduct(e){e.preventDefault();await busy($('productForm').querySelector('[type=submit]'),async()=>{
 const id=$('productId').value||null;const price=Number($('productPrice').value);if(!Number.isFinite(price)||price<0||price>5000)throw Error('请输入正确产品价格');
 unpack(await db.rpc('yt_pos_owner_product',{p_id:id,p_name:$('productName').value.trim(),p_category:$('productCategory').value.trim(),p_price:price,p_active:$('productActive').checked,p_sort:Number($('productSort').value)}));
 clearProduct();await loadCatalog();showNotice(id?'产品已更新':'产品已加入菜单');
 }).catch(()=>{});}
function editProduct(id){const p=state.catalog.find(x=>x.id===id);if(!p)return;showTab('admin');$('productId').value=p.id;$('productName').value=p.name;$('productCategory').value=p.category;$('productPrice').value=p.price_rm;$('productActive').checked=p.active;$('productSort').value=p.sort_order||100;window.scrollTo({top:0,behavior:'smooth'});}
function clearProduct(){$('productForm').reset();$('productId').value='';$('productActive').checked=true;$('productSort').value=100;}
async function loadRights(){if(!isOwner())return;const staff=unpack(await db.rpc('yt_pos_staff_list'))||[];
 $('staffRights').innerHTML=staff.length?staff.map(x=>`<div class="admin-entry"><div><strong>${esc(x.username)}</strong><small>${x.active?'Active':'Disabled'} · ${x.can_cashier?'Cashier Enabled':'Staff only'}</small></div><label class="checkline"><input type="checkbox" data-cashier="${esc(x.id)}" ${x.can_cashier?'checked':''} ${!x.active?'disabled':''}><span>Cashier</span></label></div>`).join(''):'<div class="empty">还没有 Staff 账户。</div>';}
async function changeRight(id,allowed,input){await busy(input,async()=>{if(!window.confirm(`确认${allowed?'授予':'撤销'}这个员工的 Cashier 权限？`)){input.checked=!allowed;return;}unpack(await db.rpc('yt_pos_owner_cashier_access',{p_staff:id,p_allowed:allowed}));showNotice('员工权限已经更新');await loadRights();}).catch(()=>{input.checked=!allowed;});}
function startPolling(){stopPolling();state.interval=setInterval(()=>{if(state.activeView==='dashboard')refreshOrders(true)},6500);}
function stopPolling(){if(state.interval){clearInterval(state.interval);state.interval=null;}}
function bind(){
 $('signinForm').addEventListener('submit',e=>login(e).catch(()=>{}));
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
 $('staffRights').onchange=e=>{const box=e.target.closest('input[data-cashier]');if(box)changeRight(box.dataset.cashier,box.checked,box);};
 document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible'&&state.activeView==='dashboard')refreshOrders(true);});
}
async function boot(){bind();if(!usable){resetLogin();showNotice('请检查 /play/config.js，POS 尚未连上 Supabase',true,true);return;}
 const {data,error}=await db.auth.getSession();if(!error&&data?.session){try{await launch();return;}catch(e){showNotice('请重新登录工作账号：'+errorText(e),true);}}
 resetLogin();}
boot().catch(e=>{resetLogin();showNotice(errorText(e),true,true);});
