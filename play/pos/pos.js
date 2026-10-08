import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';

// Yetipsy POS V1. Order creation and payment transitions always execute on Supabase.
// The browser never chooses product prices or changes a paid status directly.
const $=id=>document.getElementById(id);
const conf=window.YETIPSY_PLAY_CONFIG||{};
const portal=document.body.dataset.entry==='cashier'?'cashier':'work';
const usable=/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(conf.url||'')&&/^sb_publishable_/.test(conf.publishableKey||'');
const db=usable?createClient(conf.url,conf.publishableKey,{auth:{storageKey:portal==='cashier'?'yt-cashier-session-v2':'yt-work-session-v1',persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}}):null;
const workURL=(conf.url||'')+'/functions/v1/yt-work-auth';
const state={identity:null,catalog:[],cart:new Map(),currentTab:'benefits',
  active:[],paid:[],pending:[],seenPending:new Set(),seenInitialized:false,
  currentRequestId:null,refreshing:false,interval:null,noticeTimer:null,activeView:'login',
   series:[],rewardRules:[],editOrder:null,editCart:new Map(),redeemPending:null,scanStream:null,scanTimer:null,
  selectedOrderCart:null,activeRewardHold:null,ownerMemberList:[]};
const msgMap={staff_only:'需要有效员工账号',cashier_only:'需要 Cashier 权限',not_authenticated:'登录已过期，请重新登录',
  order_not_pending:'订单不在待接受状态',order_not_accepted:'订单必须先由 Cashier 接受',order_not_served:'请先完成出品，之后才能收款',
  product_unavailable:'这款产品已停止销售，请重新选择',order_too_large:'单笔订单金额或数量过大',
  invalid_line:'订单产品无效',invalid_order:'订单资料不正确',invalid_channel:'下单渠道无效',invalid_filter:'订单筛选条件无效',
  order_not_found:'找不到这张订单',request_conflict:'重复请求出现冲突，请重新开单',invalid_payment_method:'请选择正确的收款方式',
  order_cannot_cancel:'这张订单不能直接取消，已出品／已付款订单必须走人工处理流程',
  invalid_credentials:'账号或密码错误',owner_only:'只有 Owner 才能更改此设置',too_many_attempts:'错误尝试太多，请稍后再试',
  reason_required:'请填写至少两个字的取消／拒绝原因',
   pos_redemption_required:'这个奖品必须在 POS 中选择匹配商品兑换',reward_pos_disabled:'Owner 已暂停这份奖励兑换',
   reward_product_mismatch:'这份奖品不能兑换所选择的商品或系列',item_already_redeemed:'这一杯已经使用过奖励',item_already_assigned:'这杯已领取其他权益，不能再抵扣',
   reward_not_pos_bound:'此奖励尚未绑定 POS 商品或系列，请联系 Owner 先完成绑定',redeem_on_unpaid_accepted_order:'请先选择已接受、尚未结账的订单',
   cannot_cancel_redeemed_order:'订单已有奖励抵扣，不能直接取消，请联系 Owner 进行后续退款/调整',
   order_edit_permission_required:'Owner 未开放改单权限',paid_or_served_order_locked:'已付款／已出品订单不能直接改单',order_changed_reload:'订单已被其他员工修改，请刷新后再试',
   invalid_order_revision:'改单必须填写原因并保留至少一个商品',order_benefit_already_assigned:'商品已产生权益，不能直接改单',
   order_not_paid:'请先结账后再生成权益',benefits_after_payment_only:'订单出品并收款后才能发游戏权益',series_not_configured:'请让 Owner 为此产品配置权益系列',
   series_rule_not_ready:'该系列的多次游戏／积分方案暂未开放，请 Owner 先确定规则',unit_already_issued:'该杯已经发过 QR，不能重复发送。可在当前设备找回原码',
   item_not_in_order:'产品不属于这张账单',unit_not_in_order:'找不到对应商品单位',invalid_benefit_request:'选择的商品、活动或领取时限不正确',
   token_invalid:'请让顾客在 Wallet 重新生成兑奖 QR；已经成功预留的奖励不受 QR 图片过期影响',reward_unavailable:'奖品还不能兑换或已过期',role_mismatch:'请使用正确的 Cashier／Staff 登录入口',
  reward_pos_binding_required:'该奖励尚未由 Owner 绑定 POS 商品或系列',redeem_order_not_ready:'先让 Cashier 接受订单，且订单必须尚未结账',
  reward_reserved_by_other_order:'此奖品正预留在另一张订单，请取消之前的预留或等待到期',
  hold_expired_rescan:'预留已过期，请让顾客重新出示 Wallet QR 以续期',coupon_hold_not_ready_or_expired:'购物车仍有未选择商品或已过期的兑奖预留，请先处理',
  choose_reward_product:'请先选择奖品对应的赠饮',choose_discount_item:'请选择一项符合奖品条件的订单商品',
  reward_binding_changed_rescan:'Owner 已修改兑奖规则，请重新核对这张奖券',discount_amount_invalid:'优惠金额计算失败',
  pos_checkout_only:'领取奖励只能在 POS 购物车预留，最终结账时才会扣券',
  release_coupon_before_edit:'订单已预留奖励，修改产品前请先取消预留',
  release_coupon_before_cancel:'订单还有预留奖励，请先在购物车内取消预留',
  unit_already_reserved:'这杯饮品已被其他优惠占用',unit_not_available:'这杯商品已领取其他权益，无法再使用折扣',
  cannot_remove_prepared_reward_item:'赠饮已经出品，不能直接撤销预留；请先联系 Cashier 处理订单',
  coupon_no_longer_available:'奖品已失效，请让顾客再次核对',coupon_cart_item_missing:'赠饮／优惠商品已被修改，请检查订单'};
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
 if(result.must_change_password){$('signinForm').classList.add('hidden');$('firstPasswordForm').classList.remove('hidden');$('firstOldPassword').value=password;return;}
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
 buildNav();await Promise.all([loadCatalog(),refreshOrders(false)]);{const requested=new URL(location.href).searchParams.get('tab');const defaultPage=portal==='cashier'?'pending':'benefits';showTab(['benefits','orders','create','pending','history','reset','admin','more'].includes(requested)?requested:defaultPage);}startPolling();
}
async function changeCashierFirstPassword(e){e.preventDefault();const button=e.submitter;await busy(button,async()=>{
 const oldPw=$('firstOldPassword').value,newPw=$('firstNewPassword').value;
 if(newPw!==$('firstNewAgain').value)throw Error('两次输入的新密码不一致');
 const username=$('username').value.trim().toLowerCase();
 if(newPw.length<12||newPw.length>128||!/[A-Z]/.test(newPw)||!/[a-z]/.test(newPw)||!/\d/.test(newPw)||newPw.toLowerCase().includes(username))throw Error('新密码至少12位，需包含大小写字母及数字，不能含用户名');
 await work('password_change',{old_password:oldPw,new_password:newPw},true);
 await db.auth.signOut();$('firstPasswordForm').reset();$('password').value='';resetLogin();
 showNotice('工作账号新密码设置成功，请重新登录');
 }).catch(()=>{});}

function buildNav(){const nav=$('nav');const tabs=portal==='cashier'
  ?[['pending','▣ 待审核'],['orders','▤ 订单'],['create','＋ 点单'],['more','⋯ 更多']]
  :[['benefits','▣ Game Pass'],['orders','▤ 订单'],['create','＋ 点单'],['more','⋯ 更多']];
 nav.replaceChildren();for(const [key,label] of tabs){const b=document.createElement('button');b.type='button';b.dataset.tab=key;b.textContent=label;b.onclick=()=>showTab(key);nav.append(b);}}
function showTab(tab){
 if(tab==='redeem'){tab='orders';}
 if((tab==='pending'&&!isCashier())||(tab==='admin'&&!isOwner()))return;
 if(tab!=='create')closeCartDrawer();state.currentTab=tab;
 for(const section of ['create','pending','orders','history','benefits','redeem','reset','admin','more'])$('tab-'+section).classList.toggle('hidden',section!==tab);
 for(const b of $('nav').querySelectorAll('button'))b.classList.toggle('active',b.dataset.tab===tab ||
   (['history','reset','admin'].includes(tab)&&b.dataset.tab==='more'));
 if(tab==='admin')loadAdmin().then(loadOwnerRewardOffers).catch(e=>showNotice(errorText(e),true));
 if(tab==='benefits')loadBenefits().catch(e=>showNotice(errorText(e),true));
 if(tab==='pending'||tab==='orders'||tab==='history')refreshOrders(false).catch(e=>showNotice(errorText(e),true));
}
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
 $('cartCount').textContent=count+' 件';$('cartTotal').textContent=money(total);$('createOrderBtn').disabled=count===0;
 $('cartDockCount').textContent=count+' 件';$('cartDockTotal').textContent=money(total);
 $('cartDock').classList.toggle('has-items',count>0);}
function openCartDrawer(){if(state.currentTab!=='create'||state.activeView!=='dashboard')return;document.body.classList.add('cart-open');$('cartDock').setAttribute('aria-expanded','true');$('cartCloseBtn').focus({preventScroll:true});}
function closeCartDrawer(){document.body.classList.remove('cart-open');$('cartDock')?.setAttribute('aria-expanded','false');}
function adjustCart(id,delta){const p=state.catalog.find(x=>x.id===id&&x.active);if(!p)return;const before=state.cart.get(id)||0,next=Math.max(0,Math.min(20,before+delta));if(next===0)state.cart.delete(id);else state.cart.set(id,next);renderCart();}
async function createOrder(){const btn=$('createOrderBtn');await busy(btn,async()=>{
 if(!state.cart.size)throw Error('请先选择产品');const rows=[...state.cart].map(([id,qty])=>({product_id:id,quantity:qty}));
 const cashier=isCashier()&&$('cashierDirect').checked;const channel=cashier?'cashier':'staff';
 const request=state.currentRequestId||crypto.randomUUID();state.currentRequestId=request;
 const data=unpack(await db.rpc('yt_pos_create_order',{
  p_request:request,p_table:$('tableInput').value.trim()||null,p_note:$('orderNote').value.trim()||null,
  p_items:rows,p_channel:channel
 }));
 state.currentRequestId=null;state.cart.clear();$('orderNote').value='';renderCart();closeCartDrawer();
 showNotice(`${data.order_no} 创建成功 · ${cashier?'Cashier 已自动接受':'等待 Cashier 接受'}`);
 await refreshOrders(false);showTab('orders');if(cashier)openOrderCart(data.id).catch(e=>showNotice(errorText(e),true));
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
 return `<article class="order"><div class="order-head"><div><h3>#<span>${esc(row.order_no||'—')}</span> · ${esc(row.table_label||'Walk-in')}</h3><small>${esc(row.created_by_name||'Staff')} · ${stamp(row.created_at)}<br>消费先开单，收款最后确认</small><span class="order-status ${pay?'paid':cancelled?'cancelled':row.status==='pending'?'pending':''}">${statusLabel(row)}</span></div><div class="order-price">${money(row.amount_rm)}</div></div><div class="order-lines">${items}</div>${row.notes?`<small>备注：${esc(row.notes)}</small>`:''}${row.has_chit?'<small>▣ 已生成 Order Chit（待出品）</small>':''}${pay?`<small>✓ ${stamp(row.paid_at)} · ${esc(row.payment_method||'')}</small>`:''}${controls}<div class="receipt-actions"><button type="button" data-receipt="${escapeAttr(row.id)}">${pay?'预览 Receipt':'预览未付款账单'}</button>${!pay&&!cancelled&&['pending','confirmed'].includes(row.status)&&state.identity?.can_edit_orders?`<button type="button" data-edit="${escapeAttr(row.id)}">改单 · Audit</button>`:''}${!pay&&!cancelled&&['confirmed','fulfilled'].includes(row.status)?`<button type="button" class="primary" data-order-cart="${escapeAttr(row.id)}">▣ 购物车 · Redeem</button>`:''}${pay?`<button type="button" data-benefits="${escapeAttr(row.id)}">发 Game Pass ↗</button>`:''}</div></article>`;
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
 state.active=rows[0]||[];state.paid=rows[1]||[];state.pending=isCashier()?(rows[2]||[]):[];notifyPending();renderOrders();refreshRedeemOrderChoices();}
 catch(e){if(!silent)showNotice(errorText(e),true);}finally{state.refreshing=false;}}
const unpackPromise=async p=>unpack(await p);
async function orderAction(orderId,action,container){const btn=container;await busy(btn,async()=>{
 let reason=null,method=null;
 if(action==='reject'||action==='cancel'){reason=window.prompt('请填写拒绝／取消原因（必填）','客人取消');if(reason===null)return;if(reason.trim().length<2)throw Error('reason_required');}
 if(action==='paid'){const card=btn.closest('.order');method=card?.querySelector('[data-payment]')?.value||'foodcourt';
   const quote=unpack(await db.rpc('yt_pos_cart_summary',{p_order:orderId}));
   if(!quote.can_pay)throw Error('coupon_hold_not_ready_or_expired');
   if(!window.confirm(`确认已收到 ${money(quote.payable_rm)}？\n已预留优惠：−${money(quote.reserved_discount_rm)}\n收款方式：${method.toUpperCase()}\n\n点击确认后才会正式使用顾客奖券。`))return;}
 if(action==='fulfilled'&&!window.confirm('确认这些产品都已完成出品？'))return;
 const result=unpack(await db.rpc('yt_pos_action',{p_order:orderId,p_action:action,p_reason:reason,p_method:method}));
 showNotice(({accept:'已接受，订单进入制作队列',reject:'订单已拒绝',fulfilled:'已完成出品，等待结账',paid:'已经记录收款',cancel:'订单已取消'})[action]||'状态已更新');
 await refreshOrders(false);
 }).catch(()=>{});}
async function loadAdmin(){if(!isOwner())return;await loadCatalog();await Promise.all([loadRights(),loadRewardRules()]);}
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
async function loadRewardRules(){
 if(!isOwner())return;
 state.rewardRules=unpack(await db.rpc('yt_pos_owner_reward_rules'))||[];
 const select=$('mapReward');const old=select.value;select.replaceChildren(new Option('请选择奖品',''));
 for(const r of state.rewardRules)select.add(new Option(`${r.reward_name}${!r.active?'（已停用）':''}`,r.reward_id));
 if(state.rewardRules.some(r=>r.reward_id===old))select.value=old;
 const product=$('mapProduct'),ps=product.value;product.replaceChildren(new Option('选择具体产品',''));
 for(const item of state.catalog)if(item.active)product.add(new Option(`${item.name} · ${money(item.price_rm)}`,item.id));
 if(state.catalog.some(x=>x.id===ps))product.value=ps;
 const series=$('mapSeries'),oldS=series.value;series.replaceChildren(new Option('选择产品系列',''));
 for(const item of state.series)if(item.active)series.add(new Option(item.name,item.id));
 if(state.series.some(x=>x.id===oldS))series.value=oldS;
 updateRewardMapForm();renderRewardMappings();
}
function updateRewardMapForm(){
 const r=state.rewardRules?.find(x=>x.reward_id===$('mapReward').value);
 $('mapMode').value=r?.mode==='series'?'series':r?.mode==='disabled'?'disabled':'product';
 $('mapProduct').value=r?.product_id||'';
 $('mapSeries').value=r?.series_id||'';
 $('mapDiscountType').value=r?.discount_type||'free';$('mapDiscountValue').value=r?.discount_value||5;
 toggleMapInputs();
}
function toggleMapInputs(){
 const mode=$('mapMode').value;
 $('mapProductLabel').classList.toggle('hidden',mode!=='product');
 $('mapSeriesLabel').classList.toggle('hidden',mode!=='series');
 $('mapDiscountValueLabel').classList.toggle('hidden',$('mapDiscountType').value==='free');
}
function renderRewardMappings(){
 const el=$('rewardMappingList');if(!el)return;
 el.innerHTML=(state.rewardRules||[]).slice(0,120).map(r=>{
  const product=state.catalog.find(p=>p.id===r.product_id)?.name;
  const series=state.series.find(p=>p.id===r.series_id)?.name;
  const info=r.mode==='product'?'✓ 指定商品：'+(product||'已停售商品'):r.mode==='series'?'✓ 指定系列：'+(series||'历史系列'):r.mode==='disabled'?'暂停兑奖':'未绑定 · 禁止发放和核销';
  const discount=['product','series'].includes(r.mode)?' · '+(r.discount_type==='fixed'?'RM'+r.discount_value+' 抵扣':r.discount_type==='percent'?r.discount_value+'% 折扣':'免费一杯'):'';
  return `<button class="reward-map-item" type="button" data-reward-map="${esc(r.reward_id)}"><strong>${esc(r.reward_name)}</strong><small>${esc(info+discount)}</small></button>`;
 }).join('');
 const pending=(state.rewardRules||[]).filter(r=>!['product','series'].includes(r.mode)).length;
 $('rewardBindingSummary').textContent=pending?`⚠ 还有 ${pending} 种奖品未绑定商品／系列（或处于暂停），不允许新发放或核销。请逐一设置。`:'✓ 所有现有奖品均已绑定 POS，可按指定产品／系列核销。';
 $('rewardBindingSummary').classList.toggle('all-bound',pending===0);
}
async function saveRewardMap(e){e.preventDefault();const btn=e.submitter;await busy(btn,async()=>{
 const id=$('mapReward').value,mode=$('mapMode').value;
 if(!id)throw Error('请先选择奖品');
 const product=mode==='product'?$('mapProduct').value:null;
 const series=mode==='series'?$('mapSeries').value:null;
 if(mode==='product'&&!product||mode==='series'&&!series)throw Error('必须选择对应的产品或系列');
 if(!['product','series','disabled'].includes(mode))throw Error('所有奖品必须绑定 POS 商品／系列，或设为暂停');
 const discountType=$('mapDiscountType').value,discountValue=discountType==='free'?0:Number($('mapDiscountValue').value);
 if(discountType!=='free'&&(!Number.isFinite(discountValue)||discountValue<=0))throw Error('必须填写正确的 RM 或百分比折扣');
 unpack(await db.rpc('yt_pos_owner_reward_rule_save_v2',{
  p_reward:id,p_mode:mode,p_product:product||null,p_series:series||null,
  p_type:discountType,p_value:discountValue
 }));await loadRewardRules();$('mapReward').value=id;updateRewardMapForm();showNotice('奖品兑换限制已保存到服务器');
 }).catch(()=>{});}

async function preparePinReset(e){e.preventDefault();await busy(e.submitter,async()=>{
 if(!$('resetConfirmed').checked)throw Error('请先在现场核对顾客身份');
 const country=$('resetCountry').value;
 let digits=$('resetPhone').value.trim().replace(/\D/g,'');
 if(country==='+60'){
   if(digits.startsWith('60'))digits=digits.slice(2);
   if(digits.startsWith('0'))digits=digits.slice(1);
   if(!/^1\d{8,9}$/.test(digits))throw Error('马来西亚手机号格式不正确');
 }else{
   if(digits.startsWith('65'))digits=digits.slice(2);
   if(!/^[89]\d{7}$/.test(digits))throw Error('新加坡手机号格式不正确');
 }
 const phone=country+digits,birthday=$('resetBirthday').value;
 if(!birthday)throw Error('请确认顾客出生日期');
 const resp=await fetch(conf.url+'/functions/v1/yt-pin-auth',{
  method:'POST',headers:{'Content-Type':'application/json',apikey:conf.publishableKey},
  cache:'no-store',body:JSON.stringify({action:'reset_prepare',phone,birthday,onsite_confirmed:true})
 });
 const data=await resp.json().catch(()=>({ok:false,error:'server_unavailable'}));
 if(!resp.ok||!data.ok)throw Error(data.message||data.error||'PIN 重设失败');
 const link=portalClientUrl();link.searchParams.set('reset',data.token);
 const root=$('resetQR');root.classList.remove('hidden');root.replaceChildren();
 const head=document.createElement('strong');head.textContent='顾客专属重设链接 · 5 分钟有效';
 const qr=document.createElement('div');qr.className='qr-screen';
 const text=document.createElement('p');text.className='qr-link';text.textContent=link.href;
 const copy=document.createElement('button');copy.type='button';copy.className='quiet';copy.textContent='复制重设链接';
 copy.onclick=()=>navigator.clipboard?.writeText(link.href).then(()=>showNotice('已复制'));
 root.append(head,qr,text,copy);
 if(await qrLibrary())new window.QRCode(qr,{text:link.href,width:206,height:206});
 else qr.textContent='二维码图片暂不可用，可复制链接交给本人。';
 showNotice('已验证现场资料，PIN 重设二维码已生成');
 }).catch(()=>{});}

async function changeRight(id,allowed,input){await busy(input,async()=>{if(!window.confirm(`确认${allowed?'授予':'撤销'}这个员工的 Cashier 权限？`)){input.checked=!allowed;return;}unpack(await db.rpc('yt_pos_owner_cashier_access',{p_staff:id,p_allowed:allowed}));showNotice('员工权限已经更新');await loadRights();}).catch(()=>{input.checked=!allowed;});}
// POS V2 — server-enforced order revisions, per-unit QR benefits, receipts and redemption.
const friendlyDate=d=>d?stamp(d):'—';
const portalClientUrl=()=>new URL('../',import.meta.url);
function receiptInner(r){
 const paid=r.payment_status==='paid';
 const items=(r.items||[]).map(i=>`<div class="receipt-row"><div><strong>${esc(i.item_name||'Drink')}</strong><small>${Number(i.quantity)} × ${money(i.unit_price_rm)}${Number(i.discount_rm)>0?' · Reward 已抵扣 '+money(i.discount_rm):''}</small></div><b>${money(i.line_total_rm)}</b></div>`).join('');
 const discount=Number(r.discount_total_rm||0);
 return `<div class="receipt-paper" id="receiptPaper"><div class="receipt-logo">YE<span>·</span>TIPSY</div><div class="receipt-subhead">KLUANG · POINT OF SALE</div>
 <div class="receipt-document">${paid?'✓ PAYMENT RECEIPT · 已收款':'UNPAID BILL · 尚未结账'}</div>
 <div class="receipt-facts"><p><strong>#${esc(r.order_no||'—')}</strong></p><p>Table · ${esc(r.table_label||'Walk-in')}</p><p>Created · ${esc(friendlyDate(r.created_at))}</p><p>By · ${esc(r.created_by||'—')}</p>
 ${paid?`<p>Paid · ${esc(friendlyDate(r.paid_at))}</p><p>Payment · ${esc((r.payment_method||'foodcourt').toUpperCase())}</p>`:''}
 ${r.notes?`<p>Note · ${esc(r.notes)}</p>`:''}</div>
 <div class="receipt-items-head"><span>ITEM</span><span>AMOUNT</span></div>${items}
 ${discount>0?`<div class="receipt-discount"><span>产品奖励抵扣</span><b>−${money(discount)}</b></div>`:''}
 <div class="receipt-sum"><span>${paid?'TOTAL PAID':'AMOUNT DUE'}</span><strong>${money(r.amount_rm)}</strong></div>
 <p class="receipt-bottom">Thank you for visiting Yetipsy.<br>Internal POS record · Not a tax invoice.<br>Foodcourt payment is manually recorded.</p>
 </div>`;
}
async function viewReceipt(orderId){
 const [receiptResult,quoteResult]=await Promise.all([db.rpc('yt_pos_receipt',{p_order:orderId}),db.rpc('yt_pos_cart_summary',{p_order:orderId})]);
 const data=unpack(receiptResult),quote=unpack(quoteResult);
 $('receiptContent').innerHTML=receiptInner(data)+(data.payment_status==='paid'?'':`<div class="receipt-pending-note">预留优惠（结账后正式核销） −${money(quote.reserved_discount_rm)}<br><b>预计应收 ${money(quote.payable_rm)}</b></div>`);
 $('receiptTitle').textContent='#'+(data.order_no||'ORDER')+' · '+(data.payment_status==='paid'?'Receipt':'未付款账单');
 $('receiptOverlay').classList.remove('hidden');
 document.body.classList.add('sheet-open');
 $('receiptClose').focus();
}
function closeReceipt(){ $('receiptOverlay').classList.add('hidden');document.body.classList.remove('sheet-open'); }
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
  const ready=!unit.reward_redeemed&&unit.series_active&&['games','choose'].includes(unit.benefit_mode)&&Number(unit.game_plays)===1;
  const issued=!!unit.game_pass_id;
  const expired=issued&&unit.pass_status==='issued'&&!!unit.pass_expires_at&&Date.parse(unit.pass_expires_at)<=Date.now();
  const claimed=!!unit.reward_redeemed||(issued&&(unit.pass_status==='claimed'||unit.pass_status==='used'||unit.assigned));
  const key='yt-pos-v2-unit:'+unit.order_item_id+':'+unit.unit_number;
  let original=null;try{original=JSON.parse(sessionStorage.getItem(key)||'null')}catch{}
  const recover=issued&&!expired&&!claimed&&original;
  const card=document.createElement('div');card.className='order-note';
  const summary=document.createElement('div');summary.innerHTML=`<strong>${esc(unit.product_name)} · 第 ${unit.unit_number} 份</strong><small>单杯 ${money(unit.unit_price_rm)} · ${esc(unit.series_name||'未分配系列')}</small><small>${issued?'✓ 已生成 QR':ready?'可生成':'Owner 尚未配置可用权益规则'}</small>`;
  const btn=document.createElement('button');btn.type='button';btn.className='primary';
  btn.dataset.issueUnit='1';btn.dataset.item=unit.order_item_id;btn.dataset.unit=String(unit.unit_number);
  btn.textContent=unit.reward_redeemed?'已用于兑换奖励':claimed?'已领取':recover?'重新显示 QR':expired?'过期重发 QR':issued?'已发出':ready?'生成专属 QR':'不可发';
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
function refreshRedeemOrderChoices(){
 const sel=$('redeemOrderSelect');if(!sel)return;
 const old=sel.value;sel.replaceChildren(new Option('选择现场待结账订单',''));
 for(const o of state.active.filter(o=>o.payment_status==='unpaid' && ['confirmed','fulfilled'].includes(o.status)))
  sel.add(new Option(`#${o.order_no} · ${o.table_label||'Walk-in'} · ${money(o.amount_rm)}`,o.id));
 if([...sel.options].some(x=>x.value===old))sel.value=old;
}
async function lookupPOSRedeem(){
 const order=$('redeemOrderSelect').value;if(!order)throw Error('请先选择已接受的现场订单');
 const token=$('redeemToken').value;
 await openOrderCart(order);$('cartRedeemToken').value=token;
 await reserveInCart();
}
async function confirmPOSItemRedeem(){throw Error('pos_checkout_only');}
async function confirmPOSRedeem(){throw Error('pos_checkout_only');}
function stopRedeemCamera(){
 if(state.scanTimer){clearInterval(state.scanTimer);state.scanTimer=null;}
 if(state.scanStream){for(const track of state.scanStream.getTracks())track.stop();state.scanStream=null;}
 $('redeemVideo').classList.add('hidden');$('cartRedeemVideo').classList.add('hidden');
}
async function startRedeemCamera(){
 if(!state.selectedOrderCart&&!$('redeemOrderSelect').value)throw Error('请先选择一张待结账订单，再打开相机扫码');
 if(state.scanStream){stopRedeemCamera();return;}
 if(!navigator.mediaDevices?.getUserMedia||typeof BarcodeDetector==='undefined')throw Error('当前浏览器不支持相机扫码，请粘贴兑奖二维码内容');
 const stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:'environment'}});
 state.scanStream=stream;const video=state.selectedOrderCart?$('cartRedeemVideo'):$('redeemVideo');video.srcObject=stream;video.classList.remove('hidden');await video.play();
 const detector=new BarcodeDetector({formats:['qr_code']});
 state.scanTimer=setInterval(async()=>{
  if(!state.scanStream)return;
  try{const codes=await detector.detect(video);if(codes.length){if(state.selectedOrderCart){$('cartRedeemToken').value=codes[0].rawValue;stopRedeemCamera();await reserveInCart();}
       else{$('redeemToken').value=codes[0].rawValue;stopRedeemCamera();await lookupPOSRedeem();}}}catch(e){console.warn('Barcode scan:',e)}
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

// POS V4 - Cart-integrated reward preflight. The 60-second Wallet QR only authenticates
// the reservation; actual user_rewards redemption is committed by DB checkout trigger.
function escapeOrderCart(){stopRedeemCamera();state.selectedOrderCart=null;state.activeRewardHold=null;
 $('orderCartOverlay').classList.add('hidden');document.body.classList.remove('sheet-open');}
async function openOrderCart(id){
 state.selectedOrderCart=id;state.activeRewardHold=null;$('cartRedeemToken').value='';
 $('cartRedeemChoices').innerHTML='';$('orderCartOverlay').classList.remove('hidden');
 document.body.classList.add('sheet-open');await refreshOrderCart();
}
async function refreshOrderCart(){if(!state.selectedOrderCart)return;
 const id=state.selectedOrderCart;
 const [receipt,summary]=await Promise.all([
  db.rpc('yt_pos_receipt',{p_order:id}),db.rpc('yt_pos_cart_summary',{p_order:id})]);
 const bill=unpack(receipt),q=unpack(summary);
 $('orderCartTitle').textContent='#'+(q.order_no||bill.order_no)+' · 购物车';
 $('orderCartItems').innerHTML=(bill.items||[]).map(item=>`<div class="cart-preview-item"><strong>${esc(item.item_name)} × ${Number(item.quantity)}</strong><span>${money(item.quantity*item.unit_price_rm)}</span></div>`).join('');
 $('orderCartHolds').innerHTML=(q.holds||[]).length?q.holds.map(h=>`<div class="cart-discount-line"><div><strong>− ${esc(h.reward_name)}</strong><small>${h.can_checkout?'已预留，结账才核销':h.state==='reserved'?'待选择商品':'预留超时，请重新扫码'} · 有效至 ${stamp(h.expires_at)}</small></div><b>−${money(h.discount_rm)}</b>${q.payment_status==='unpaid'?`<button type="button" class="quiet" data-release-hold="${esc(h.id)}">释放</button>`:''}</div>`).join(''):'<p class="muted">当前没有预留奖励。</p>';
 $('orderCartGross').textContent=money(q.gross_rm);
 $('orderCartDiscount').textContent='−'+money(q.reserved_discount_rm);
 $('orderCartPayable').textContent=money(q.payable_rm);
 $('orderCartStatus').textContent=q.unresolved_count>0?`有 ${q.unresolved_count} 份未完成选择或已超时的奖励，请先处理。`:
 q.status==='confirmed'?'奖品已加入购物车，需确认出品完成后才可以结账；扫码不会立即扣券。':
 '✓ 扫码预留不会立即消耗 Wallet 奖品，结账时才扣券。';
 $('orderCartStatus').classList.toggle('warn',q.unresolved_count>0);
 $('cartRedeemForm').classList.toggle('hidden',q.payment_status!=='unpaid'||!['confirmed','fulfilled'].includes(q.status));
 $('cartCheckoutControls').classList.toggle('hidden',!isCashier()||q.payment_status==='paid');
 $('cartCheckoutBtn').disabled=!q.can_pay;
 $('cartCheckoutPayment').value='foodcourt';
}
async function reserveInCart(){const btn=$('cartReserveBtn');await busy(btn,async()=>{
 const order=state.selectedOrderCart;if(!order)throw Error('请选择订单');
 const token=parseRedeemToken($('cartRedeemToken').value);
 const hold=unpack(await db.rpc('yt_pos_cart_reserve',{p_order:order,p_token:token,p_request:crypto.randomUUID()}));
 $('cartRedeemToken').value='';
 state.activeRewardHold=hold;
 await displayRewardHoldChoices(hold);
 await refreshOrderCart();
 showNotice('QR 已核对并预留，奖券仍在 Wallet，完成结账后才会被使用');
 }).catch(()=>{});}
async function displayRewardHoldChoices(hold){
 const root=$('cartRedeemChoices');root.replaceChildren();
 if(hold.state==='ready'){root.innerHTML='<div class="redeem-banner success">✓ 奖励已在本单预留，结账时正式使用。</div>';return;}
 const banner=document.createElement('div');banner.className='redeem-banner';
 banner.innerHTML=`<strong>✓ ${esc(hold.reward_name)}</strong><small>已预留至 ${stamp(hold.expires_at)}。即使扫码 QR 已过 60 秒，预留仍有效。</small>`;
 root.append(banner);
 if(hold.discount_type==='free'){
  const names=hold.products||[];
  if(!names.length){root.insertAdjacentHTML('beforeend','<div class="empty">没有开放的兑换商品，请 Owner 先建立该系列产品。</div>');return;}
  if(hold.mode==='product'&&names.length===1){await chooseRewardHold(hold,{p_product:names[0].product_id});return;}
  root.insertAdjacentHTML('beforeend','<p class="muted">请选择要赠送的一款商品（加入当前购物车）。</p>');
  for(const x of names){const b=document.createElement('button');b.className='reward-choice';b.type='button';b.textContent=`＋ ${x.name} · ${money(x.price_rm)} → 免费加入购物车`;
   b.onclick=()=>chooseRewardHold(hold,{p_product:x.product_id}).catch(e=>showNotice(errorText(e),true));root.append(b);}
 }else{
  const choices=unpack(await db.rpc('yt_pos_cart_discount_units',{p_hold:hold.hold_id}))||[];
  if(!choices.length){root.insertAdjacentHTML('beforeend','<div class="empty">本单暂时没有匹配的商品，请先添加符合规则的商品或取消预留。</div>');return;}
  if(choices.length===1){await chooseRewardHold(hold,{p_item:choices[0].item_id,p_unit:choices[0].unit_number});return;}
  root.insertAdjacentHTML('beforeend','<p class="muted">选择要应用 Discount 的一杯商品：</p>');
  for(const x of choices){const b=document.createElement('button');b.className='reward-choice';b.type='button';b.textContent=`${x.name} · #${x.unit_number} → −${money(x.discount_rm)}`;
   b.onclick=()=>chooseRewardHold(hold,{p_item:x.item_id,p_unit:x.unit_number}).catch(e=>showNotice(errorText(e),true));root.append(b);}
 }
}
async function chooseRewardHold(hold,fields){
 const result=unpack(await db.rpc('yt_pos_cart_choose',{
  p_hold:hold.hold_id,p_product:fields.p_product||null,p_item:fields.p_item||null,p_unit:fields.p_unit||null
 }));
 $('cartRedeemChoices').innerHTML=`<div class="redeem-banner success"><strong>✓ 已预留 ${esc(hold.reward_name)}</strong><p>购物车抵扣 −${money(result.discount_rm)}。结账前不会使用奖券。</p></div>`;
 state.activeRewardHold=null;await refreshOrderCart();await refreshOrders(false);
 if(result.added_to_cart)showNotice('赠送饮品已加入购物车，请再次确认出品完成后才能结账');
}
async function releaseCartHold(id){
 if(!window.confirm('撤销本单的奖励预留？顾客 Wallet 不会扣券。'))return;
 unpack(await db.rpc('yt_pos_cart_release',{p_hold:id}));
 state.activeRewardHold=null;$('cartRedeemChoices').replaceChildren();
 await refreshOrderCart();await refreshOrders(false);showNotice('已释放预留，顾客奖品仍可使用');
}
async function checkoutOrderCart(){const btn=$('cartCheckoutBtn');await busy(btn,async()=>{
 if(!isCashier())throw Error('cashier_only');
 const q=unpack(await db.rpc('yt_pos_cart_summary',{p_order:state.selectedOrderCart}));
 if(!q.can_pay)throw Error('coupon_hold_not_ready_or_expired');
 const method=$('cartCheckoutPayment').value;
 if(!window.confirm(`确认已实际收到 ${money(q.payable_rm)}？\n本单优惠：−${money(q.reserved_discount_rm)}\n\n确认后才正式核销所有预留奖励，此动作不能随意撤销。`))return;
 unpack(await db.rpc('yt_pos_action',{p_order:state.selectedOrderCart,p_action:'paid',p_method:method,p_reason:null}));
 await refreshOrderCart();await refreshOrders(false);
 $('cartRedeemChoices').innerHTML='<div class="redeem-banner success">✓ 已结账，奖励已正式使用，Receipt 金额已更新。</div>';
 showNotice('Foodcourt／Cashier 收款已登记，奖券已随结账正式核销');
 }).catch(()=>{});}
// Compact Owner issuance: only rewards with an active SKU/series binding are selectable.
async function loadOwnerRewardOffers(){
 if(!isOwner())return;
 const eligible=(state.rewardRules||[]).filter(r=>r.active&&['product','series'].includes(r.mode));
 const rewards=$('ownerGiveReward');if(!rewards)return;
 const old=rewards.value;rewards.replaceChildren(new Option('选择已绑定 POS 的奖品',''));
 eligible.forEach(r=>rewards.add(new Option(r.reward_name,r.reward_id)));
 if(eligible.some(r=>r.reward_id===old))rewards.value=old;
 const result=await db.from('profiles').select('id,display_name,phone').not('phone','is',null).order('created_at',{ascending:false}).limit(300);
 if(result.error)throw result.error;
 state.ownerMemberList=result.data||[];
 const sel=$('ownerGiveMember'),previous=sel.value;sel.replaceChildren(new Option('选择会员（最近 300 个）',''));
 state.ownerMemberList.forEach(m=>sel.add(new Option((m.display_name||'Member')+' · '+(m.phone||''),m.id)));
 if(state.ownerMemberList.some(m=>m.id===previous))sel.value=previous;
}
async function ownerCreateNewReward(event){event.preventDefault();const button=event.submitter;await busy(button,async()=>{
 if(!isOwner())throw Error('owner_only');
 const name=$('ownerNewRewardName').value.trim(),days=Number($('ownerNewRewardDays').value);
 if(name.length<2||!Number.isInteger(days)||days<1||days>365)throw Error('请输入奖励名称及正确有效天数');
 const reward=unpack(await db.rpc('yt_create_reward_v11',{
  p_name:name,p_description:$('ownerNewRewardDesc').value.trim(),p_category:$('ownerNewRewardCategory').value,
  p_validity:days,p_next_day:$('ownerNewRewardNextDay').checked,
  p_use_from:null,p_use_until:null,p_daily_from:null,p_daily_until:null
 }));
 $('ownerNewRewardForm').reset();await loadRewardRules();
 $('mapReward').value=String(reward);updateRewardMapForm();
 $('mapReward').scrollIntoView({block:'center',behavior:'smooth'});
 showNotice('奖励已创建，请在上面的奖品绑定栏设置 POS 商品／系列，否则无法领取和核销。');
 }).catch(()=>{});}
async function ownerDirectGift(){const btn=$('ownerSendGift');await busy(btn,async()=>{
 const member=$('ownerGiveMember').value,reward=$('ownerGiveReward').value;
 if(!member||!reward)throw Error('请选择已绑定的奖品和顾客');
 if(!window.confirm('确认把这份 POS 绑定的奖励直接加入该顾客 Wallet？'))return;
 unpack(await db.rpc('yt_send_reward',{p_customer:member,p_reward:reward,p_request:crypto.randomUUID()}));
 showNotice('奖品已发放，顾客必须在 POS 购物车扫码并结账才会使用');
 }).catch(()=>{});}
async function ownerGiftClaimQR(){const btn=$('ownerIssueGiftQR');await busy(btn,async()=>{
 const reward=$('ownerGiveReward').value;if(!reward)throw Error('请选择一个已绑定的奖品');
 const until=$('ownerGiftUntil').value;
 if(!until||new Date(until).getTime()<=Date.now()+60000)throw Error('设置有效的领取截止时间');
 const token=crypto.randomUUID();
 const cap=Number($('ownerGiftTotal').value);if(!Number.isInteger(cap)||cap<1||cap>10000)throw Error('数量需为 1–10000');
 unpack(await db.rpc('yt_create_offer',{
  p_reward:reward,p_token:token,p_from:new Date().toISOString(),p_until:new Date(until).toISOString(),
  p_max:cap,p_per_user:1
 }));
 const link=portalClientUrl();link.searchParams.set('gift',token);
 const root=$('ownerGiftLink');root.replaceChildren();root.classList.remove('hidden');
 const t=document.createElement('strong');t.textContent='已生成领取链接 · 顾客领入 Wallet 后须 POS 结账才核销';
 const qr=document.createElement('div');qr.className='qr-screen';const a=document.createElement('a');a.href=link.href;a.textContent=link.href;a.className='qr-link';a.target='_blank';a.rel='noreferrer';
 root.append(t,qr,a);
 if(await qrLibrary())new window.QRCode(qr,{text:link.href,width:204,height:204});
 else qr.textContent='二维码图片暂时无法加载，仍可复制领取链接。';
 showNotice('已创建 Reward Claim，奖励绑定规则将在 POS 结账时验证');
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
 $('cartDock').onclick=openCartDrawer;$('cartShade').onclick=closeCartDrawer;$('cartCloseBtn').onclick=closeCartDrawer;
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
  $('redeemCheck').onclick=e=>{const b=e.target.closest('[data-confirm-redeem]');if(b)confirmPOSRedeem(b).catch(()=>{});const u=e.target.closest('[data-pos-redeem]');if(u)confirmPOSItemRedeem(u).catch(()=>{});};
  document.body.addEventListener('click',e=>{const receipt=e.target.closest('[data-receipt]');if(receipt)viewReceipt(receipt.dataset.receipt).catch(e=>showNotice(errorText(e),true));
   const edit=e.target.closest('[data-edit]');if(edit)openEditDialog(edit.dataset.edit).catch(e=>showNotice(errorText(e),true));
   const benefit=e.target.closest('[data-benefits]');if(benefit){showTab('benefits');$('benefitOrderSelect').value=benefit.dataset.benefits;loadSelectedPaidUnits().catch(err=>showNotice(errorText(err),true));}});
  $('editClose').onclick=closeEditDialog;$('editForm').onsubmit=submitEditOrder;
 $('receiptClose').onclick=closeReceipt;$('receiptPrint').onclick=()=>window.print();$('receiptOverlay').onclick=e=>{if(e.target===$('receiptOverlay'))closeReceipt();};
 $('mapReward').onchange=updateRewardMapForm;$('mapMode').onchange=toggleMapInputs;$('mapDiscountType').onchange=toggleMapInputs;$('rewardMapForm').onsubmit=saveRewardMap;
 $('rewardMappingList').onclick=e=>{const b=e.target.closest('[data-reward-map]');if(b){$('mapReward').value=b.dataset.rewardMap;updateRewardMapForm();$('mapReward').scrollIntoView({behavior:'smooth',block:'center'});}};
 $('resetPinForm').onsubmit=preparePinReset;document.querySelectorAll('[data-go-tab]').forEach(b=>b.onclick=()=>showTab(b.dataset.goTab));
 document.addEventListener('keydown',e=>{if(e.key==='Escape'){if(document.body.classList.contains('cart-open'))closeCartDrawer();else if(!$('orderCartOverlay').classList.contains('hidden'))escapeOrderCart();else if(!$('receiptOverlay').classList.contains('hidden'))closeReceipt();}});
  $('editLineList').onchange=event=>{const inp=event.target.closest('[data-edit-qty],[data-edit-product]');if(inp)editDialogChange(inp);};
  $('editAddProduct').onclick=()=>{const p=state.catalog.find(p=>p.active);if(p){state.editCart.set(crypto.randomUUID(),{product_id:p.id,quantity:1});renderEditRows();}};
 $('orderCartClose').onclick=escapeOrderCart;
 $('orderCartOverlay').onclick=e=>{if(e.target===$('orderCartOverlay'))escapeOrderCart();};
 $('cartReserveBtn').onclick=reserveInCart;
 $('cartScanCamera').onclick=()=>startRedeemCamera().catch(e=>showNotice(errorText(e),true));
 $('cartCheckoutBtn').onclick=checkoutOrderCart;
 $('orderCartHolds').onclick=e=>{const b=e.target.closest('button[data-release-hold]');if(b)releaseCartHold(b.dataset.releaseHold).catch(err=>showNotice(errorText(err),true));};
 $('ownerSendGift').onclick=ownerDirectGift;$('ownerIssueGiftQR').onclick=ownerGiftClaimQR;$('ownerNewRewardForm').onsubmit=ownerCreateNewReward;
 document.body.addEventListener('click',e=>{const btn=e.target.closest('[data-order-cart]');if(btn)openOrderCart(btn.dataset.orderCart).catch(err=>showNotice(errorText(err),true));});

 document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible'&&state.activeView==='dashboard')refreshOrders(true);});
}
async function boot(){bind();if(!usable){resetLogin();showNotice('请检查 /play/config.js，POS 尚未连上 Supabase',true,true);return;}
 const {data,error}=await db.auth.getSession();if(!error&&data?.session){try{await launch();return;}catch(e){showNotice('请重新登录工作账号：'+errorText(e),true);}}
 resetLogin();}
boot().catch(e=>{resetLogin();showNotice(errorText(e),true,true);});
