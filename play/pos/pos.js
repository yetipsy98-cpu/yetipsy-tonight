import {createPlayWork} from './play-upgrade.js?v=20261015-service-bell-cashier-only-v1';
import {revisionSummary,benefitSummary,revisionHistory} from './owner-order-edit.js?v=20261010-copy-v15-4';
import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';
import {createCustomPricing} from './custom-pricing.js?v=20261016-v1';
import {createBannerManager} from '../owner-banners.js?v=20261010-copy-v15-4';
import {createConsole} from './console.js?v=20261015-tool-pane-visibility-fix-v1';
import {applyReceiptLayout} from './receipt-layout.js?v=20261012-v22';
import {createOwnerOrderApprovals} from './owner-order-approvals.js?v=20261015-orders-approvals-v1';
import {createStoreBox} from './store-box.js?v=20261015-storebox-stability-v1';
import {createAmbassadorTools} from './ambassador.js?v=20261015-nav-storebox-qr-amb-page-binding-v1';

// Yetipsy POS V1. Order creation and payment transitions always execute on Supabase.
// The browser never chooses product prices or changes a paid status directly.
const $=id=>document.getElementById(id);
const conf=window.YETIPSY_PLAY_CONFIG||{};
const portal='work';
// Keep an existing Cashier login when all entry points adopt the shared workspace.
try{if(!localStorage.getItem('yt-work-session-v1')&&localStorage.getItem('yt-cashier-session-v2'))localStorage.setItem('yt-work-session-v1',localStorage.getItem('yt-cashier-session-v2'));localStorage.removeItem('yt-cashier-session-v2');}catch{}
const usable=/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(conf.url||'')&&/^sb_publishable_/.test(conf.publishableKey||'');
const db=usable?createClient(conf.url,conf.publishableKey,{auth:{storageKey:'yt-work-session-v1',persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}}):null;
const workURL=(conf.url||'')+'/functions/v1/yt-work-auth';
const state={identity:null,catalog:[],cart:new Map(),currentTab:'benefits',
  active:[],paid:[],pending:[],revisionRequests:[],seenPending:new Set(),seenInitialized:false,seenKds:new Set(),seenKdsInitialized:false,storeBoxQueue:[],seenStoreBox:new Set(),seenStoreBoxInitialized:false,ambassadorAccess:false,ambassadorDraft:null,
  currentRequestId:null,refreshing:false,interval:null,noticeTimer:null,activeView:'login',
  series:[],rewardRules:[],editOrder:null,editCart:new Map(),redeemPending:null,scanStream:null,scanTimer:null,luckyMode:null,luckyModeLoadedAt:0,
  selectedOrderCart:null,activeRewardHold:null,ownerMemberList:[],draftId:null,draftSummary:null,draftEpoch:0,draftLoading:false,draftSaving:false,draftMutating:false,draftSelection:null,pendingSubmit:null,scanEpoch:0,
  ownerDashboard:null,ownerDashboardDay:null,ownerDashboardLoading:false,duitnowQrPath:null,duitnowQrLoaded:false,duitnowQrError:null,kdsHistory:null,kdsHistoryDay:null,kdsHistoryLoading:false,duitnowProofFile:null,duitnowProofUrl:null,duitnowProofStream:null,duitnowProofs:[],authUserId:null};
const msgMap={game_points_already_used:'本单积分已花费或到期，不能撤销；可保留权益后改单',benefits_current_day_only:'只能分配当前营业日订单的 GamePass',pass_already_claimed:'顾客已领取，不能取消或再次发码',pass_changed_reload:'二维码已更新，请刷新后再取消',invalid_pass_cancellation:'请填写至少两个字的取消原因',default_campaign_not_available:'默认活动需已开放并包含可用游戏',order_not_editable:'该订单已取消或退款，不能再次改单',invalid_revision_price:'单价需为0至5000，最多两位小数',issued_reward_already_redeemed:'关联奖励已经核销，不能撤销；可关闭撤销选项保留权益',issued_reward_locked:'关联奖励已锁在其他订单，请先释放后再撤销',issued_points_balance_insufficient:'会员积分余额不足，不能撤回；可保留权益并记录人工处理',invalid_adjustment_payment:'请填写有效金额、收退款方式及说明',adjustment_exceeds_balance:'金额超过当前待补收／退款余额，请刷新核对',order_payment_adjustment_pending:'本单还有补收／退款未完成，暂不能发 GamePass',pass_revoked:'这次游戏权益已由 Owner 撤销',aged_order_owner_required:'这张订单已超过72小时，需要 Owner 批准处理',aged_orders_block_day_close:'有超过72小时未完成的订单，Owner 处理后才能完成 Closing',invalid_cutoff:'请选择有效的截止时间',invalid_business_day:'营业日日期不正确',day_close_changed_reload:'收款或订单状态已变化，请刷新 Daily Statement 后再确认',business_day_already_closed:'本营业日已经完成 Closing',day_close_note_required:'有未完成款项时请填写 Closing 备注',cash_out_exceeds_expected:'现金记录不正确',invalid_day_close:'Daily Statement 内容无效，请刷新后重试',business_day_not_closed:'本营业日尚未完成 Closing',order_not_unpaid:'该订单已经处理，请刷新',invalid_reset_scope:'请先选择有效的清空范围，旧页面请刷新后再试',reset_scope_conflict:'本次确认的范围已经锁定，请取消后重新选择',active_order_bundle_exists:'这张订单已有整单 QR，请从原设备找回，或等待到期',no_eligible_bundle_units:'这张订单没有尚可分配的 Game Pass',bundle_request_conflict:'发码请求不一致，请刷新核对',reset_confirmation_expired:'本次重置确认已过期，请从第一次密码确认重新开始',reset_cleanup_pending:'上一次重置的账号清理尚未完成，请继续清理',reset_cleanup_failed:'旧账号或广告文件清理暂未完成，请稍后重试',invalid_reset_request:'重置确认无效，请重新开始',short_code_invalid_or_expired:'兑换码不正确或已过期，请顾客重新生成',short_code_rate_limited:'输入次数过多，请一分钟后再试，或扫描二维码',minimum_paid_drink_required:'最低消费必须包含至少一杯付费饮品',minimum_one_paid_drink:'使用奖励必须至少购买一杯优惠后仍需付费的饮品',minimum_purchase_not_met:'请保留至少一杯付费饮品，并满足奖励最低消费',cart_requires_paid_drink:'先选择至少一杯付费饮品，再使用奖励',ambassador_clear_cart_first:'请先清空普通购物车，再单独核销 Ambassador Pass',ambassador_pass_not_found:'找不到有效的 Ambassador Pass',ambassador_pass_not_valid_today:'此 Pass 只在预约营业日有效',cannot_redeem_own_pass:'不能核销自己签发的 Pass',ambassador_prices_not_configured:'Owner 尚未完成这天的 Freeflow 男女价格设置',invalid_guest_count:'请填写至少一位顾客',token_invalid_rescan_wallet:'兑奖码已失效，请让顾客在 Wallet 重新生成',reward_reserved_by_another_order:'这份奖励已锁定在另一张订单，请先取消原订单',draft_already_submitted:'这份购物车已提交，请到订单页面核对',paid_cart_item_already_discounted:'这杯已经使用其他优惠，请选择另一杯',paid_cart_item_missing:'原优惠饮品已不在购物车，请移除奖励后重新选择',cart_price_changed_rescan:'商品价格已变化，请移除奖励并重新扫码',preorder_coupon_not_ready_or_expired:'奖励未选好或已过期，请移除后重新扫码',too_many_cart_rewards:'单笔最多使用二十份奖励',staff_only:'需要有效员工账号',cashier_only:'需要 Cashier 权限',not_authenticated:'登录已过期，请重新登录',
  order_not_pending:'订单不在待接受状态',order_not_accepted:'订单必须先由 Cashier 接受',order_not_served:'请先完成出品，之后才能收款',
  product_unavailable:'这款产品已停止销售，请重新选择',order_too_large:'单笔订单金额或数量过大',
  invalid_line:'订单产品无效',invalid_order:'订单资料不正确',invalid_channel:'下单渠道无效',invalid_checkout_mode:'付款安排不正确',invalid_filter:'订单筛选条件无效',
  order_not_found:'找不到这张订单',request_conflict:'重复请求出现冲突，请重新开单',invalid_payment_method:'请选择正确的收款方式',
  order_cannot_cancel:'这张订单不能直接取消，已出品／已付款订单必须走人工处理流程',
  invalid_credentials:'账号或密码错误',invalid_reward_name:'奖励名称需为2至120个字',reward_not_found:'找不到该奖励',owner_only:'只有 Owner 才能更改此设置',
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
  challenge_one_cup_only:'Challenge 固定只预出 1 杯',store_box_item_not_in_order:'Package 商品不在这张订单中，请刷新后重试',duplicate_store_box_item:'Package 预出选择重复，请刷新后重试',store_box_component_unavailable:'选择的 Package 杯数超过可用数量',store_box_quantity_unavailable:'Package 预出数量超过套餐杯数',invalid_store_box_selection:'Package 预出数量无效，请检查后重试',store_box_order_unavailable:'Package 订单状态已变化，请刷新后重试',
  reward_reserved_by_other_order:'此奖品正预留在另一张订单，请取消之前的预留或等待到期',
  moon_invalid_code:'Moon 旧码格式不正确',moon_reward_not_bound:'Moon 奖励尚未在 Owner 的现有兑奖规则中绑定',moon_code_not_found:'找不到该 Moon 兑换码，请 Owner 先手动登记',moon_already_redeemed:'这张 Moon 码已经使用过',moon_reserved_elsewhere:'这张 Moon 码已经锁定在其他订单，请先释放',moon_expired:'Moon 码已过期',moon_not_started:'还未到领取日期',moon_drink_required:'请填写要送出的实际饮品名称',moon_minimum_payable:'抵扣 RM5 后必须仍有付费饮品金额',moon_release_unavailable:'订单已经出品或收款，无法直接释放赠品',
  hold_expired_rescan:'预留已过期，请让顾客重新出示 Wallet QR 以续期',coupon_hold_not_ready_or_expired:'购物车仍有未选择商品或已过期的兑奖预留，请先处理',
  choose_reward_product:'请先选择奖品对应的赠饮',choose_discount_item:'请选择一项符合奖品条件的订单商品',
  reward_binding_changed_rescan:'Owner 已修改兑奖规则，请重新核对这张奖券',discount_amount_invalid:'优惠金额计算失败',
  pos_checkout_only:'领取奖励只能在 POS 购物车预留，最终结账时才会扣券',
  release_coupon_before_edit:'订单已预留奖励，修改产品前请先取消预留',
  release_coupon_before_cancel:'订单还有预留奖励，请先在购物车内取消预留',
  unit_already_reserved:'这杯饮品已被其他优惠占用',unit_not_available:'这杯商品已领取其他权益，无法再使用折扣',
  cannot_remove_prepared_reward_item:'赠饮已经出品，不能直接撤销预留；请先联系 Cashier 处理订单',
  coupon_no_longer_available:'奖品已失效，请让顾客再次核对',coupon_cart_item_missing:'赠饮／优惠商品已被修改，请检查订单',
  gamepass_mode_disabled:'Owner 已关闭 GamePass 发码',lucky_minimum_spend:'这张订单未达到 Lucky Box 最低有效消费',lucky_daily_budget_reached:'今日 Lucky Box 奖励预算已满，已发出的 QR 不受影响',gamepass_order_mode_mismatch:'这张订单已经绑定另一种游戏模式，不能更换玩法',lucky_box_already_opened:'顾客已打开礼物箱，无法重新生成这个 QR',lucky_requires_paid_pos:'Lucky Box 仅限有效 POS 付费订单',
  store_box_claim_already_active:'这个存酒箱已有领取码，请显示或先取消原码',store_box_already_claimed:'顾客已经领取这个存酒箱',store_box_product_not_configured:'Owner 尚未设置这个商品的存酒规则',store_box_after_payment_only:'订单完成出品并付款后才能生成存酒箱',store_box_request_already_active:'这个存酒箱已有叫酒请求',store_box_quantity_unavailable:'叫酒数量超过可用数量或单次上限',store_box_not_available:'这个存酒箱目前不能叫酒',cashier_or_owner_only:'只有 Cashier 或 Owner 可以暂停或恢复存酒箱'};
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const money=v=>'RM'+Number(v||0).toFixed(2);
const stamp=v=>v?new Intl.DateTimeFormat('zh-MY',{timeZone:'Asia/Kuala_Lumpur',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'}).format(new Date(v)):'—';
const unpack=r=>{if(r?.error){const e=Error(r.error.message||r.error.code||'server_unavailable');e.code=r.error.code;throw e;}return r.data};
const errorText=e=>{let s=String(e?.message||e||'server_unavailable');if(/yt pos payment entries method check/i.test(s))return '付款方式未被系统识别，这笔收款没有完成。请先刷新订单核对付款状态，再重试；不要连续重复收款。';return msgMap[s]||s.replaceAll('_',' ')};
const isOwner=()=>state.identity?.can_owner===true||state.identity?.role==='owner';
const isOwnerLimited=()=>state.identity?.can_owner_limited===true;
const isCashier=()=>state.identity?.can_cashier===true||isOwner();
const isStaff=()=>!!state.identity?.role&&state.identity.role!=='owner'&&state.identity.role!=='cashier';
function updateCreateHint(){const payNow=$('checkoutPayNow').checked;if(isCashier()&&$('cashierDirect').checked)$('createHint').textContent=payNow?'下单后立即打开收款；订单同时进入吧台 KDS。':'订单直接进入吧台 KDS，出品后进入挂单收款。';else $('createHint').textContent=payNow?'若 Owner 开启审核，Cashier 接单后打开收款；若关闭审核，下单后立即打开收款。':'订单按 Owner 的审核设置进入流程；未付款订单可在「待付款」中随时结账。';}
let consoleUI=null,storeBox=null,limitedReportView=null,orderApprovals=null,approvalCount=null;
const playUpgrade=createPlayWork({db,notice:(message,bad)=>showNotice(message,bad),isOwner,isCashier,isCashierAccount:()=>state.identity?.role==='cashier',qrLibrary:()=>qrLibrary(),getOrders:()=>[...state.active,...state.paid],refreshOrders:()=>refreshOrders(false),onMemberBound:()=>state.selectedOrderCart?refreshOrderCart():undefined});
globalThis.ytPlayWork=playUpgrade;
function showNotice(message,bad=false,persist=false){const n=$('notice'),label=$('noticeMessage');if(!n)return;if(label)label.textContent=message;else n.textContent=message;n.dataset.message=message;n.classList.remove('hidden');n.classList.toggle('error',bad);n.setAttribute('role',bad?'alert':'status');n.setAttribute('aria-live',bad?'assertive':'polite');clearTimeout(state.noticeTimer);if(!persist)state.noticeTimer=setTimeout(()=>n.classList.add('hidden'),bad?8000:6200);}
function busy(btn,fn){if(btn?.disabled)return Promise.resolve();if(btn)btn.disabled=true;return Promise.resolve().then(fn).catch(e=>{showNotice(errorText(e),true);throw e}).finally(()=>{if(btn)btn.disabled=false});}
async function getBearer(){const {data,error}=await db.auth.getSession();if(error||!data.session?.access_token)throw Error('not_authenticated');return data.session.access_token;}
async function work(action,data={},signed=false){const headers={'Content-Type':'application/json',apikey:conf.publishableKey};if(signed)headers.Authorization='Bearer '+await getBearer();const endpoint=action.startsWith('reset_')?(conf.url||'')+'/functions/v1/yt-owner-reset':workURL;const resp=await fetch(endpoint,{method:'POST',headers,cache:'no-store',body:JSON.stringify({action,...data})});const res=await resp.json().catch(()=>({ok:false,error:'server_unavailable'}));if(!resp.ok||!res.ok)throw Error(res.error||'server_unavailable');return res;}
function resetLogin(){clearInterval(state.benefitTimer);state.shownBenefit=null;state.benefitLoading=false;state.benefitListEpoch=(state.benefitListEpoch||0)+1;benefitEpoch++;state.editBusy=false;closeEditDialog();state.revisionRequests=[];state.editCart.clear();state.editPending=null;state.adjustmentPending=null;stopRedeemCamera();stopPolling();storeBox?.clear();limitedReportView?.clear();limitedReportView=null;state.cart.clear();state.ambassadorDraft=null;state.draftSummary=null;state.draftSelection=null;state.pendingSubmit=null;state.draftEpoch++;state.ownerDashboard=null;state.ownerDashboardDay=null;state.ownerDashboardLoading=false;state.storeBoxQueue=[];state.seenStoreBox=new Set();state.seenStoreBoxInitialized=false;state.seenKds=new Set();state.seenKdsInitialized=false;state.seenPending=new Set();state.seenInitialized=false;state.activeView='login';state.identity=null;customPricing?.refreshAccess();state.authUserId=null;consoleUI?.roleChanged();buildNav();$('revisionApprovalTab')?.classList.toggle('hidden',!isOwner());if(!isOwner()){approvalCount=null;$('revisionApprovalCount')?.classList.add('hidden');}$('accountMenu').classList.add('hidden');$('accountMenu').open=false;$('signinForm').classList.remove('hidden');$('firstPasswordForm').classList.add('hidden');$('signin').classList.remove('hidden');$('dashboard').classList.add('hidden');$('logout').classList.add('hidden');$('accountName').textContent='WORK ACCOUNT';}
async function login(e){e.preventDefault();await busy($('signinBtn'),async()=>{
 const username=$('username').value.trim().toLowerCase(),password=$('password').value;
 const result=await work('login',{username,password});
  const {error}=await db.auth.setSession({access_token:result.access_token,refresh_token:result.refresh_token});if(error)throw error;
 if(result.must_change_password){$('signinForm').classList.add('hidden');$('firstPasswordForm').classList.remove('hidden');$('firstOldPassword').value=password;return;}
 $('password').value='';await launch();
});}
async function launch(){if(!usable){showNotice('尚未配置 /play/config.js 的 Supabase 连接',true,true);return;}
 const identity=unpack(await db.rpc('yt_pos_identity'));if(!identity)throw Error('staff_only');try{const authSession=await db.auth.getSession?.();state.authUserId=authSession?.data?.session?.user?.id||null;}catch{state.authUserId=null;}
  state.identity={...identity,can_owner:identity.role==='owner'||identity.can_owner===true,can_cashier:identity.role==='owner'||identity.can_cashier===true,can_edit_orders:identity.role==='owner'||identity.can_edit_orders===true};customPricing.refreshAccess();state.activeView='dashboard';$('signin').classList.add('hidden');$('dashboard').classList.remove('hidden');$('logout').classList.remove('hidden');
 $('accountName').textContent=identity.username+' · '+(isOwner()?'OWNER':identity.can_owner_limited?'OWNER LIMITED':identity.role==='cashier'?'CASHIER':isCashier()?'STAFF + CASHIER':'STAFF');$('permissionPill').textContent=isOwner()?'OWNER':identity.can_owner_limited?'OWNER LIMITED':identity.role==='cashier'?'CASHIER':isCashier()?'STAFF + CASHIER':'STAFF';
 $('workspaceSubtitle').textContent=identity.can_owner_limited?'报表 · Ambassador Pass':isOwner()?'经营总览 · 现场订单 · 店铺设置':isCashier()?'待审核 · 收款结账 · Game Pass':'快速点单 · 出品跟进 · Game Pass';
 $('cashierCreateChoice').classList.toggle('hidden',!isCashier());$('cashierDirect').checked=isCashier();$('checkoutPayNow').checked=true;$('checkoutPayLater').checked=false;
 $('createHint').textContent=isCashier()?'订单会保存在订单页；出品、收款都可稍后处理。':'Staff 点单后等待 Cashier 接受；订单会保存在订单页。';
 $('accountMenu').classList.remove('hidden');
 playUpgrade.mount();buildNav();consoleUI?.roleChanged();if(typeof createAmbassadorTools==='function'){globalThis.ytAmbassadorTools?.destroy();globalThis.ytAmbassadorTools=createAmbassadorTools({db,isOwner,isCashier,role:()=>state.identity?.role,notice:(message,bad)=>showNotice(message,bad),onRedeemPass:token=>scanAmbassadorPass(token),onClosePage:()=>showTab(defaultTab()),onAccessChange:enabled=>{state.ambassadorAccess=enabled;if(state.identity){buildNav();if(!enabled&&state.currentTab==='ambassador')showTab(defaultTab());}}});}
 if(typeof isOwnerLimited==='function'&&isOwnerLimited()){ensureLimitedHome();showTab('limited');await loadLimitedReports();return;}
 restoreDraft();try{const mode=await db.rpc('yt_lucky_public_mode');if(mode.error)throw mode.error;state.luckyMode=unpack(mode);}catch{state.luckyMode={mode:'game'};}state.luckyModeLoadedAt=Date.now();buildNav();const context=unpack(await db.rpc('yt_business_context'));state.businessDay=context.day;$('paidDate').value=context.day;if($('kdsHistoryDate'))$('kdsHistoryDate').value=context.day;await Promise.all([loadCatalog(),refreshOrders(false)]);showTab(new URL(location.href).searchParams.get('tab')||defaultTab());startPolling();
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

const defaultTab=()=>limitedRole()?'limited':isOwner()?'admin':state.identity?.role==='cashier'?'pending':'create';
const limitedRole=()=>typeof isOwnerLimited==='function'&&isOwnerLimited();
function ensureLimitedHome(){let section=$('tab-limited');if(!section){document.querySelector('main')?.insertAdjacentHTML('beforeend','<section id="tab-limited" class="tab-view hidden"><div id="limitedReportsRoot"></div></section>');section=$('tab-limited');}else if(!$('limitedReportsRoot'))section.innerHTML='<div id="limitedReportsRoot"></div>';}
async function loadLimitedReports(){const root=$('limitedReportsRoot');if(!root||!isOwnerLimited())return;const module=await import('./owner-reports.js?v=20261014-limited-report-full-v1');limitedReportView||=module.createOwnerReports({db,root,isOwner:isOwnerLimited,allowExport:false,notice:(message,bad)=>showNotice(message,bad),businessDay:state.businessDay});await limitedReportView.load();}
function buildNav(){const nav=$('nav');$('tab-benefits')?.classList.toggle('benefits-off',state.luckyMode?.mode==='off');$('revisionApprovalTab')?.classList.toggle('hidden',!isOwner());$('ownerApprovalShortcut')?.classList.toggle('hidden',!isOwner());const tabs=limitedRole()
  ?[['limited','报表'],['ambassador','发 Pass']]
  :isOwner()
  ?[['admin','管理'],['create','点单'],['orders','订单'],['benefits','Game Pass'],['storebox','存酒箱']]
  :isCashier()?[['orders','订单'],['create','点单'],['benefits','Game Pass'],['storebox','存酒箱']]
  :[['create','点单'],['orders','订单'],['benefits','Game Pass'],['storebox','存酒箱']];
 if(state.luckyMode?.mode==='off'){const index=tabs.findIndex(([key])=>key==='benefits');if(index>=0)tabs.splice(index,1);}
 if(isCashier()||isOwner())tabs.push(['bell','服务铃']);
 if(state.ambassadorAccess&&!limitedRole())tabs.push(['ambassador','发 Pass']);
 $('orderPendingTab').classList.toggle('hidden',!isCashier());
 nav.replaceChildren();for(const [key,label] of tabs){const b=document.createElement('button');b.type='button';b.dataset.tab=key;b.textContent=label;b.onclick=()=>showTab(key);nav.append(b);}updateAlertDots();}
const isAmbassadorOrder=row=>(row?.items||[]).some(item=>item.name==='Freeflow Male'||item.name==='Freeflow Female');
function productionItems(row){return (row?.items||[]).flatMap(item=>{
 if(item.store_box_item){const prep=row.package_preps?.find(entry=>entry.item_id===item.id),selections=prep?.selections||[],quantity=selections.reduce((sum,entry)=>sum+Math.max(0,Number(entry.quantity)||0),0);if(!quantity)return[];const breakdown=selections.filter(entry=>Number(entry.quantity)>0).map(entry=>`${entry.name||((entry.key==='default')?item.name:entry.key)} ×${Number(entry.quantity)}`).join(' · ');return[{...item,quantity,name:breakdown?`${item.name} · ${breakdown}`:item.name}];}
 return Number(item.quantity)>0?[item]:[];
});}
function productionRows(){return (state.active||[]).filter(row=>row.status==='confirmed'&&!isAmbassadorOrder(row)&&productionItems(row).some(item=>!item.fulfilled));}
function unpaidRows(){return (state.active||[]).filter(row=>row.payment_status==='unpaid'&&(row.status==='fulfilled'||row.status==='confirmed'));}
function updateAlertDots(){const pending=isCashier()&&Number(state.pending?.length)>0,kds=productionRows().length+Number(state.storeBoxQueue?.length),unpaid=unpaidRows().length;const orders=[...($('nav')?.querySelectorAll?.('button')||[])].find(button=>button.dataset.tab==='orders'),pendingTab=$('orderPendingTab'),activeTab=[...($('orderTabs')?.querySelectorAll?.('button')||[])].find(button=>button.dataset.goTab==='orders'),unpaidTab=$('orderUnpaidTab');orders?.classList.toggle('has-alert',pending||kds||unpaid);pendingTab?.classList.toggle('has-alert',pending);activeTab?.classList.toggle('has-alert',kds>0);unpaidTab?.classList.toggle('has-alert',unpaid>0);}
function renderKdsEmpty(){const count=productionRows().length+Number(state.storeBoxQueue?.length);$('kdsCount').textContent=String(count);$('kdsEmpty').classList.toggle('hidden',count>0);}
function updateStoreBoxQueue(rows){const list=rows||[],ids=new Set(list.map(row=>row.request_id));if(state.seenStoreBoxInitialized){const added=list.filter(row=>!state.seenStoreBox.has(row.request_id));const audibleCalls=added.filter(row=>row.request_source!=='cashier_checkout');if(audibleCalls.length){showNotice(`🔔 收到 ${audibleCalls.length} 个存酒箱叫酒请求`,false,true);announceNewOrder();}}state.storeBoxQueue=list;state.seenStoreBox=ids;state.seenStoreBoxInitialized=true;renderKdsEmpty();updateAlertDots();}
function showTab(tab,orderId=null){
 if(limitedRole()&&!['limited','insights','ambassador'].includes(tab))tab='limited';
 if(tab==='insights'&&limitedRole())tab='limited';
 if(tab==='more')tab=isOwner()?'admin':'benefits';
 if(tab==='redeem')tab='create';

 if(!['create','pending','orders','unpaid','history','approvals','benefits','storebox','ambassador','bell','redeem','reset','admin','limited'].includes(tab)||(tab==='pending'&&!isCashier())||(tab==='approvals'&&!isOwner())||(tab==='admin'&&!isOwner())||(tab==='limited'&&!limitedRole())||(tab==='ambassador'&&!state.ambassadorAccess&&!limitedRole()))tab=defaultTab();
 $('accountMenu').open=false;
 if(tab==='reset'&&consoleUI){consoleUI.open('pin');return;}
 if(tab!=='create'){closeCartDrawer();stopRedeemCamera();}if(tab!=='redeem')globalThis.ytAmbassadorTools?.pause?.();state.currentTab=tab;
 for(const section of ['create','pending','orders','unpaid','history','approvals','benefits','storebox','ambassador','bell','redeem','reset','admin','limited'])$('tab-'+section)?.classList.toggle('hidden',section!==tab);
 const orderView=['pending','orders','unpaid','history','approvals'].includes(tab);$('orderTabs').classList.toggle('hidden',!orderView);
 for(const b of $('orderTabs').querySelectorAll('button'))b.classList.toggle('active',b.dataset.goTab===tab);
 for(const b of $('nav').querySelectorAll('button'))b.classList.toggle('active',b.dataset.tab===tab||(orderView&&b.dataset.tab==='orders'));
 if(tab==='admin'&&!consoleUI)loadAdmin().then(loadOwnerRewardOffers).catch(e=>showNotice(errorText(e),true));
 if(tab==='admin')loadOwnerDashboard().catch(e=>showNotice(errorText(e),true));
 if(tab==='admin')playUpgrade.mapRefresh();
 if(tab==='benefits')loadBenefits(orderId).catch(e=>showNotice(errorText(e),true));
 if(tab==='storebox')storeBox?.loadStaff().catch(e=>showNotice(errorText(e),true));
 if(tab==='ambassador')globalThis.ytAmbassadorTools?.open().catch(e=>showNotice(errorText(e),true));
 if(tab==='bell')playUpgrade.poll();
 if(tab==='pending'||tab==='orders'||tab==='unpaid'||tab==='history'||tab==='approvals')refreshOrders(false).catch(e=>showNotice(errorText(e),true));
 if(tab==='approvals')loadOwnerApprovals().catch(e=>showNotice(errorText(e),true));
}
const compactNumber=v=>Number(v||0).toLocaleString('en-MY');
function renderOwnerDashboard(data){
 const root=$('ownerDashboardStats'),alerts=$('ownerDashboardAlerts'),status=$('ownerDashboardStatus');if(!root||!alerts||!status)return;
 const s=data?.stats||{},m=data?.member_stats||{},l=data?.live||{};
 const metrics=[['今日实收',money(s.today_amount),compactNumber(s.today_orders)+' 张收款单','money'],['本月实收',money(s.month_amount),compactNumber(s.month_orders)+' 张收款单','money'],['会员',compactNumber(m.total),`本月新增 ${compactNumber(m.month_new)}`,''],['现场待处理',compactNumber(Number(l.pending_orders||0)+Number(l.preparing_orders||0)+Number(l.unpaid_orders||0)),`审核 ${compactNumber(l.pending_orders)} · 出品 ${compactNumber(l.preparing_orders)} · 收款 ${compactNumber(l.unpaid_orders)}`,'']];
 root.innerHTML=metrics.map(([label,value,note,tone])=>`<article class="owner-overview-card ${tone}"><span>${label}</span><strong>${value}</strong><small>${note}</small></article>`).join('');
 const warnings=[];if(Number(l.unbound_rewards))warnings.push(`${compactNumber(l.unbound_rewards)} 种奖励尚未绑定权益`);if(Number(l.low_stock_pool_entries))warnings.push(`${compactNumber(l.low_stock_pool_entries)} 项奖池库存偏低`);if(Number(l.expiring_rewards))warnings.push(`${compactNumber(l.expiring_rewards)} 份奖励将在 7 天内到期`);if(Number(l.unclaimed_passes))warnings.push(`${compactNumber(l.unclaimed_passes)} 份 Game Pass 尚未领取`);
 alerts.innerHTML=warnings.length?`<strong>需要留意</strong>${warnings.map(x=>`<span>${x}</span>`).join('')}`:'<span>目前没有需要立即处理的经营提醒。</span>';
 alerts.classList.toggle('has-alerts',warnings.length>0);status.textContent=`营业日 ${data.business_day||state.businessDay||'—'} · 刚刚更新`;
}
async function loadOwnerDashboard(force=false){
 if(!isOwner()||!$('ownerDashboardStats'))return;if(state.ownerDashboardLoading)return;
 const day=state.businessDay;if(!day)return;if(!force&&state.ownerDashboard&&state.ownerDashboardDay===day){renderOwnerDashboard(state.ownerDashboard);return;}
 state.ownerDashboardLoading=true;$('ownerDashboardStatus').textContent='正在读取经营数据…';$('ownerDashboardStats').innerHTML='<div class="owner-overview-loading">正在整理今日经营情况…</div>';
 try{const response=unpack(await db.rpc('yt_owner_report_v8',{p_start:day,p_end:day,p_member_page:1,p_search:''}));state.ownerDashboard=response;state.ownerDashboardDay=day;renderOwnerDashboard(response);}
 catch(e){$('ownerDashboardStats').innerHTML='<div class="owner-overview-loading error">经营数据暂时无法读取，请点击刷新。</div>';$('ownerDashboardStatus').textContent='读取失败';throw e;}
 finally{state.ownerDashboardLoading=false;}
}
async function loadCatalog(){const [products,series]=await Promise.all([db.rpc('yt_pos_catalog'),db.rpc('yt_pos_series_catalog')]);state.catalog=unpack(products)||[];state.series=unpack(series)||[];
 const category=$('categoryProduct');const chosen=category.value;category.replaceChildren(new Option('全部类别',''));
 const cats=[...new Set(state.catalog.filter(x=>x.active).map(x=>x.category))].sort();for(const c of cats)category.add(new Option(c,c));category.value=cats.includes(chosen)?chosen:'';renderCategoryButtons();
  const sel=$('productSeries');const value=sel.value;sel.replaceChildren(new Option('未配置系列（不发权益）',''));for(const row of state.series)sel.add(new Option(row.name+' · '+row.benefit_mode,row.id));sel.value=state.series.some(x=>x.id===value)?value:'';
  renderCatalog();renderCart();if(isOwner()){renderProductAdmin();renderSeriesAdmin();}}
function renderCategoryButtons(){const root=$('categoryProductButtons');if(!root)return;
 root.replaceChildren(...[...$('categoryProduct').options].map(option=>{const b=document.createElement('button');b.type='button';b.className='category-pill'+(option.value===$('categoryProduct').value?' active':'');b.dataset.category=option.value;b.textContent=option.textContent;b.setAttribute('aria-pressed',String(option.value===$('categoryProduct').value));return b;}));
}
function renderCatalog(){renderCategoryButtons();const root=$('catalog'),search=$('searchProduct').value.trim().toLowerCase(),category=$('categoryProduct').value;
 const list=state.catalog.filter(p=>p.active&&(!category||p.category===category)&&(!search||(`${p.name} ${p.category}`).toLowerCase().includes(search)));
 root.innerHTML=list.length?list.map(p=>`<button class="product" data-add="${esc(p.id)}" type="button"><strong>${esc(p.name)}</strong><small>${esc(p.category)}</small><b>${money(p.price_rm)}</b><em>+ 加入</em></button>`).join(''):'<div class="empty">没有符合条件的产品。Owner 可以先到「Owner 设置」创建菜单。</div>';}

const draftItems=()=>[...state.cart].map(([product_id,quantity])=>({product_id,quantity}));
const draftKey=()=>`yt-pos-v5-draft:${portal}:${state.identity?.username||''}`;
function restoreDraft(){
 state.cart.clear();state.draftId=crypto.randomUUID();state.draftSummary=null;state.draftSelection=null;state.pendingSubmit=null;state.currentRequestId=null;
 try{const oldKey=`yt-pos-v5-draft:cashier:${state.identity?.username||''}`;if(state.identity?.role==='cashier'&&!sessionStorage.getItem(draftKey())&&sessionStorage.getItem(oldKey)){sessionStorage.setItem(draftKey(),sessionStorage.getItem(oldKey));sessionStorage.removeItem(oldKey);}const d=JSON.parse(sessionStorage.getItem(draftKey())||'null');if(d?.draftId){state.draftId=d.draftId;state.cart=new Map(d.items||[]);state.ambassadorDraft=d.ambassador||null;state.draftSelection=d.selection||null;state.pendingSubmit=d.pending||null;$('tableInput').value=d.table||'';$('orderNote').value=d.note||'';const mode=state.pendingSubmit?.p_checkout_mode||'pay_now';$('checkoutPayNow').checked=mode==='pay_now';$('checkoutPayLater').checked=mode!=='pay_now';if(state.pendingSubmit)$('cashierDirect').checked=state.pendingSubmit.p_channel==='cashier';}}catch{}
}
function saveDraft(){if(!state.identity)return;try{sessionStorage.setItem(draftKey(),JSON.stringify({draftId:state.draftId,items:[...state.cart],ambassador:state.ambassadorDraft,selection:state.draftSelection,pending:state.pendingSubmit,table:$('tableInput').value,note:$('orderNote').value,checkoutMode:$('checkoutPayNow').checked?'pay_now':'pay_later'}));}catch{}}
function updateDraftControls(){
 const locked=state.draftSaving||!!state.pendingSubmit,mutating=state.draftMutating;
 $('createOrderBtn').textContent=state.draftSaving?'正在提交…':state.pendingSubmit?'重试确认原订单 →':'提交订单 →';
 $('createOrderBtn').disabled=state.draftSaving||mutating||(!state.pendingSubmit&&(state.draftLoading||(!state.cart.size&&!state.ambassadorDraft)||!state.draftSummary?.can_submit));
 for(const id of ['tableInput','orderNote','cashierDirect','checkoutPayNow','checkoutPayLater'])$(id).disabled=locked;
 const noScan=locked||mutating||state.draftLoading||state.draftSummary?.holds?.some(h=>h.state==='pending');
 $('draftRedeemCheck').disabled=!!noScan;$('draftRedeemScan').disabled=locked||mutating;$('draftRedeemToken').disabled=locked||mutating;
 for(const b of $('draftRewardRows').querySelectorAll('button'))b.disabled=locked||mutating;
 for(const b of $('draftRewardChoices').querySelectorAll('button'))b.disabled=locked||mutating;
 if(state.pendingSubmit&&!state.draftSaving)$('draftStatus').textContent='提交状态待确认。点击重试会核对原订单，不会重复开单。';
}
function renderCart(){let count=0,total=0;const rows=[];
 if(state.ambassadorDraft){
  const d=state.ambassadorDraft;
  for(const [kind,label,qty,price] of [['male','Freeflow Male',Number(d.male||0),Number(d.male_price||0)],['female','Freeflow Female',Number(d.female||0),Number(d.female_price||0)]]){
   if(!qty)continue;count+=qty;total+=qty*price;
   rows.push(`<div class="cart-row"><div><strong>${label}</strong><small>${money(price)} × ${qty}</small></div><div class="cart-tools"><button type="button" data-amb-dec="${kind}" aria-label="减少">−</button><b>${qty}</b><button type="button" data-amb-inc="${kind}" aria-label="增加">+</button></div></div>`);
  }
  if(count)rows.unshift(`<div class="redeem-banner"><strong>Ambassador Pass · ${esc(d.reservation_day||'')}</strong><p>${esc(d.ambassador_name||'Ambassador')} · ${count} 位 · 收款后计入日结${Number(d.commission_rate||0)>0?'及 Ambassador 佣金':' · 此 Pass 佣金 RM0.00'}</p><button class="quiet" type="button" data-amb-remove>移除 Pass</button></div>`);
 }else{
  for(const [id,qty] of state.cart){const p=state.catalog.find(x=>x.id===id&&x.active);if(!p){if(!state.pendingSubmit)state.cart.delete(id);continue;}count+=qty;total+=qty*Number(p.price_rm);
   rows.push(`<div class="cart-row"><div><strong>${esc(p.name)}</strong><small>${money(p.price_rm)} × ${qty}</small></div><div class="cart-tools"><button type="button" data-dec="${esc(id)}" aria-label="减少">−</button><b>${qty}</b><button type="button" data-inc="${esc(id)}" aria-label="增加">+</button></div></div>`);
  }
 }
 $('cartRows').innerHTML=rows.length?rows.join(''):'<div class="empty">请先选择产品或扫描 Ambassador Pass。</div>';
 $('cartCount').textContent=count+' 件';$('cartDockCount').textContent=count+' 件';$('cartDock').classList.toggle('has-items',count>0);
 $('draftGross').textContent=money(total);$('draftDiscount').textContent='−RM0.00';$('cartTotal').textContent=money(total);$('cartDockTotal').textContent=money(total);
 saveDraft();refreshDraftSummary().catch(e=>{$('draftStatus').textContent=errorText(e)+'，请点击重新核对。';});
}
async function refreshDraftSummary(){const epoch=++state.draftEpoch;
 if(state.pendingSubmit){state.draftLoading=false;updateDraftControls();return state.draftSummary;}
 if(state.ambassadorDraft){const d=state.ambassadorDraft,gross=Number(d.male||0)*Number(d.male_price||0)+Number(d.female||0)*Number(d.female_price||0);state.draftSummary={gross_rm:gross,reserved_discount_rm:0,payable_rm:gross,unresolved_count:0,holds:[],can_submit:gross>0};state.draftLoading=false;$('draftRewardRows').replaceChildren();$('draftRewardChoices').replaceChildren();$('draftGross').textContent=money(gross);$('draftDiscount').textContent='−RM0.00';$('cartTotal').textContent=money(gross);$('cartDockTotal').textContent=money(gross);$('draftStatus').textContent=gross>0?'Freeflow Pass 已加入购物车，可照常结账。':'请至少保留一位顾客。';saveDraft();updateDraftControls();return state.draftSummary;}
 if(!state.cart.size){state.draftSummary=null;state.draftLoading=false;$('draftRewardRows').replaceChildren();$('draftRewardChoices').replaceChildren();$('draftStatus').textContent='先选择至少一杯付费饮品，再使用奖励。';updateDraftControls();return null;}
 state.draftLoading=true;updateDraftControls();$('draftStatus').textContent='正在核对购物车…';
 try{
  const q=unpack(await db.rpc('yt_moon_preorder_summary',{p_draft:state.draftId,p_cart:draftItems()}));if(epoch!==state.draftEpoch)return null;
  state.draftSummary=q;
  $('draftRewardRows').innerHTML=(q.holds||[]).map(h=>`<div class="draft-reward-row"><div><strong>${esc(h.reward_name)}</strong><small>${h.valid?'已选好 · 下单后锁码':h.state==='pending'?'请选择适用饮品':'选择已失效，请移除后重新扫码'}${h.chosen_product_name?' · '+esc(h.chosen_product_name)+(h.discount_type==='free'?'（赠饮）':''):''}</small></div><b>−${money(h.discount_rm)}</b><button type="button" class="quiet" data-release-draft="${esc(h.id)}">移除</button></div>`).join('');
  $('draftGross').textContent=money(q.gross_rm);$('draftDiscount').textContent='−'+money(q.reserved_discount_rm);$('cartTotal').textContent=money(q.payable_rm);$('cartDockTotal').textContent=money(q.payable_rm);
  $('draftStatus').textContent=q.unresolved_count?'请先处理奖励。':!q.can_submit?'需保留一杯付费饮品并满足消费门槛。':q.holds?.length?'奖励已加入。':'可以提交。';
  if(state.draftSelection?.source!=='moon'&&state.draftSelection&&q.holds?.some(h=>h.id===state.draftSelection.id&&h.state==='pending'))renderDraftChoices(state.draftSelection);
  saveDraft();return q;
 }catch(e){if(epoch===state.draftEpoch)state.draftSummary=null;throw e;}
 finally{if(epoch===state.draftEpoch){state.draftLoading=false;updateDraftControls();}}
}
async function draftOperation(fn){if(state.draftSaving||state.pendingSubmit||state.draftMutating)return;state.draftMutating=true;updateDraftControls();try{await fn();}catch(e){showNotice(errorText(e),true);throw e;}finally{state.draftMutating=false;updateDraftControls();}}
function extractMoonCode(raw){
 const text=String(raw||'').trim().toUpperCase();
 const full=text.match(/YT[\s-]*MOON[\s-]*([A-Z0-9]{8})/);
 if(full)return full[1];
 const compact=text.replace(/[\s-]/g,'');if(/^[A-Z0-9]{8}$/.test(compact))return compact;
 return null;
}
function isAmbassadorToken(raw){const text=String(raw||'').trim();if(/^YTAMB\s*:/i.test(text)||/^ambassador:/i.test(text))return true;try{return new URL(text).searchParams.has('amb');}catch{return false;}}
async function scanAmbassadorPass(raw){
 if(state.cart.size||state.ambassadorDraft)throw Error('ambassador_clear_cart_first');
 const p=unpack(await db.rpc('yt_ambassador_pos_pass_lookup',{p_token:raw}));
 const root=$('draftRewardChoices');state.draftSelection=null;root.innerHTML=`<article class="redeem-banner"><strong>Freeflow · ${esc(p.ambassador_name||'Ambassador')}</strong><p>${esc(p.reservation_day)} · 已核销 ${Number(p.checked_pax||0)} 位 / 预登记 ${Number(p.planned_pax||0)} 位</p>${Number(p.checked_pax||0)>Number(p.planned_pax||0)?'<p>已超过预登记人数；仍可继续核销，请确认实际人数。</p>':''}${p.guest_name?`<small>${esc(p.guest_name)}${p.guest_phone?' · '+esc(p.guest_phone):''}</small>`:''}<div class="cart-redeem-choices"><label>男士 ${money(p.male_price)}<input id="ambassadorMaleCount" type="number" min="0" max="500" step="1" value="0" aria-label="Freeflow 男士人数"></label><label>女士 ${money(p.female_price)}<input id="ambassadorFemaleCount" type="number" min="0" max="500" step="1" value="0" aria-label="Freeflow 女士人数"></label></div><p id="ambassadorPassQuote">合计 RM0.00</p><p id="ambassadorPassWarning" role="status"></p><button class="primary" id="ambassadorPassCreate" type="button">加入购物车</button></article>`;
 const total=()=>Number($('ambassadorMaleCount').value||0)*Number(p.male_price||0)+Number($('ambassadorFemaleCount').value||0)*Number(p.female_price||0);
 const update=()=>{$('ambassadorPassQuote').textContent='合计 '+money(total());};
 const planned=Number(p.planned_pax||0),checked=Number(p.checked_pax||0),warn=()=>{
  const next=Number($('ambassadorMaleCount').value||0)+Number($('ambassadorFemaleCount').value||0),host=$('ambassadorPassWarning');
  if(host)host.textContent=checked+next>planned?`提醒：本次后累计 ${checked+next} 位，超过预登记 ${planned} 位；仍可继续核销。`:'';
 };
 $('ambassadorMaleCount').oninput=()=>{update();warn();};$('ambassadorFemaleCount').oninput=()=>{update();warn();};
 $('ambassadorPassCreate').onclick=()=>busy($('ambassadorPassCreate'),async()=>{
  const m=Number($('ambassadorMaleCount').value||0),f=Number($('ambassadorFemaleCount').value||0);if(!Number.isInteger(m)||!Number.isInteger(f)||m<0||f<0||m+f<1||m+f>500)throw Error('invalid_guest_count');
  state.ambassadorDraft={token:raw,pass_id:p.pass_id,pass_code:p.pass_code,reservation_day:p.reservation_day,ambassador_name:p.ambassador_name,commission_rate:Number(p.commission_rate||0),male:m,female:f,male_price:Number(p.male_price),female_price:Number(p.female_price),planned_pax:planned,checked_pax:checked,guest_name:p.guest_name,guest_phone:p.guest_phone};
  state.draftSelection=null;$('draftRedeemToken').value='';root.replaceChildren();saveDraft();renderCart();openCartDrawer();showNotice('Freeflow 已加入购物车；请使用下方正常结账按钮。');
 }).catch(()=>{});
}
async function scanDraftReward(){return draftOperation(async()=>{
 const raw=$('draftRedeemToken').value.trim();const custom=await customPricing?.scan(raw);if(custom){if(custom.cancelled){$('draftRedeemToken').value='';return;}if(!state.catalog.some(x=>x.id===custom.id))state.catalog.push({...custom,active:true,category:'CUSTOM',is_drink:true});state.cart.set(custom.id,(state.cart.get(custom.id)||0)+1);$('draftRedeemToken').value='';saveDraft();await refreshDraftSummary();showNotice('订制饮品已通过 Redeem 加入购物车');return;}if(isAmbassadorToken(raw)){await scanAmbassadorPass(raw);return;}
 if(!state.cart.size)throw Error('cart_requires_paid_drink');
 const moonCode=extractMoonCode(raw);
 let h=null;
 if(moonCode)h=unpack(await db.rpc('yt_pos_preorder_scan_auto',{p_draft:state.draftId,p_code:moonCode,p_request:crypto.randomUUID(),p_cart:draftItems()}));
 else{
  const short=raw.replace(/[\s-]/g,'').toUpperCase(),manual=/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$/.test(short);
  const args={p_draft:state.draftId,p_request:crypto.randomUUID(),p_cart:draftItems(),...(manual?{p_code:short}:{p_token:parseRedeemToken(raw)})};
  h=unpack(await db.rpc(manual?'yt_pos_preorder_scan_code':'yt_pos_preorder_scan',args));
 }
 if(h?.error_code)throw Error(h.error_code);
 if(h?.source==='moon'&&h?.requires_product){state.draftSelection=h;renderDraftChoices(h);return;}
 if(h?.source==='moon'){ $('draftRedeemToken').value='';state.draftSelection=null;saveDraft();await refreshDraftSummary();$('draftRewardChoices').replaceChildren();showNotice(h.kind==='R0'?'Moon 抵扣已预留，结账才核销':'Moon 奖励已预留，结账才核销');return; }
 $('draftRedeemToken').value='';state.draftSelection=h;saveDraft();await refreshDraftSummary();renderDraftChoices(h);
});}
function renderDraftChoices(h){const root=$('draftRewardChoices');root.replaceChildren();
 if(h.source==='moon'&&h.requires_product){
  root.innerHTML='<p class="field-note">'+esc(h.reward_name)+' · 请选择已绑定商品</p>';
  for(const product of h.products||[]){
   const b=document.createElement('button');b.type='button';b.className='reward-choice';
   b.textContent='＋ '+product.name+' · '+money(product.price_rm)+' → Moon 赠饮';
   b.onclick=()=>draftOperation(async()=>{
    const info=unpack(await db.rpc('yt_pos_preorder_scan_auto',{p_draft:state.draftId,p_code:h.code,p_request:crypto.randomUUID(),p_cart:draftItems(),p_product:product.product_id}));
    if(info?.error_code)throw Error(info.error_code);
    $('draftRedeemToken').value='';state.draftSelection=null;root.replaceChildren();saveDraft();await refreshDraftSummary();showNotice('Moon 奖励已按绑定商品预留，结账才核销');
   }).catch(()=>{});
   root.append(b);
  }
  if(!(h.products||[]).length)root.insertAdjacentHTML('beforeend','<p class="field-note">此 Moon 奖励尚未在 Owner 的现有兑奖规则中绑定商品或系列。</p>');
  return;
 }
 if(h.state==='chosen'){root.innerHTML='<p class="field-note">这份奖励已经选好，请在上方核对。</p>';return;}
 root.innerHTML=`<p class="field-note">${esc(h.reward_name)} · ${h.discount_type==='free'?'选择一杯赠饮':'选择要抵扣的一杯'}</p>`;
 const used=state.draftSummary?.holds||[];let choices=0;
 for(const p of h.products||[]){const qty=h.discount_type==='free'?1:(state.cart.get(p.product_id)||0);for(let n=1;n<=qty;n++){
  if(h.discount_type!=='free'&&used.some(x=>x.state==='chosen'&&x.discount_type!=='free'&&x.chosen_product_id===p.product_id&&x.chosen_unit===n))continue;
  const b=document.createElement('button');b.type='button';b.className='reward-choice';const cut=h.discount_type==='free'?Number(p.price_rm):h.discount_type==='fixed'?Math.min(Number(p.price_rm),Number(h.discount_value)):Math.round(Number(p.price_rm)*Number(h.discount_value))/100;
  b.textContent=`${p.name}${h.discount_type==='free'?' · 赠饮':' · 第 '+n+' 杯'} → −${money(cut)}`;
  b.onclick=()=>draftOperation(async()=>{unpack(await db.rpc('yt_pos_preorder_choose',{p_hold:h.id,p_product:p.product_id,p_unit:h.discount_type==='free'?null:n,p_cart:draftItems()}));state.draftSelection=null;root.replaceChildren();saveDraft();await refreshDraftSummary();showNotice('奖励已加入点单购物车，下单后锁码');}).catch(()=>{});root.append(b);choices++;
 }}
 if(!choices)root.insertAdjacentHTML('beforeend','<p class="field-note">购物车没有可用的饮品，请先移除奖励、调整商品，再重新扫码。</p>');
}
async function releaseDraftReward(id){return draftOperation(async()=>{const hold=state.draftSummary?.holds?.find(x=>x.id===id);unpack(await db.rpc(hold?.source==='moon'?'yt_moon_preorder_release':'yt_pos_preorder_release',{p_hold:id}));if(state.draftSelection?.id===id)state.draftSelection=null;$('draftRewardChoices').replaceChildren();saveDraft();await refreshDraftSummary();showNotice('奖励已移除，顾客奖券仍可使用');});}
function openCartDrawer(){if(state.currentTab!=='create'||state.activeView!=='dashboard')return;document.body.classList.add('cart-open');$('cartDock').setAttribute('aria-expanded','true');$('cartCloseBtn').focus({preventScroll:true});refreshDraftSummary().catch(e=>showNotice(errorText(e),true));}
function closeCartDrawer(){stopRedeemCamera();document.body.classList.remove('cart-open');$('cartDock')?.setAttribute('aria-expanded','false');}
function adjustCart(id,delta){if(state.draftSaving||state.pendingSubmit||state.draftMutating)return;if(state.ambassadorDraft){showNotice('Ambassador Pass 只能单独结账，不能加入普通饮品。',true);return;}if(state.draftSummary?.holds?.length||state.draftSelection){showNotice('先移除购物车中的奖励，再修改饮品数量。',true);return;}const p=state.catalog.find(x=>x.id===id&&x.active);if(!p)return;const n=Math.max(0,Math.min(20,(state.cart.get(id)||0)+delta));if(n)state.cart.set(id,n);else state.cart.delete(id);renderCart();}
async function adjustAmbassadorCart(kind,delta){
 const d=state.ambassadorDraft;if(!d||state.draftSaving||state.pendingSubmit||state.draftMutating)return;
 const key=kind==='male'?'male':'female';d[key]=Math.max(0,Math.min(500,Number(d[key]||0)+delta));
 if(!d.male&&!d.female)state.ambassadorDraft=null;
 saveDraft();renderCart();
}
async function createOrder(){if(state.draftSaving||state.draftMutating)return;state.draftSaving=true;updateDraftControls();let data,ambassador=!!state.ambassadorDraft;
 try{
  if(!state.pendingSubmit){
   if(ambassador){
    const d=state.ambassadorDraft;if(!d||Number(d.male||0)+Number(d.female||0)<1)throw Error('invalid_guest_count');
    state.pendingSubmit={ambassador:true,p_request:crypto.randomUUID(),p_token:d.token,p_male:Number(d.male||0),p_female:Number(d.female||0),p_checkout_mode:$('checkoutPayNow').checked?'pay_now':'pay_later'};
   }else{
    if(!state.cart.size)throw Error('请先选择产品');const q=await refreshDraftSummary();if(!q?.can_submit)throw Error('minimum_purchase_not_met');
    state.pendingSubmit={p_request:crypto.randomUUID(),p_table:$('tableInput').value.trim()||null,p_note:$('orderNote').value.trim()||null,p_items:draftItems(),p_channel:isCashier()&&$('cashierDirect').checked?'cashier':'staff',p_draft:state.draftId,p_checkout_mode:$('checkoutPayNow').checked?'pay_now':'pay_later'};
   }
   saveDraft();updateDraftControls();
  }
  ambassador=state.pendingSubmit?.ambassador===true;
  if(ambassador){
   const result=unpack(await db.rpc('yt_ambassador_pos_order_create',{p_token:state.pendingSubmit.p_token,p_male:state.pendingSubmit.p_male,p_female:state.pendingSubmit.p_female,p_request:state.pendingSubmit.p_request}));
   data={...result,id:result.order_id,status:result.status||'fulfilled'};
  }else data=unpack(await db.rpc('yt_pos_create_order_with_rewards_v2',state.pendingSubmit));
 }catch(e){if(e.code&&(/^[0-9A-Z]{5}$/.test(e.code)||/^PGRST/.test(e.code))){state.pendingSubmit=null;saveDraft();}showNotice(errorText(e),true);$('draftStatus').textContent=state.pendingSubmit?'提交状态待确认，请重试确认原订单。':'提交未完成：'+errorText(e);}
 finally{state.draftSaving=false;updateDraftControls();}
 if(!data)return;
 const attached=Number(data.reward_cart?.attached||0),checkoutMode=state.pendingSubmit?.p_checkout_mode||'pay_now';state.pendingSubmit=null;state.cart.clear();state.ambassadorDraft=null;state.draftId=crypto.randomUUID();state.draftSummary=null;state.draftSelection=null;$('orderNote').value='';$('checkoutPayNow').checked=true;$('checkoutPayLater').checked=false;$('draftRewardChoices').replaceChildren();saveDraft();renderCart();closeCartDrawer();
 showNotice(ambassador?(checkoutMode==='pay_now'?`${data.order_no||''} Freeflow 已开单，正在打开付款窗口。`:`${data.order_no||''} Freeflow 已加入待收款订单；请照常结账。`):`${data.order_no} 已下单 · ${attached?'奖励已锁码，结账才核销':data.status==='confirmed'?'已进入吧台 KDS':'等待 Cashier 接受'}`);
 showTab('create');try{await refreshOrders(false);const orderId=data.id||data.order_id||[...state.active,...state.pending,...state.paid].find(row=>row.order_no===data.order_no)?.id;if(orderId&&(isCashier()||isOwner()))await promptCashierPackagePrep(orderId);if(checkoutMode==='pay_now'){if(orderId)await openOrderCart(orderId);else showNotice(`${data.order_no||'订单'} 已成功下单，但暂时找不到订单付款窗口，请刷新订单列表。`,true);}}catch(e){showNotice(`${data.order_no||'订单'} 已成功下单，订单列表暂未刷新，请点刷新。`,true);}
}
function revisionRequestFor(orderId){return state.revisionRequests.find(item=>item.order_id===orderId)||null;}
 function revisionRequestMarkup(row){const request=revisionRequestFor(row.id);if(!request)return'';const label=request.status==='pending'?'改单申请已送交 Owner，等待审批':request.status==='approved'?'Owner 已批准改单':'Owner 已拒绝改单';return `<small class="revision-request-status ${request.status}">${label}${request.review_note?` · ${esc(request.review_note)}`:''}${request.reviewed_at?` · ${stamp(request.reviewed_at)}`:''}</small>`;}
 function statusLabel(row){if(isAmbassadorOrder(row)&&row.payment_status==='unpaid')return 'Freeflow · 待收款';if(row.payment_status==='refunded')return '已退款取消';if(row.payment_status==='paid'&&Number(row.balance_rm)>0)return '待补收 '+money(row.balance_rm);if(row.payment_status==='paid'&&Number(row.balance_rm)<0)return '待退款 '+money(-row.balance_rm);if(row.payment_status==='paid'&&row.status==='confirmed')return '已付款 · 待出品';if(row.payment_status==='paid')return '已付款';if(row.status==='confirmed'&&row.store_box_only)return '待结账 · 结账后发码';return ({pending:'等待 Cashier 接受',confirmed:'已接受 · 待出品',fulfilled:'已出品 · 待结账',cancelled:'已拒绝／取消'}[row.status]||row.status);}
function escapeAttr(s){return esc(s)}
function checkoutLabel(row){return row.checkout_mode==='pay_now'?'直接付':'后付 / 挂单';}
function benefitSummaryMarkup(data){const rows=[`<div><small>活动模式</small><b>${esc(data.mode||'权益')}</b></div>`,`<div><small>会员</small><b>${esc(data.member_name||'未关联会员')}</b></div>`];if(Number(data.points_earned||0)>0||data.mode==='会员积分')rows.push(`<div><small>本单获得积分</small><b>+${Number(data.points_earned||0)}</b></div>`);if(data.points_balance!=null)rows.push(`<div><small>目前可用积分</small><b>${Number(data.points_balance||0)}</b></div>`);if(Number(data.lucky_points||0)>0)rows.push(`<div><small>Lucky Box 积分</small><b>${Number(data.lucky_claimed_points||0)} / ${Number(data.lucky_points||0)} 已领取</b></div>`);if(Number(data.gamepass_claimed_count||0)>0)rows.push(`<div><small>已领取 GamePass</small><b>${Number(data.gamepass_claimed_count)} 份</b></div>`);rows.push(`<div><small>操作端</small><b>${esc(data.operator_name||'历史记录未保存操作端')}${data.operator_role?` · ${esc(data.operator_role)}`:''}</b></div>`);return `<div class="benefit-summary-grid">${rows.join('')}</div>`;}
async function toggleOrderBenefitSummary(button){button.disabled=true;let overlay=document.getElementById('orderBenefitSummaryOverlay');if(!overlay){overlay=document.createElement('section');overlay.id='orderBenefitSummaryOverlay';overlay.className='edit-overlay benefit-summary-overlay hidden';overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');overlay.setAttribute('aria-labelledby','benefitSummaryTitle');overlay.innerHTML='<article class="card benefit-summary-dialog"><div class="receipt-dialog-head"><div><small>MEMBER BENEFITS</small><h2 id="benefitSummaryTitle">处理结果</h2></div><button type="button" class="quiet" data-benefit-summary-close>关闭</button></div><div class="benefit-summary-content" aria-live="polite">正在读取会员与积分结果…</div></article>';document.body.append(overlay);overlay.addEventListener('click',e=>{if(e.target===overlay||e.target.closest('[data-benefit-summary-close]'))overlay.classList.add('hidden');});overlay.addEventListener('keydown',e=>{if(e.key==='Escape')overlay.classList.add('hidden');});}overlay.classList.remove('hidden');overlay.querySelector('[data-benefit-summary-close]').focus();const content=overlay.querySelector('.benefit-summary-content');content.textContent='正在读取会员与积分结果…';try{const orderId=button.dataset.orderBenefitSummary,map=unpack(await db.rpc('yt_pos_order_benefit_summaries',{p_orders:[orderId]}))||{},result=map[orderId];if(!result){content.textContent='尚未找到这笔订单的权益记录。';return;}const row=state.paid.find(item=>item.id===orderId);if(row)row.benefit_summary=result;content.innerHTML=benefitSummaryMarkup(result);}catch(error){content.textContent=errorText(error);showNotice(errorText(error),true);}finally{button.disabled=false;}}
function elapsed(v){const minutes=Math.max(0,Math.floor((Date.now()-Date.parse(v))/60000));return minutes<1?'刚刚':minutes<60?`${minutes} 分钟`:`${Math.floor(minutes/60)}小时 ${minutes%60}分`;}
function orderCupCount(row){return productionItems(row).reduce((sum,item)=>sum+(item.fulfilled?0:Math.max(0,Number(item.quantity)||0)),0);}
function renderKdsOrder(row,history=false){const cancelled=history&&row.status==='cancelled',completed=history&&row.status==='fulfilled',sourceItems=history?(row.items||[]):productionItems(row);const items=sourceItems.map(item=>{const done=!!item.fulfilled||completed;return `<div class="kds-item${done||cancelled?' kds-item-done':''}"><b>${cancelled?'已取消':done?'✓ 已出品':`${Number(item.quantity)} 杯`}</b><span>${esc(item.name)}</span>${!history&&!done?`<button type="button" class="quiet" data-action="fulfilled_item" data-order="${escapeAttr(row.id)}" data-order-item="${escapeAttr(item.id)}">确认这项</button>`:''}</div>`;}).join('');const stateLabel=history?(cancelled?'已取消':'已出品'):(row.payment_status==='paid'?'已付款':'后付');const remaining=sourceItems.some(item=>!item.fulfilled);const shownCups=history?(cancelled?0:(row.items||[]).reduce((sum,item)=>sum+Math.max(0,Number(item.quantity)||0),0)):orderCupCount(row);return `<article class="kds-ticket${history?' kds-ticket-history':''}"><div class="kds-ticket-head"><div class="kds-ticket-main"><span class="kds-source">现场订单${history?' · 历史':''}</span><h3 class="kds-table-number">${esc(row.table_label||'Walk-in')}</h3><small>#${esc(row.order_no||'—')} · ${history?stamp(row.event_at||row.fulfilled_at||row.updated_at):elapsed(row.created_at)} · ${esc(row.created_by_name||'Staff')}</small></div><span class="kds-state ${row.payment_status==='paid'?'paid':''}">${stateLabel}</span></div><div class="kds-cup-highlight"><strong>${shownCups}</strong><span>${history?(cancelled?'已取消':'已出品'):'待出杯'}</span></div><div class="kds-items">${items}</div>${row.notes?`<div class="kds-note">备注：${esc(row.notes)}</div>`:''}${history?'':`<div class="action-row">${remaining?`<button type="button" class="main-button" data-action="fulfilled_all" data-order="${escapeAttr(row.id)}">整单确认出品</button>`:''}${isCashier()?`<button type="button" class="quiet" data-action="request_cancel" data-order="${escapeAttr(row.id)}">申请取消</button>`:''}</div>`}</article>`;}
function renderKdsBoxHistory(row){const selected=Array.isArray(row.selections)&&row.selections.length?row.selections.map(x=>`${esc(x.name)} ×${Number(x.quantity)}`).join(' · '):`${esc(row.component_name||row.name)} ×${Number(row.quantity)}`;const status=row.status==='served'?'已出杯':row.status==='cancelled'?'已取消':'已过期';const when=row.served_at||row.cancelled_at||row.expires_at||row.requested_at;return `<article class="kds-ticket kds-ticket-history storebox-request"><div class="kds-ticket-head"><div class="kds-ticket-main"><span class="kds-source">存酒箱叫酒 · 历史</span><h3 class="kds-table-number">${esc(row.table_label||'未填桌号')}</h3><small>#${esc(row.order_no||'—')} · ${stamp(when)} · ${esc(row.name)}</small></div><span class="kds-state">${status}</span></div><div class="kds-cup-highlight"><strong>${Number(row.quantity)}</strong><span>${esc(row.unit_label||'杯')}</span></div><div class="kds-items"><strong>${selected}</strong></div>${row.cancel_reason?`<div class="kds-note">备注：${esc(row.cancel_reason)}</div>`:''}</article>`;}
function renderKdsHistory(){const root=$('kdsHistoryList'),data=state.kdsHistory;if(!root)return;if(!data){root.innerHTML='<div class="empty">选择营业日后查看记录。</div>';return;}const rows=[...(data.orders||[]).map(row=>({...row,_kind:'order'})),...(data.store_box_requests||[]).map(row=>({...row,_kind:'storebox'}))].sort((a,b)=>Date.parse(b.event_at||b.served_at||b.cancelled_at||b.fulfilled_at||b.updated_at||b.requested_at||0)-Date.parse(a.event_at||a.served_at||a.cancelled_at||a.fulfilled_at||a.updated_at||a.requested_at||0));root.innerHTML=rows.length?rows.map(row=>row._kind==='order'?renderKdsOrder(row,true):renderKdsBoxHistory(row)).join(''):'<div class="empty">这个营业日没有已完成或取消的 KDS 记录。</div>';}
async function loadKdsHistory(){if(!state.identity||state.kdsHistoryLoading)return;state.kdsHistoryLoading=true;const root=$('kdsHistoryList'),day=$('kdsHistoryDate').value||state.businessDay;root.innerHTML='<div class="empty">正在读取 KDS 历史…</div>';try{state.kdsHistory=unpack(await db.rpc('yt_kds_history',{p_day:day,p_limit:100}));state.kdsHistoryDay=day;renderKdsHistory();}catch(error){root.innerHTML=`<div class="empty">${esc(errorText(error))}</div>`;}finally{state.kdsHistoryLoading=false;}}
function renderOrder(row,scope){const pay=row.payment_status==='paid',refunded=row.payment_status==='refunded',cancelled=row.status==='cancelled';
 const binding=row.member_binding,mode=state.luckyMode?.mode||'game',summary=row.benefit_summary,pointsBindingOpen=mode==='off';
 const benefitReady=pay&&row.status==='fulfilled'&&Number(row.balance_rm||0)===0&&!cancelled&&!refunded&&!isAmbassadorOrder(row);
 const processed=summary?.processed??Boolean(binding?.member_binding||['gamepass','lucky_box'].includes(binding?.source));
 const memberActionOpen=pointsBindingOpen&&(isCashier()||isOwner())&&!cancelled&&!refunded&&!isAmbassadorOrder(row);
 const memberActions=memberActionOpen&&binding?.member_binding&&!pay
  ?`${binding.can_unbind?`<button type="button" class="quiet" data-play-member-unbind="${escapeAttr(row.id)}">取消绑定</button>`:''}<small>已绑定会员；结账后按实付金额发积分</small>`
  :memberActionOpen&&!pay&&!binding?.member_binding?binding?.source==='customer_order'
   ?`<button type="button" data-play-member-scan="${escapeAttr(row.id)}">绑定会员并发积分</button>`
   :`<button type="button" data-play-order-qr="${escapeAttr(row.id)}">生成积分绑定 QR</button><button type="button" data-play-member-scan="${escapeAttr(row.id)}">扫描会员码领积分</button>`:'';
 const benefitAction=benefitReady
  ?processed&&(isCashier()||isOwner())?`<button type="button" data-order-benefit-summary="${escapeAttr(row.id)}">查看处理结果</button>`
   :!processed&&mode==='lucky'?`<button type="button" data-benefits="${escapeAttr(row.id)}">分配 Lucky Box</button>`
    :!processed&&mode!=='off'?`<button type="button" data-benefits="${escapeAttr(row.id)}">发游戏资格</button>`:memberActions
  :memberActions;
 const items=(row.items||[]).map(i=>`<div class="order-line"><span>${esc(i.quantity)} × ${esc(i.name)}</span><b>${money(Number(i.quantity)*Number(i.price_rm))}</b></div>`).join('');
 let controls='';
 if(scope==='pending'&&isCashier()&&row.status==='pending')controls=`<div class="action-row"><button type="button" class="primary" data-action="accept" data-order="${escapeAttr(row.id)}">接受订单 →</button><button type="button" class="danger" data-action="reject" data-order="${escapeAttr(row.id)}">拒绝</button></div>`;
 if(scope==='unpaid')controls=`<div class="action-row">${!pay&&row.status==='confirmed'&&(isOwner()||isCashier())&&(row.items||[]).some(item=>item.store_box_item)&&!row.package_preps?.length?`<button type="button" data-order-prep="${escapeAttr(row.id)}">选择 Package 预出杯</button>`:''}<button type="button" class="primary" data-order-cart="${escapeAttr(row.id)}">${isAmbassadorOrder(row)?'Freeflow 收款':row.store_box_only?'收款并发领取码':'优惠与结账'}</button></div>`;
 return `<article class="order"><div class="order-head"><div><h3>#<span>${esc(row.order_no||'—')}</span> · ${esc(row.table_label||'Walk-in')}</h3><small>${esc(row.created_by_name||'Staff')} · ${stamp(row.created_at)}</small><span class="order-status ${pay?'paid':cancelled?'cancelled':row.status==='pending'?'pending':''}">${statusLabel(row)}</span>${scope==='pending'?`<span class="order-status">${checkoutLabel(row)}</span>`:''}</div><div class="order-price">${money(row.amount_rm)}</div></div><details><summary>${(row.items||[]).reduce((sum,item)=>sum+Number(item.quantity||0),0)} 件商品 · 查看明细</summary><div class="order-lines">${items}</div></details>${row.notes?`<small>备注：${esc(row.notes)}</small>`:''}${revisionRequestMarkup(row)}${pay?`<small>✓ ${stamp(row.paid_at)} · ${esc(row.payment_method||'')}</small>`:''}${controls}<div class="receipt-actions"><button type="button" data-receipt="${escapeAttr(row.id)}">${pay||refunded?'账单':'未付款账单'}</button>${!cancelled&&row.payment_status!=='refunded'&&(isOwner()||isCashier()||(!pay&&['pending','confirmed'].includes(row.status)&&state.identity?.can_edit_orders))&&!isAmbassadorOrder(row)?`<button type="button" data-edit="${escapeAttr(row.id)}">${isCashier()?'改单 / 申请取消':'改单'}</button>`:''}${scope!=='unpaid'&&!pay&&!cancelled&&['pending','confirmed','fulfilled'].includes(row.status)&&!(row.status==='confirmed'&&row.store_box_only)?`<button type="button" class="primary" data-order-cart="${escapeAttr(row.id)}">▣ 优惠与结账</button>`:''}${benefitAction||''}</div></article>`;
}
function renderOrders(){const active=$('activeList'),unpaid=$('unpaidList'),pending=$('pendingList'),paid=$('paidList'),production=productionRows().sort((a,b)=>Date.parse(b.created_at)-Date.parse(a.created_at)),tabs=unpaidRows().sort((a,b)=>Date.parse(a.created_at)-Date.parse(b.created_at));
 active.innerHTML=production.map(row=>renderKdsOrder(row)).join('');
 unpaid.innerHTML=tabs.length?tabs.map(row=>renderOrder(row,'unpaid')).join(''):'<div class="empty">目前没有待付款挂单。</div>';
 paid.innerHTML=state.paid.length?state.paid.map(row=>renderOrder(row,'paid')).join(''):'<div class="empty">还没有已结账订单。</div>';
 pending.innerHTML=state.pending.length?state.pending.map(row=>renderOrder(row,'pending')).join(''):'<div class="empty">所有订单已接受，没有待处理的新单。</div>';
 $('pendingCount').textContent=String(state.pending.length);$('unpaidCount').textContent=String(tabs.length);renderKdsEmpty();
 const n=state.pending.length;const banner=$('pendingBanner');banner.classList.add('hidden');
 $('pendingBannerTitle').textContent=n>0?`${n} 笔订单等待 Cashier 接受`:'没有待审核订单';
 $('pendingBannerText').textContent=n?'有新订单待接受。':'已处理完成';
 updateAlertDots();
}
function notifyPending(){if(!isCashier())return;const ids=new Set(state.pending.map(x=>x.id));
 if(state.seenInitialized){const newOrders=state.pending.filter(o=>o.created_channel!=='cashier'&&!state.seenPending.has(o.id));if(newOrders.length){const o=newOrders[0];showNotice(`🔔 收到 ${newOrders.length} 笔 Staff 待审核订单 · ${o.order_no}`,false,true);ping('approval');announceNewOrder();}}
 state.seenPending=ids;state.seenInitialized=true;
}
function notifyKds(){const rows=productionRows(),ids=new Set(rows.map(row=>row.id));if(state.seenKdsInitialized){const added=rows.filter(row=>!state.seenKds.has(row.id));const audible=added.filter(row=>!(state.identity?.role==='cashier'&&((state.authUserId&&row.created_by===state.authUserId)||(!state.authUserId&&row.created_channel==='cashier'&&row.created_by_name===state.identity?.username))));if(audible.length){showNotice(`🔔 吧台新增 ${audible.length} 笔待出品订单`,false,true);announceNewOrder();}}state.seenKds=ids;state.seenKdsInitialized=true;}
let alertAudio=null;
function unlockAudio(){try{const C=window.AudioContext||window.webkitAudioContext;if(!C)return;alertAudio=alertAudio||new C();alertAudio.resume?.();}catch{}}
function ping(kind='kds'){try{unlockAudio();const ctx=alertAudio;if(!ctx)return;const notes=kind==='approval'?[740,940,740]:[880,1100,1320],start=ctx.currentTime+.02;notes.forEach((frequency,index)=>{const osc=ctx.createOscillator(),gain=ctx.createGain(),at=start+index*.16;osc.frequency.value=frequency;gain.gain.setValueAtTime(.0001,at);gain.gain.exponentialRampToValueAtTime(.07,at+.015);gain.gain.exponentialRampToValueAtTime(.0001,at+.12);osc.connect(gain);gain.connect(ctx.destination);osc.start(at);osc.stop(at+.13);});}catch{}}
let lastOrderAnnouncementAt=0;
function announceNewOrder(){if(state.identity?.role!=='cashier')return;const now=Date.now();if(now-lastOrderAnnouncementAt<2500)return;lastOrderAnnouncementAt=now;let fallbackPlayed=false;const fallback=()=>{if(!fallbackPlayed){fallbackPlayed=true;ping('kds');}};try{const synth=window.speechSynthesis,Utterance=window.SpeechSynthesisUtterance;if(!synth||!Utterance)throw Error('voice unavailable');synth.cancel();const message=new Utterance('有新的订单');message.lang='zh-CN';message.rate=1;message.volume=1;message.onerror=fallback;let started=false;message.onstart=()=>{started=true;};const voice=synth.getVoices?.().find(item=>/^zh[-_]/i.test(item.lang));if(voice)message.voice=voice;synth.resume?.();synth.speak(message);setTimeout(()=>{if(!started&&!synth.speaking&&!synth.pending)fallback();},1500);}catch{fallback();}}
async function refreshLuckyMode(force=false){if(!force&&Date.now()-state.luckyModeLoadedAt<30000)return;try{const response=await db.rpc('yt_lucky_public_mode');if(response.error)throw response.error;const previous=state.luckyMode?.mode;state.luckyMode=unpack(response);state.luckyModeLoadedAt=Date.now();state.luckyModeLoadFailed=false;if(previous!==state.luckyMode?.mode&&state.identity){buildNav();if(state.luckyMode?.mode==='off'&&state.currentTab==='benefits')showTab(defaultTab());}}catch(error){state.luckyMode={mode:'game'};state.luckyModeLoadedAt=Date.now();state.luckyModeLoadFailed=true;console.warn('Unable to read active benefit mode; member-points binding stays hidden.',error?.message||error);}}
 async function refreshOrders(silent=true){if(!state.identity||state.refreshing)return;state.refreshing=true;
 try{await refreshLuckyMode();const context=unpack(await db.rpc('yt_business_context'));if(state.businessDay!==context.day){if(!$('paidDate').value||$('paidDate').value===state.businessDay)$('paidDate').value=context.day;state.businessDay=context.day;}const calls=[db.rpc('yt_pos_orders',{p_scope:'active',p_limit:80}),db.rpc('yt_pos_orders_day',{p_scope:'paid',p_day:$('paidDate').value||null,p_limit:100})];if(isCashier()){calls.push(db.rpc('yt_pos_orders',{p_scope:'pending',p_limit:80}));if(!isOwner())calls.push(db.rpc('yt_pos_owner_revision_requests_mine'));}const rows=await Promise.all(calls.map(unpackPromise));
 state.active=rows[0]||[];state.paid=rows[1]||[];state.pending=isCashier()?(rows[2]||[]):[];state.revisionRequests=isCashier()&&!isOwner()?(rows[3]||[]):[];
 const packageOrderIds=state.active.filter(row=>row.status==='confirmed'&&(row.items||[]).some(item=>item.store_box_item)).map(row=>row.id);if(packageOrderIds.length){try{const prepMap=unpack(await db.rpc('yt_pos_kds_package_preps',{p_orders:packageOrderIds}))||{};for(const row of state.active)row.package_preps=prepMap[row.id]||[];}catch(error){console.warn('KDS Package 预出杯信息载入失败',error?.message||error);}}
 if((isCashier()||isOwner())&&state.paid.length){try{const ids=state.paid.filter(row=>row.payment_status==='paid').map(row=>row.id);if(ids.length){const summaries=unpack(await db.rpc('yt_pos_order_benefit_summaries',{p_orders:ids}))||{};for(const row of state.paid)row.benefit_summary=summaries[row.id]||null;}}catch(error){console.warn('订单权益摘要载入失败',error?.message||error);}}
 notifyPending();notifyKds();renderOrders();refreshRedeemOrderChoices();if(isCashier())await loadDuitNowProofs(silent);await storeBox?.loadOrderQueue(silent);if(isOwner())await refreshOwnerApprovalCount(silent);if(isCashier()||isOwner())await refreshBellIndicator(silent);}
 catch(e){if(!silent)showNotice(errorText(e),true);}finally{state.refreshing=false;}}
async function refreshOwnerApprovalCount(silent=true){
 if(!isOwner())return;try{const result=await db.rpc('yt_pos_owner_revision_requests_list');if(result.error)throw result.error;const rows=Array.isArray(result.data)?result.data:[],count=rows.filter(row=>row.status==='pending').length,badge=$('revisionApprovalCount');if(badge){badge.textContent='';badge.classList.toggle('hidden',!count);badge.setAttribute('aria-label',count?count+' 笔待审批':'没有待审批订单');}document.querySelectorAll('[data-owner-approval-dot]').forEach(dot=>dot.classList.toggle('hidden',!count));if(approvalCount!==null&&count>approvalCount)showNotice('有 '+count+' 笔改单／取消申请等待 Owner 审批');approvalCount=count;}catch(error){if(!silent)throw error;console.warn('改单待审数量载入失败',error);}
}
async function loadOwnerApprovals(){if(!isOwner())return;orderApprovals||=createOwnerOrderApprovals({db,root:$('ownerOrderApprovalsRoot'),notice:(message,bad)=>showNotice(errorText(Error(message)),bad),onChange:()=>refreshOrders(false)});await orderApprovals.load();await refreshOwnerApprovalCount(false);}
async function refreshBellIndicator(silent=true){
 const button=[...($('nav')?.querySelectorAll('button')||[])].find(item=>item.dataset.tab==='bell');if(!button||(!isOwner()&&!isCashier()))return;
 try{const result=await db.rpc('yt_play_bell_list');if(result.error)throw result.error;const rows=Array.isArray(result.data)?result.data:[],pending=rows.some(row=>row.status==='pending');button.classList.toggle('has-alert',pending);button.removeAttribute('data-pending-count');button.setAttribute('aria-label',pending?'服务铃有待确认呼叫':'服务铃');}
 catch(error){if(!silent)console.warn('服务铃状态载入失败',error);}
}
const unpackPromise=async p=>unpack(await p);
async function loadDuitNowProofs(silent=true){
 const root=$('duitnowProofList');if(!root||!isCashier())return;
 try{
  const rows=unpack(await db.rpc('yt_pos_duitnow_proof_list'))||[];state.duitnowProofs=rows;
  $('duitnowProofCount').textContent=String(rows.length);root.replaceChildren();
  if(!rows.length){root.innerHTML='<div class="empty">目前没有待确认的 DuitNow 记录。</div>';return;}
  for(const row of rows){
   const card=document.createElement('article');card.className='order';card.dataset.proofOrder=row.order_id;
   const head=document.createElement('div');head.className='order-head';const info=document.createElement('div');
   const title=document.createElement('h3');title.textContent=`#${row.order_no} · ${row.table_label||'Walk-in'}`;
   const meta=document.createElement('small');meta.textContent=`${row.submitted_by||'Staff'} · ${stamp(row.submitted_at)} · DuitNow${row.status==='pending'?' · 待确认':row.status==='confirmed'?' · 已确认，待清理截图':' · 已拒绝，待清理截图'}`;
   const amount=document.createElement('div');amount.className='order-price';amount.textContent=money(row.amount_rm);info.append(title,meta);head.append(info,amount);card.append(head);
   const image=document.createElement('img');image.alt=`${row.order_no} DuitNow 交易记录`;image.loading='lazy';image.style.cssText='display:block;width:min(100%,420px);max-height:420px;object-fit:contain;margin:12px auto;border-radius:12px;background:#fff;padding:8px';
   const downloaded=await db.storage.from('yetipsy-payment-proof').download(row.storage_path);if(downloaded.error)throw downloaded.error;
   const objectUrl=URL.createObjectURL(downloaded.data);image.src=objectUrl;image.onload=()=>URL.revokeObjectURL(objectUrl);card.append(image);
   const actions=document.createElement('div');actions.className='action-row';
   if(row.status==='pending'){const approve=document.createElement('button');approve.type='button';approve.className='primary';approve.dataset.proofAction='confirm';approve.dataset.order=row.order_id;approve.textContent='确认已到账';
    const reject=document.createElement('button');reject.type='button';reject.className='danger';reject.dataset.proofAction='reject';reject.dataset.order=row.order_id;reject.textContent='拒绝并退回未付款';actions.append(approve,reject);
   }else{const cleanup=document.createElement('button');cleanup.type='button';cleanup.className='quiet';cleanup.dataset.proofAction='cleanup';cleanup.dataset.order=row.order_id;cleanup.textContent='重试删除交易截图';actions.append(cleanup);}card.append(actions);root.append(card);
  }
 }catch(error){if(!silent)showNotice(errorText(error),true);else console.error('DuitNow review queue failed',error);}
}
async function handleDuitNowProofAction(event){
 const button=event.target.closest('[data-proof-action]');if(!button)return;
 await busy(button,async()=>{
  const action=button.dataset.proofAction,row=state.duitnowProofs.find(item=>item.order_id===button.dataset.order);
  if(!row)throw Error('payment_proof_not_pending');
  let approve=false,note=null,result;
  if(action==='cleanup'){result={storage_path:row.storage_path};}
  else{approve=action==='confirm';if(approve&&!window.confirm(`确认 ${row.order_no} 的 ${money(row.amount_rm)} DuitNow 已到账？确认后订单会入账，截图立即删除。`))return;
   if(!approve){if(!window.confirm(`拒绝 ${row.order_no} 的 DuitNow 记录？订单会恢复为未付款，截图会删除。`))return;note=window.prompt('拒绝原因（可留空）','');if(note===null)return;}
   result=unpack(await db.rpc('yt_pos_duitnow_proof_review',{p_order:row.order_id,p_confirm:approve,p_note:note}));}
  const removed=await db.storage.from('yetipsy-payment-proof').remove([result.storage_path]);
  if(removed.error)throw Error(`状态已记录，但截图删除失败：${removed.error.message}。可在此队列重试。`);
  unpack(await db.rpc('yt_pos_duitnow_proof_cleanup_complete',{p_order:row.order_id}));
  await refreshOrders(false);showNotice(action==='cleanup'?'交易截图已清理。':approve?`${row.order_no} 已确认收款，截图已删除。`:`${row.order_no} 已拒绝，订单恢复未付款，截图已删除。`);
 }).catch(()=>{});
}
async function orderAction(orderId,action,container){if(action==='request_cancel'){await openEditDialog(orderId);$('editCancelOrder').checked=true;state.editDirty=true;await previewOwnerEdit();return;}const btn=container;await busy(btn,async()=>{
 if(action==='fulfilled_item'||action==='fulfilled_all'){const itemId=action==='fulfilled_item'?btn.dataset.orderItem:null;if(action==='fulfilled_all'&&!window.confirm('确认整单所有商品都已完成出品？'))return;const result=unpack(await db.rpc('yt_pos_item_fulfill',{p_order:orderId,p_order_item:itemId,p_all:action==='fulfilled_all'}));showNotice(result.status==='fulfilled'?'全部商品已出品；订单保留在订单页待收款。':`已确认出品：${result.item_name||'该商品'}。`);await refreshOrders(false);return;}
 let reason=null,method=null;const sourceRow=[...state.active,...state.pending].find(row=>row.id===orderId);
 if(action==='reject'||action==='cancel'){reason=window.prompt('请填写拒绝／取消原因（必填）','客人取消');if(reason===null)return;if(reason.trim().length<2)throw Error('reason_required');}
 if(action==='paid'){const card=btn.closest('.order');method=card?.querySelector('[data-payment]')?.value||'foodcourt';
   const quote=unpack(await db.rpc('yt_pos_cart_summary',{p_order:orderId}));
   if(!quote.can_pay)throw Error('coupon_hold_not_ready_or_expired');
   if(!window.confirm(`确认已收到 ${money(quote.payable_rm)}？\n已预留优惠：−${money(quote.reserved_discount_rm)}\n收款方式：${method.toUpperCase()}\n\n点击确认后才会正式使用顾客奖券。`))return;}
 if(isOwner()&&['paid','fulfilled','accept'].includes(action)){const row=[...state.active,...state.pending].find(x=>x.id===orderId);if(row&&Date.parse(row.created_at)<=Date.now()-72*3600000){reason=window.prompt('Owner 批准处理超过72小时订单，请填写原因','已现场核对');if(reason===null)return;if(reason.trim().length<2)throw Error('reason_required');}}
 if(action==='fulfilled'&&!window.confirm('确认整单所有商品都已完成出品？'))return;
 const result=unpack(await db.rpc('yt_pos_action',{p_order:orderId,p_action:action,p_reason:reason,p_method:method}));
 showNotice(action==='fulfilled'&&result.payment_status==='paid'?'已完成出品，订单完成':({accept:'已接受，订单进入吧台 KDS',reject:'订单已拒绝',fulfilled:'已完成出品，订单进入挂单',paid:'已经记录收款',cancel:'订单已取消'})[action]||'状态已更新');
 await refreshOrders(false);
 if(action==='accept'&&(isCashier()||isOwner()))await promptCashierPackagePrep(orderId);
 }).catch(()=>{});}
let bannerManager=null;
async function loadPOSBanners(){if(!isOwner())return;if(!bannerManager)bannerManager=createBannerManager({db,root:$('ownerBannersPanel'),notify:showNotice});await bannerManager.load();}
async function loadAdmin(){if(!isOwner())return;await loadPOSBanners();await loadCatalog();await Promise.all([loadRights(),loadRewardRules()]);}
function renderProductAdmin(){if(!isOwner())return;const root=$('productAdminList');root.innerHTML=state.catalog.length?state.catalog.map(p=>`<div class="admin-entry"><div><strong>${esc(p.name)}</strong><small>${esc(p.category)} · ${money(p.price_rm)} · ${p.active?'可点单':'已停用'} · ${esc(p.series_name||'没有系列权益')}</small></div><div class="admin-entry-actions"><button data-copy-product="${esc(p.id)}" type="button">复制</button><button data-product="${esc(p.id)}" type="button">编辑</button></div></div>`).join(''):'<div class="empty">当前没有产品。请先新增菜单。</div>';}
async function saveProduct(e){e.preventDefault();await busy($('productForm').querySelector('[type=submit]'),async()=>{
 const id=$('productId').value||null;const price=Number($('productPrice').value);if(!Number.isFinite(price)||price<0||price>5000)throw Error('请输入正确产品价格');
 unpack(await db.rpc('yt_pos_owner_product_v2',{p_id:id,p_name:$('productName').value.trim(),p_category:$('productCategory').value.trim(),p_price:price,p_active:$('productActive').checked,p_sort:Number($('productSort').value),p_series:$('productSeries').value||null}));
 clearProduct();await loadCatalog();showNotice(id?'产品已更新':'产品已加入菜单');
 }).catch(()=>{});}
function editProduct(id){const p=state.catalog.find(x=>x.id===id);if(!p)return;consoleUI?consoleUI.open('catalog','products'):showTab('admin');$('productId').value=p.id;$('productName').value=p.name;$('productCategory').value=p.category;$('productPrice').value=p.price_rm;$('productActive').checked=p.active;$('productSort').value=p.sort_order||100;$('productSeries').value=p.series_id||'';window.scrollTo({top:0,behavior:'smooth'});}
function copyProduct(id){const p=state.catalog.find(x=>x.id===id);if(!p)return;consoleUI?consoleUI.open('catalog','products'):showTab('admin');$('productId').value='';$('productName').value=p.name+' 副本';$('productCategory').value=p.category;$('productPrice').value=p.price_rm;$('productActive').checked=p.active;$('productSort').value=Number(p.sort_order||100)+1;$('productSeries').value=p.series_id||'';$('productName').focus();$('productName').select();}
function clearProduct(){$('productForm').reset();$('productId').value='';$('productActive').checked=true;$('productSort').value=100;$('productSeries').value='';}
async function loadRights(){if(!isOwner())return;const staff=unpack(await db.rpc('yt_pos_staff_list'))||[];
 $('staffRights').innerHTML=staff.length?staff.map(x=>`<div class="admin-entry"><div><strong>${esc(x.username)}</strong><small>${x.active?'Active':'Disabled'} · ${x.role==='cashier'?'Cashier 独立账号':'Staff'}</small></div>${x.role==='cashier'?'<span>独立 Cashier 账号</span>':`<label class="checkline"><input type="checkbox" data-cashier="${esc(x.id)}" ${x.can_cashier?'checked':''} ${!x.active?'disabled':''}><span>收银权限</span></label><label class="checkline"><input type="checkbox" data-edit-staff="${esc(x.id)}" ${x.can_edit_orders?'checked':''} ${!x.active?'disabled':''}><span>改单权限</span></label>`}</div>`).join(''):'<div class="empty">还没有 Staff 账户。</div>';}
async function loadRewardRules(){
 if(!isOwner())return;
 state.rewardRules=unpack(await db.rpc('yt_pos_owner_reward_rules'))||[];
 const select=$('mapReward'),old=select.value;select.replaceChildren(new Option('选择奖励后进入修改模式',''));
 for(const r of state.rewardRules)select.add(new Option(`${r.reward_name}${!r.active?'（已停用）':''}`,r.reward_id));
 if(state.rewardRules.some(r=>r.reward_id===old))select.value=old;
 const product=$('mapProduct'),ps=product.value;product.replaceChildren(new Option('选择具体产品',''));
 for(const item of state.catalog)if(item.active)product.add(new Option(`${item.name} · ${money(item.price_rm)}`,item.id));
 if(state.catalog.some(x=>x.id===ps))product.value=ps;
 const series=$('mapSeries'),oldS=series.value;series.replaceChildren(new Option('选择产品系列',''));
 for(const item of state.series)if(item.active)series.add(new Option(item.name,item.id));
 if(state.series.some(x=>x.id===oldS))series.value=oldS;
 renderRewardMappings();
 if(ownerRewardMode==='edit'&&select.value)updateRewardMapForm();
}
let ownerRewardMode='create',rewardSaveRetry=null;
function localDateTime(value){if(!value)return '';const d=new Date(value);if(Number.isNaN(d.getTime()))return '';const p=n=>String(n).padStart(2,'0');return `${d.getFullYear()}-${p(d.getMonth()+1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;}
function setRewardEditorMode(mode,{rewardId='',copy=false}={}){
 ownerRewardMode=mode;const editing=mode==='edit';
 $('rewardModeCreate').classList.toggle('active',!editing);$('rewardModeEdit').classList.toggle('active',editing);
 $('rewardEditPicker').classList.toggle('hidden',!editing);$('rewardEditorTitle').textContent=editing?'修改奖励':'创建奖励';
 $('saveRewardEditor').textContent=editing?'保存修改':'创建奖励';$('cancelRewardEdit').classList.toggle('hidden',!editing);
 if(rewardId)$('mapReward').value=rewardId;
 if(editing){if($('mapReward').value)updateRewardMapForm();else clearRewardEditor();}else clearRewardEditor();
}
function clearRewardEditor(){
 $('ownerNewRewardForm').reset();$('mapReward').value='';$('ownerNewRewardDays').value=30;$('ownerNewRewardNextDay').checked=true;
 $('mapMode').value='product';$('mapProduct').value='';$('mapSeries').value='';$('mapDiscountType').value='free';$('mapDiscountValue').value='5';$('mapMinDrinks').value=1;$('mapMinSpend').value=0;toggleMapInputs();
}
function updateRewardMapForm(){
 const r=state.rewardRules?.find(x=>x.reward_id===$('mapReward').value);if(!r)return;
 $('ownerNewRewardName').value=r.reward_name||'';$('ownerNewRewardDesc').value=r.description||'';$('ownerNewRewardCategory').value=r.category||'custom';
 $('ownerNewRewardDays').value=r.validity_days||30;$('ownerNewRewardNextDay').checked=!!r.next_day_only;
 $('ownerNewRewardStart').value=localDateTime(r.redeem_start_at);$('ownerNewRewardEnd').value=localDateTime(r.redeem_end_at);
 $('ownerNewRewardClockFrom').value=String(r.daily_start_local||'').slice(0,5);$('ownerNewRewardClockUntil').value=String(r.daily_end_local||'').slice(0,5);
 $('mapMode').value=['product','series','any_drink','disabled'].includes(r.mode)?r.mode:'disabled';
 $('mapProduct').value=r.product_id||'';$('mapSeries').value=r.series_id||'';
 $('mapDiscountType').value=['free','fixed','percent'].includes(r.discount_type)?r.discount_type:'free';$('mapDiscountValue').value=r.discount_value||5;
 $('mapMinDrinks').value=r.min_paid_drinks??1;$('mapMinSpend').value=r.min_spend_rm??0;toggleMapInputs();
}
function toggleMapInputs(){
 const mode=$('mapMode').value,disabled=mode==='disabled';
 const free=$('mapDiscountType').options[0];if(free)free.disabled=mode==='any_drink';
 if(mode==='any_drink'&&$('mapDiscountType').value==='free')$('mapDiscountType').value='fixed';
 $('mapProductLabel').classList.toggle('hidden',disabled||mode!=='product');
 $('mapSeriesLabel').classList.toggle('hidden',disabled||mode!=='series');
 $('mapDiscountType').closest('label').classList.toggle('hidden',disabled);
 $('mapDiscountValueLabel').classList.toggle('hidden',disabled||$('mapDiscountType').value==='free');
 $('mapMinDrinks').closest('label').classList.toggle('hidden',disabled);$('mapMinSpend').closest('label').classList.toggle('hidden',disabled);
}
function describeRewardRule(r){
 const product=state.catalog.find(p=>p.id===r.product_id)?.name,series=state.series.find(p=>p.id===r.series_id)?.name;
 const scope=r.mode==='product'?'指定商品：'+(product||'已停售商品'):r.mode==='series'?'指定系列：'+(series||'历史系列'):r.mode==='any_drink'?'任意饮品抵扣':r.mode==='disabled'?'暂停兑奖':'未配置 POS 兑奖规则';
 const discount=['product','series','any_drink'].includes(r.mode)?' · '+(r.discount_type==='fixed'?'RM'+r.discount_value+' 抵扣':r.discount_type==='percent'?r.discount_value+'% 折扣':'免费一份'):'';
 return scope+discount+(['product','series','any_drink'].includes(r.mode)?` · 最少 ${r.min_paid_drinks??1} 杯付费饮品`+(Number(r.min_spend_rm)>0?' · 净消费 ≥ RM'+r.min_spend_rm:''):'');
}
function renderRewardMappings(){
 const el=$('rewardMappingList');if(!el)return;
 el.innerHTML=(state.rewardRules||[]).slice(0,120).map(r=>`<div class="reward-map-item"><div><strong>${esc(r.reward_name)}</strong><small>${esc(describeRewardRule(r))}</small></div><div class="admin-entry-actions"><button type="button" data-reward-edit="${esc(r.reward_id)}">修改</button><button type="button" data-reward-copy="${esc(r.reward_id)}">复制</button></div></div>`).join('');
 const pending=(state.rewardRules||[]).filter(r=>!['product','series','any_drink'].includes(r.mode)).length;
 $('rewardBindingSummary').textContent=pending?`${pending} 种奖励暂停或尚未配置兑奖规则。`:'所有奖励均已配置兑奖规则。';
 $('rewardBindingSummary').classList.toggle('all-bound',pending===0);
}
function copyRewardToEditor(id){const r=state.rewardRules.find(x=>x.reward_id===id);if(!r)return;
 setRewardEditorMode('create');clearRewardEditor();$('ownerNewRewardName').value=String(r.reward_name||'奖励').slice(0,116)+' 副本';$('ownerNewRewardDesc').value=r.description||'';$('ownerNewRewardCategory').value=r.category||'custom';
 $('ownerNewRewardDays').value=r.validity_days||30;$('ownerNewRewardNextDay').checked=!!r.next_day_only;$('ownerNewRewardStart').value=localDateTime(r.redeem_start_at);$('ownerNewRewardEnd').value=localDateTime(r.redeem_end_at);
 $('ownerNewRewardClockFrom').value=String(r.daily_start_local||'').slice(0,5);$('ownerNewRewardClockUntil').value=String(r.daily_end_local||'').slice(0,5);
 $('mapMode').value=['product','series','any_drink','disabled'].includes(r.mode)?r.mode:'disabled';$('mapProduct').value=r.product_id||'';$('mapSeries').value=r.series_id||'';
 $('mapDiscountType').value=['free','fixed','percent'].includes(r.discount_type)?r.discount_type:'free';$('mapDiscountValue').value=r.discount_value||5;$('mapMinDrinks').value=r.min_paid_drinks??1;$('mapMinSpend').value=r.min_spend_rm??0;
 toggleMapInputs();$('ownerNewRewardName').focus();$('ownerNewRewardName').select();
}
async function saveOwnerReward(e){e.preventDefault();const btn=e.submitter;await busy(btn,async()=>{
 if(!isOwner())throw Error('owner_only');
 const name=$('ownerNewRewardName').value.trim(),days=Number($('ownerNewRewardDays').value);
 if(name.length<2||!Number.isInteger(days)||days<1||days>365)throw Error('请输入奖励名称及正确有效天数');
 if(ownerRewardMode==='create'&&$('mapMode').value==='disabled')throw Error('创建奖励时请先设置可用的兑奖规则');
 const from=$('ownerNewRewardStart').value,until=$('ownerNewRewardEnd').value,clockFrom=$('ownerNewRewardClockFrom').value,clockUntil=$('ownerNewRewardClockUntil').value;
 if(Boolean(clockFrom)!==Boolean(clockUntil))throw Error('每日使用时间必须同时输入开始和结束');
 const mode=$('mapMode').value,type=$('mapDiscountType').value;
 const product=mode==='product'?$('mapProduct').value:null;
 const series=mode==='series'?$('mapSeries').value:null;
 if(mode==='product'&&!product||mode==='series'&&!series)throw Error('必须选择对应的产品或系列');
 const discountType=mode==='disabled'?'free':type,value=discountType==='free'?0:Number($('mapDiscountValue').value),minimum=mode==='disabled'?1:Number($('mapMinDrinks').value),spend=mode==='disabled'?0:Number($('mapMinSpend').value);
 if(mode!=='disabled'&&(!Number.isInteger(minimum)||minimum<1||minimum>20||!Number.isFinite(spend)||spend<0||spend>10000))throw Error('至少保留一杯付费饮品，并填写有效最低消费');
 if(mode!=='disabled'&&type!=='free'&&(!Number.isFinite(value)||value<=0||value>(type==='percent'?100:5000)))throw Error('请填写正确抵扣金额或折扣百分比');
 const reward={name,description:$('ownerNewRewardDesc').value.trim(),category:$('ownerNewRewardCategory').value,validity_days:days,next_day_only:$('ownerNewRewardNextDay').checked,use_from:from?new Date(from).toISOString():null,use_until:until?new Date(until).toISOString():null,daily_from:clockFrom||null,daily_until:clockUntil||null};
 const binding={mode,product_id:product||null,series_id:series||null,discount_type:discountType,discount_value:value,min_paid_drinks:minimum,min_spend_rm:spend};
 if(ownerRewardMode==='edit'){
  const id=$('mapReward').value;if(!id)throw Error('请先选择要修改的奖励');
  unpack(await db.rpc('yt_owner_update_bound_reward_v1',{p_reward:id,p_reward_data:reward,p_binding:binding}));
  await loadRewardRules();$('mapReward').value=id;updateRewardMapForm();await loadOwnerRewardOffers();showNotice('奖励资料与兑奖规则已一起更新');
 }else{
  const key=JSON.stringify([reward,binding]);if(rewardSaveRetry?.key!==key)rewardSaveRetry={key,request:crypto.randomUUID()};
  const id=unpack(await db.rpc('yt_owner_create_bound_reward_v6',{p_reward:reward,p_binding:binding,p_request:rewardSaveRetry.request}));
  rewardSaveRetry=null;await loadRewardRules();await loadOwnerRewardOffers();$('ownerNewRewardForm').reset();clearRewardEditor();showNotice('奖励与兑奖规则已创建');
 }
 }).catch(()=>{});}
function cancelRewardEdit(){clearRewardEditor();setRewardEditorMode('create');}
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
 if(!resp.ok||!data.ok)throw Error(data.message||
data.error||'PIN 重设失败');
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
 const paid=r.payment_status==='paid',refunded=r.payment_status==='refunded',balance=Number(r.balance_rm||0),s=r.receipt_settings||{};
 const lang=['zh','en','bilingual'].includes(s.receipt_language)?s.receipt_language:'bilingual',label=(zh,en)=>lang==='zh'?zh:lang==='en'?en:`${zh} ${en}`;
 const showTable=s.show_table!==false,showStaff=s.show_staff!==false,showNotes=s.show_notes!==false,showDiscounts=s.show_discounts!==false,width=[58,80].includes(Number(s.paper_width_mm))?Number(s.paper_width_mm):80;
 const business=esc(s.business_name||'YE·TIPSY'),subtitle=esc(s.subtitle??'KLUANG · POINT OF SALE'),address=esc(s.address_line||''),contact=esc(s.contact_line||''),footer=esc(s.footer_text||'Thank you for visiting Yetipsy.').replace(/\n/g,'<br>');
 const items=(r.items||[]).map(i=>`<div class="receipt-row"><div><strong>${esc(i.item_name||'Drink')}</strong><small>${Number(i.quantity)} × ${money(i.unit_price_rm)}${showDiscounts&&Number(i.discount_rm)>0?' · '+label('优惠','DISCOUNT')+' −'+money(i.discount_rm):''}</small></div><b>${money(i.line_total_rm)}</b></div>`).join('');
 const discount=Number(r.discount_total_rm||0);
 return `<div class="receipt-paper" id="receiptPaper" style="--receipt-width:${width}mm"><div class="receipt-logo">${business}</div>${subtitle?`<div class="receipt-subhead">${subtitle}</div>`:''}${address?`<div class="receipt-business-line">${address}</div>`:''}${contact?`<div class="receipt-business-line">${contact}</div>`:''}
 <div class="receipt-document">${refunded?label('已退款取消 ·','REFUND RECORD'):['cancelled','rejected'].includes(r.status)?label('已取消 · 非付款凭证','CANCELLED · NOT A RECEIPT'):paid?'✓ '+label('已收款 ·','PAYMENT RECEIPT'):label('尚未结账 ·','UNPAID BILL')}</div>
 <div class="receipt-facts"><p><strong>#${esc(r.order_no||'—')}</strong></p>${showTable?`<p>${label('桌号','Table')} · ${esc(r.table_label||'Walk-in')}</p>`:''}<p>${label('开单','Created')} · ${esc(friendlyDate(r.created_at))}</p>${showStaff?`<p>${label('员工','By')} · ${esc(r.created_by||'—')}</p>`:''}
 ${paid?`<p>${label('付款','Paid')} · ${esc(friendlyDate(r.paid_at))}</p><p>${label('方式','Payment')} · ${esc((r.payment_method||'foodcourt').toUpperCase())}</p>`:''}
 ${showNotes&&r.notes?`<p>${label('备注','Note')} · ${esc(r.notes)}</p>`:''}</div>
 <div class="receipt-items-head"><span>${label('商品 /','ITEM')}</span><span>${label('金额 /','AMOUNT')}</span></div>${items}
 <div class="receipt-subtotal"><span>${label('商品原价','SUBTOTAL')}</span><b>${money(r.gross_total_rm)}</b></div>
 ${showDiscounts?(r.discounts||[]).map(d=>`<div class="receipt-discount"><div><span>${esc(d.reward_name||label('奖励优惠','REWARD'))}</span>${d.item_name?`<small>${esc(d.item_name)}</small>`:''}</div><b>−${money(d.discount_rm)}</b></div>`).join(''):''}
 ${showDiscounts&&discount>0?`<div class="receipt-subtotal"><span>${label('优惠合计','DISCOUNT')}</span><b>−${money(discount)}</b></div>`:''}
 <div class="receipt-sum"><span>${refunded?label('修订后金额','REVISED TOTAL'):paid&&balance!==0?label('修订后应付','TOTAL DUE'):paid?label('已收款','TOTAL PAID'):label('应付','AMOUNT DUE')}</span><strong>${money(r.amount_rm)}</strong></div>
 ${(paid||refunded)&&balance!==0?`<div class="receipt-subtotal"><span>${label('实收净额','NET RECEIVED')}</span><b>${money(r.received_rm)}</b></div><div class="receipt-hold-note">${balance>0?label('尚需补收','BALANCE DUE'):label('尚需退款','REFUND DUE')} ${money(Math.abs(balance))}</div>`:''}
 ${r.payment_entries?.length>1?`<details class="receipt-payments" open><summary>${label('收款与退款记录','PAYMENT HISTORY')}</summary>${r.payment_entries.map(e=>`<div class="receipt-row"><span>${esc(({cash:label('现金','CASH'),foodcourt:label('食阁','FOODCOURT'),duitnow:'DuitNow',card:label('刷卡','CARD'),bank_transfer:label('转账','TRANSFER'),other:label('其他','OTHER')})[e.method]||e.method)} · ${Number(e.amount_rm)<0?label('退款','REFUND'):e.kind==='adjustment'?label('补收','ADJUSTMENT'):label('收款','PAYMENT')}</span><b>${Number(e.amount_rm)<0?'−':''}${money(Math.abs(e.amount_rm))}</b></div>`).join('')}</details>`:''}
 ${r.discount_pending?`<p class="receipt-hold-note">${label('上述优惠已预留，完成结账后正式核销。','Discounts are reserved until checkout.')}</p>`:''}
 ${!paid&&!refunded&&(r.unresolved_count>0||r.minimum_met===false)?`<p class="receipt-hold-note">${label('优惠需要店员重新核对，当前账单尚不能结账。','Discounts need review before checkout.')}</p>`:''}
 <p class="receipt-bottom">${footer}${footer?'<br>':''}${label('店内账单记录 · 非税务发票','Store bill · Not a tax invoice')}</p>
 </div>`;
}
async function viewReceipt(orderId){
 const data=unpack(await db.rpc('yt_pos_bill_v8',{p_order:orderId}));
 $('receiptContent').innerHTML=receiptInner(data);
 applyReceiptLayout($('receiptContent').querySelector('.receipt-paper'),data.receipt_settings?.layout,data.payment_status==='paid'?'paid':'unpaid');
 $('receiptTitle').textContent='#'+(data.order_no||'ORDER')+' · '+(data.payment_status==='refunded'?'退款记录':data.payment_status==='paid'?'Receipt':'未付款账单');
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
 <small>${esc(s.benefit_mode)} · ${Number(s.game_plays||0)} 次 · ${s.active?'已开放':'关闭'}${s.game_plays>1?' · 暂不可发放':''}</small></div>
 <button type="button" data-series="${esc(s.id)}">编辑</button></div>`).join(''):'<div class="empty">还没有系列。先建立 CLASSIC / TOWER 等分类并设置权益。</div>';
}
function editSeries(id){const s=state.series.find(x=>x.id===id);if(!s)return;
 consoleUI?consoleUI.open('catalog','series'):showTab('admin');$('seriesId').value=s.id;$('seriesName').value=s.name;$('seriesMode').value=s.benefit_mode;
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

async function loadBenefits(preferred=null,poll=false){
 if(!state.identity)return;
 const stateResp=unpack(await db.rpc('yt_lucky_public_mode'));
 state.luckyMode=stateResp;state.luckyModeLoadedAt=Date.now();state.luckyModeLoadFailed=false;buildNav();renderOrders();
 const benefitTitle=$('benefitTitle');if(benefitTitle)benefitTitle.textContent=stateResp.mode==='lucky'?'分配 Lucky Box':stateResp.mode==='off'?'会员积分':'分配 GamePass';
 const modeHint=$('benefitModeHint');
 if(modeHint)modeHint.textContent=stateResp.mode==='lucky'?'当前为 Lucky Box：扫码直接开箱抽积分，整单一个箱子或按单杯分别开。最低合资格实付 RM'+Number(stateResp.minimum_spend_rm).toFixed(2)+
  '。发码不需要绑定游戏、系列或活动。':stateResp.mode==='off'?'Owner 已暂停新游戏码发放；之前已发的 QR 不受影响。':'当前为 Game Mode：照旧发放 GamePass 供顾客选择游戏。';
 const ticket=state.benefitListEpoch=(state.benefitListEpoch||0)+1;const existing=preferred||$('benefitOrderSelect').value;
 const actor=state.identity?.username;const response=unpack(await db.rpc(state.luckyMode?.mode==='lucky'?'yt_lucky_pos_benefit_orders':'yt_pos_benefit_orders'));if(state.identity?.username!==actor||ticket!==state.benefitListEpoch)return;state.businessDay=response.business_day;const list=response.orders||[];
 const select=$('benefitOrderSelect');select.replaceChildren(new Option('请选择当天仍可分配的订单',''));
 for(const r of list)select.add(new Option(`#${r.order_no} · ${r.table_label||'Walk-in'} · ${money(r.amount_rm)}`,r.id));
 if(list.some(x=>x.id===existing))select.value=existing;
 await loadBenefitCampaigns();
 await loadSelectedPaidUnits(poll);
}
async function loadBenefitCampaigns(){
 if(state.luckyMode?.mode==='lucky'){$('benefitCampaign').replaceChildren(new Option('Lucky Box · 无需选择活动',''));return;}
 const selected=$('benefitCampaign').value,actor=state.identity?.username;
 const r=unpack(await db.from('campaigns').select('id,name,active,is_default,starts_at,ends_at').eq('active',true).order('created_at',{ascending:false}))||[];
 if(state.identity?.username!==actor)return;const sel=$('benefitCampaign');sel.replaceChildren(new Option('请选择活动',''));
 const available=r.filter(c=>(!c.starts_at||Date.parse(c.starts_at)<=Date.now())&&(!c.ends_at||Date.parse(c.ends_at)>Date.now()));for(const c of available)sel.add(new Option(c.name+(c.is_default?' · 默认':''),c.id));
 if(available.some(x=>x.id===selected))sel.value=selected;else if(available.some(x=>x.is_default))sel.value=available.find(x=>x.is_default).id;else if(available.length===1)sel.value=available[0].id;
}
let benefitEpoch=0;
const bundleKey=id=>`yt-pos-v8-bundle:${state.identity?.username||''}:${id}`;
function cachedBundle(id){try{return JSON.parse(sessionStorage.getItem(bundleKey(id))||'null')}catch{return null}}
function benefitMode(mode){state.benefitMode=mode;$('benefitWhole').classList.toggle('hidden',mode!=='whole');$('benefitUnits').classList.toggle('hidden',mode!=='single');for(const [id,m] of [['benefitWholeMode','whole'],['benefitSingleMode','single']]){$(id).classList.toggle('active',mode===m);$(id).setAttribute('aria-pressed',String(mode===m));}$('benefitQR').classList.add('hidden');}
function renderBundleQuote(id,quote){$('cancelWholePass').classList.toggle('hidden',!quote.active_bundle);
 const pair=cachedBundle(id),active=quote.active_bundle;
 const recover=active&&pair?.raw&&pair.request===active.request_id;
 $('benefitWholeInfo').textContent=active?(recover?`已生成 ${active.pass_count} 份 Game Pass，可找回原码。`:'已有整单 QR 待领取，请在原设备找回，或等到期后重新生成。'):`${quote.eligible_units} / ${quote.total_units} 份可分配。${state.luckyMode?.mode==='lucky'?(quote.note||'整单一个 Lucky Box，可分杯开箱'):'整单 QR 由一名会员一次领取。'}`;
 $('issueWholePass').textContent=recover?'重新显示整单 QR':`生成整单 QR${quote.eligible_units?' · '+quote.eligible_units+' 份':''}`;
 $('issueWholePass').disabled=!(recover||quote.can_issue)||(state.luckyMode?.mode==='off'&&!recover);
}
async function loadSelectedPaidUnits(preserveQR=false){
 const epoch=++benefitEpoch,id=$('benefitOrderSelect').value,root=$('benefitUnits');root.replaceChildren();state.benefitOrder=null;state.bundleQuote=null;if(!preserveQR)$('benefitQR').classList.add('hidden');$('issueWholePass').disabled=true;
 $('benefitWholeInfo').textContent=id?'正在核对可分配权益…':'请选择已付款订单。';
 if(!id){$('benefitQR').classList.add('hidden');$('cancelWholePass').classList.add('hidden');root.innerHTML='<div class="empty">请选择已付款订单。</div>';return;}
 const [units,quote]=await Promise.all([db.rpc(state.luckyMode?.mode==='lucky'?'yt_lucky_pos_paid_units':'yt_pos_paid_units',{p_order:id}),db.rpc(state.luckyMode?.mode==='lucky'?'yt_lucky_bundle_quote':'yt_pos_bundle_quote',{p_order:id})]);
 if(epoch!==benefitEpoch||id!==$('benefitOrderSelect').value)return;
 const result=unpack(units);state.benefitOrder=result;state.bundleQuote=unpack(quote);renderBundleQuote(id,state.bundleQuote);const shown=state.shownBenefit;if(preserveQR&&shown){const stillValid=shown.orderId===id&&Date.parse(shown.deadline)>Date.now()&&(shown.bundleId?state.bundleQuote.active_bundle?.id===shown.bundleId:result.units?.some(u=>u.game_pass_id===shown.passId&&u.pass_status==='issued'&&Date.parse(u.pass_expires_at)>Date.now()));if(!stillValid){$('benefitQR').classList.add('hidden');state.shownBenefit=null;}}
 if(!result.units?.length){root.innerHTML='<div class="empty">这个订单没有可以处理的单杯权益。</div>';return;}
 for(const unit of result.units){
  const ready=!unit.reward_redeemed&&unit.series_active&&['games','choose'].includes(unit.benefit_mode)&&Number(unit.game_plays)===1;
  const issued=!!unit.game_pass_id;
  const expired=issued&&(unit.pass_status==='expired'||(unit.pass_status==='issued'&&!!unit.pass_expires_at&&Date.parse(unit.pass_expires_at)<=Date.now()));
  const claimed=!!unit.reward_redeemed||(issued&&(unit.pass_status==='claimed'||unit.pass_status==='used'||unit.assigned));
  const key='yt-pos-v2-unit:'+unit.order_item_id+':'+unit.unit_number;
  let original=null;try{original=JSON.parse(sessionStorage.getItem(key)||'null')}catch{}
  const recover=issued&&unit.pass_status==='issued'&&!expired&&!claimed&&original;
  const card=document.createElement('div');card.className='order-note';
  const summary=document.createElement('div');summary.innerHTML=`<strong>${esc(unit.product_name)} · 第 ${unit.unit_number} 份</strong><small>单杯 ${money(unit.unit_price_rm)} · ${esc(unit.series_name||'未分配系列')}</small><small>${issued?'✓ 已生成 QR':ready?'可生成':'Owner 尚未配置可用权益规则'}</small>`;
  const btn=document.createElement('button');btn.type='button';btn.className='primary';
  btn.dataset.issueUnit='1';btn.dataset.item=unit.order_item_id;btn.dataset.unit=String(unit.unit_number);
  btn.textContent=unit.reward_redeemed?'已用于兑换奖励':claimed?'已领取':recover?'重新显示 QR':expired?'过期重发 QR':issued?'已发出':ready?'生成专属 QR':'不可发';
  btn.disabled=claimed||(issued&&!recover&&!expired)||(!issued&&!ready)||(state.luckyMode?.mode==='off'&&!recover);
  card.append(summary,btn);if(issued&&!expired&&!claimed&&unit.pass_status==='issued'){const cancel=document.createElement('button');cancel.type='button';cancel.className='quiet';cancel.textContent='取消未领取码';cancel.onclick=()=>cancelBenefitCode({pass:unit.game_pass_id,expiry:unit.pass_expires_at},cancel);card.append(cancel);}root.append(card);
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
async function showUnitQR(token,pass,unit,kind='claim'){
 const root=$('benefitQR');root.classList.remove('hidden');root.replaceChildren();clearInterval(state.benefitTimer);const deadline=pass?.expires_at||unit?.pass_expires_at;state.shownBenefit={orderId:$('benefitOrderSelect').value,passId:pass?.pass_id||unit?.game_pass_id,bundleId:kind==='bundle'?pass.id:null,deadline};
 const url=portalClientUrl();url.searchParams.set(kind,token);
 const title=document.createElement('h3');title.textContent=state.luckyMode?.mode==='lucky'?(kind==='bundle'?`整单 Lucky Box · ${pass.pass_count} 杯`:`${unit.product_name} · Lucky Box #${unit.unit_number}`):(kind==='bundle'?`整单 · ${pass.pass_count} 份 Game Pass`:`${unit.product_name} · 第 ${unit.unit_number} 份 QR`);
 const text=document.createElement('p');text.className='muted';text.textContent=state.luckyMode?.mode==='lucky'?(kind==='bundle'?'整单一个 Lucky Box · 扫码开箱后登录领取积分。':'一杯一箱 · 扫码开箱后登录领取积分。'):(kind==='bundle'?'由一名会员确认领取；领取后3天内有效。':`${money(unit.unit_price_rm)} · 每份独立领取，扫码后进入 Yetipsy Play。`);
 const square=document.createElement('div');square.className='qr-screen';
 const link=document.createElement('a');link.href=url.href;link.className='qr-link';link.textContent=url.href;link.target='_blank';link.rel='noreferrer';
 const copyBtn=document.createElement('button');copyBtn.type='button';copyBtn.className='quiet';copyBtn.textContent='复制领取链接';copyBtn.onclick=()=>navigator.clipboard?.writeText(url.href).then(()=>showNotice('已复制'));
 const badge=document.createElement('p');badge.className='help';badge.textContent='正在验证…';
 root.append(title,text,square,link,copyBtn,badge);
 let shown=false;if(await qrLibrary()){new window.QRCode(square,{text:url.href,width:206,height:206,colorDark:'#1d251f',colorLight:'#ffffff',correctLevel:window.QRCode.CorrectLevel.M});shown=true;}
 if(!shown)square.textContent='QR 图片暂不可用，可以复制上面的顾客领取链接。';
 try{let valid;if(state.luckyMode?.mode==='lucky'){valid=unpack(await db.rpc('yt_lucky_preview',{p_token:token,p_kind:kind}))?.valid;}else if(kind==='bundle'){valid=unpack(await db.rpc('yt_pos_bundle_preview',{p_token:token}))?.valid;}else{const response=await fetch(conf.url+'/functions/v1/yt-pin-auth',{
   method:'POST',headers:{'Content-Type':'application/json','apikey':conf.publishableKey},
   body:JSON.stringify({action:'preview',kind:'claim',token}),cache:'no-store'
  });const data=await response.json();valid=data.ok&&data.preview?.valid;}
  badge.textContent=valid?'✓ 可领取':
   '⚠ 此码无法领取。';
 }catch{badge.textContent='⚠ 无法验证，请检查网络。';}
 const validText=badge.textContent;const tick=()=>{if(!root.isConnected)return clearInterval(state.benefitTimer);const seconds=Math.max(0,Math.ceil((Date.parse(deadline)-Date.now())/1000));badge.textContent=seconds?validText+' · '+seconds+' 秒内确认领取':'二维码已过期，请刷新后重新发放';if(!seconds){square.classList.add('code-expired');clearInterval(state.benefitTimer);}};state.benefitTimer=setInterval(tick,1000);tick();root.scrollIntoView({behavior:'smooth',block:'center'});
}
async function cancelBenefitCode(code,button){await busy(button,async()=>{const reason=prompt('取消未领取二维码的原因','重新分配');if(reason===null)return;const id=$('benefitOrderSelect').value;unpack(await db.rpc('yt_pos_cancel_code',{p_pass:code.pass||null,p_bundle:code.bundle||null,p_reason:reason.trim(),p_expected_expiry:code.expiry||null}));if(code.bundle){try{sessionStorage.removeItem(bundleKey(id));}catch{}}clearInterval(state.benefitTimer);state.shownBenefit=null;$('benefitQR').classList.add('hidden');await loadBenefits(id);showNotice('未领取码已取消，当天可重新分配');}).catch(()=>{});}
async function issueWholePass(button){
 const orderId=$('benefitOrderSelect').value;if(!orderId||state.benefitOrder?.order_id!==orderId)throw Error('请先选择已付款订单');
 await busy(button,async()=>{
  const lucky=state.luckyMode?.mode==='lucky';const quote=unpack(await db.rpc(lucky?'yt_lucky_bundle_quote':'yt_pos_bundle_quote',{p_order:orderId}));let pair=cachedBundle(orderId);
  if(quote.active_bundle){if(pair?.raw&&pair.request===quote.active_bundle.request_id){await showUnitQR(pair.raw,quote.active_bundle,null,'bundle');return;}throw Error('active_order_bundle_exists');}
  if(state.luckyMode?.mode==='off')throw Error('gamepass_mode_disabled');
  if(!quote.can_issue)throw Error('no_eligible_bundle_units');if(pair?.id&&!quote.active_bundle){sessionStorage.removeItem(bundleKey(orderId));pair=null;}
  if(pair?.expires_at&&Date.parse(pair.expires_at)<=Date.now()){sessionStorage.removeItem(bundleKey(orderId));pair=null;}
  if(!pair){const mins=2,campaign=lucky?null:$('benefitCampaign').value;if(!lucky&&!campaign)throw Error('请先选择活动');if(!Number.isInteger(mins)||mins<1||mins>60)throw Error('QR 有效分钟为 1–60');pair={raw:crypto.randomUUID(),request:crypto.randomUUID(),campaign,mins};sessionStorage.setItem(bundleKey(orderId),JSON.stringify(pair));}
  const pass=unpack(await db.rpc(lucky?'yt_lucky_bundle_issue':'yt_pos_bundle_issue',lucky?{p_order:orderId,p_token:pair.raw,p_request:pair.
request,p_minutes:pair.mins}:{p_order:orderId,p_campaign:pair.campaign,p_token:pair.raw,p_request:pair.request,p_minutes:pair.mins}));
  pair={...pair,...pass};sessionStorage.setItem(bundleKey(orderId),JSON.stringify(pair));
  if(pass.status!=='issued'||Date.parse(pass.expires_at)<=Date.now()){sessionStorage.removeItem(bundleKey(orderId));throw Error('原码已领取或过期，请刷新后重新分配');}
  if($('benefitOrderSelect').value!==orderId)return;
  await loadSelectedPaidUnits();await showUnitQR(pair.raw,pass,null,'bundle');showNotice(`已生成整单 ${lucky?'Lucky Box':'Game Pass'} QR · ${pass.pass_count} 份`);
 }).catch(()=>{});
}
async function issuePaidUnit(itemId,unitNumber,button){const orderId=$('benefitOrderSelect').value;
 if(!orderId)throw Error('请先选择已付款订单');
 const unit=state.benefitOrder?.units?.find(x=>x.order_item_id===itemId&&x.unit_number===unitNumber);
 if(!unit)throw Error('商品已更新，请刷新');
 const key='yt-pos-v2-unit:'+itemId+':'+unitNumber;
 let pair=null;try{pair=JSON.parse(sessionStorage.getItem(key)||'null')}catch{}
 if(unit.game_pass_id&&pair?.raw&&unit.pass_status==='issued'&&unit.pass_expires_at&&Date.parse(unit.pass_expires_at)>Date.now()){await showUnitQR(pair.raw,null,unit);return;}
 if(state.luckyMode?.mode==='off')throw Error('gamepass_mode_disabled');
 if(unit.game_pass_id&&(unit.pass_status==='expired'||(unit.pass_status==='issued'&&unit.pass_expires_at&&Date.parse(unit.pass_expires_at)<=Date.now()))){pair=null;try{sessionStorage.removeItem(key)}catch{}}
 await busy(button,async()=>{
  const lucky=state.luckyMode?.mode==='lucky';const campaign=lucky?null:(pair?.campaign||$('benefitCampaign').value);
  const mins=2;
  if(!lucky&&!campaign)throw Error('请先选择活动');
  if(!Number.isInteger(mins)||mins<1||mins>60)throw Error('QR 有效分钟为 1–60');
  if(!pair){pair={raw:crypto.randomUUID(),request:crypto.randomUUID(),campaign};sessionStorage.setItem(key,JSON.stringify(pair));}
  const rows=unpack(await db.rpc(lucky?'yt_lucky_issue_unit_pass':'yt_pos_issue_unit_pass',{
   p_order:orderId,p_item:itemId,p_unit:unitNumber,...(lucky?{}:{p_campaign:campaign}),
   p_token:pair.raw,p_request:pair.request,p_minutes:mins
  }));
  if(!rows?.length)throw Error('服务器未发出领取码');
  await loadSelectedPaidUnits();
  if($('benefitOrderSelect').value===orderId)await showUnitQR(pair.raw,rows[0],unit);
  showNotice(`已生成 ${lucky?'Lucky Box':'Game Pass'} · ${unit.product_name}`);
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

async function lookupPOSRedeem(){const token=$('redeemToken').value;showTab('create');openCartDrawer();$('draftRedeemToken').value=token;await scanDraftReward();}
async function confirmPOSItemRedeem(){throw Error('pos_checkout_only');}
async function confirmPOSRedeem(){throw Error('pos_checkout_only');}
function stopDuitnowCamera(){if(state.duitnowProofStream){state.duitnowProofStream.getTracks().forEach(track=>track.stop());state.duitnowProofStream=null;}const video=$('duitnowProofVideo');if(video){video.pause?.();video.srcObject=null;video.classList.add('hidden');} $('duitnowCameraCapture')?.classList.add('hidden');const open=$('duitnowCameraOpen');if(open)open.textContent='打开相机拍照';}
function clearDuitnowProof(){stopDuitnowCamera();state.duitnowProofFile=null;if(state.duitnowProofUrl)URL.revokeObjectURL(state.duitnowProofUrl);state.duitnowProofUrl=null;const preview=$('duitnowProofPreview');if(preview){preview.removeAttribute('src');preview.classList.add('hidden');}const input=$('duitnowProofInput');if(input)input.value='';$('duitnowCameraRetake')?.classList.add('hidden');}
function setDuitnowProof(file){if(!file)return;if(!/^image\/(png|jpeg|webp)$/.test(file.type)||file.size>5*1024*1024)throw Error('交易截图需为 PNG/JPG/WEBP 且小于5MB');stopDuitnowCamera();state.duitnowProofFile=file;if(state.duitnowProofUrl)URL.revokeObjectURL(state.duitnowProofUrl);state.duitnowProofUrl=URL.createObjectURL(file);const preview=$('duitnowProofPreview');preview.src=state.duitnowProofUrl;preview.classList.remove('hidden');$('duitnowCameraRetake')?.classList.remove('hidden');showNotice(`已选择交易记录：${file.name||'现场拍摄'}`);}
async function openDuitnowCamera(){if(state.duitnowProofStream){stopDuitnowCamera();return;}if(!navigator.mediaDevices?.getUserMedia)throw Error('当前浏览器无法打开相机，请从相册选择交易记录');let stream;try{stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:{ideal:'environment'}},audio:false});state.duitnowProofStream=stream;const video=$('duitnowProofVideo');video.srcObject=stream;video.classList.remove('hidden');await video.play();$('duitnowCameraOpen').textContent='关闭相机';$('duitnowCameraCapture').classList.remove('hidden');}catch(error){stream?.getTracks().forEach(track=>track.stop());state.duitnowProofStream=null;throw Error(error.name==='NotAllowedError'?'请允许浏览器使用相机，或从相册选择交易记录':error.message||'相机暂时无法使用');}}
async function captureDuitnowPhoto(){const video=$('duitnowProofVideo');if(!state.duitnowProofStream||!video?.videoWidth)throw Error('相机尚未准备好，请稍候再拍');const scale=Math.min(1,1600/video.videoWidth),canvas=document.createElement('canvas');canvas.width=Math.round(video.videoWidth*scale);canvas.height=Math.round(video.videoHeight*scale);canvas.getContext('2d').drawImage(video,0,0,canvas.width,canvas.height);const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/jpeg',.84));if(!blob)throw Error('拍照失败，请重试');setDuitnowProof(new File([blob],`duitnow-proof-${Date.now()}.jpg`,{type:'image/jpeg'}));}
function stopRedeemCamera(){state.scanEpoch++;if(state.scanTimer){clearInterval(state.scanTimer);state.scanTimer=null;}if(state.scanStream){for(const t of state.scanStream.getTracks())t.stop();state.scanStream=null;}for(const id of ['redeemVideo','cartRedeemVideo','draftRedeemVideo']){const v=$(id);v.classList.add('hidden');v.srcObject=null;}if($('draftRedeemScan'))$('draftRedeemScan').textContent='扫码';stopDuitnowCamera();}
let qrDecoderPromise=null;
async function qrDecoder(){
 if(typeof BarcodeDetector!=='undefined'){try{const d=new BarcodeDetector({formats:['qr_code']});return async video=>{const rows=await d.detect(video);return rows[0]?.rawValue||null;};}catch{}}
 if(!window.jsQR){qrDecoderPromise??=new Promise((resolve,reject)=>{const s=document.createElement('script');s.src='https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js';const timer=setTimeout(()=>{s.remove();reject(Error('扫码组件加载失败，请粘贴兑奖码'));},8000);s.onload=()=>{clearTimeout(timer);resolve();};s.onerror=()=>{clearTimeout(timer);reject(Error('扫码组件加载失败，请粘贴兑奖码'));};document.head.append(s);}).catch(e=>{qrDecoderPromise=null;throw e;});await qrDecoderPromise;}
 const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d',{willReadFrequently:true});
 return video=>{if(!video.videoWidth)return null;const scale=Math.min(1,640/video.videoWidth);canvas.width=Math.round(video.videoWidth*scale);canvas.height=Math.round(video.videoHeight*scale);ctx.drawImage(video,0,0,canvas.width,canvas.height);const pixels=ctx.getImageData(0,0,canvas.width,canvas.height);return window.jsQR(pixels.data,canvas.width,canvas.height,{inversionAttempts:'attemptBoth'})?.data||null;};
}
async function startRedeemCamera(){
 if(state.scanStream){stopRedeemCamera();return;}if(state.currentTab!=='create'||state.selectedOrderCart)throw Error('请在点单购物车里扫码');if(state.pendingSubmit||state.draftSaving||state.draftMutating)return;
 if(!navigator.mediaDevices?.getUserMedia)throw Error('当前浏览器无法打开相机，请粘贴兑奖码');const epoch=++state.scanEpoch;const decode=await qrDecoder();if(epoch!==state.scanEpoch)return;
 let stream;try{stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:{ideal:'environment'}},audio:false});if(epoch!==state.scanEpoch){stream.getTracks().forEach(t=>t.stop());return;}state.scanStream=stream;const video=$('draftRedeemVideo');video.srcObject=stream;video.classList.remove('hidden');await video.play();$('draftRedeemScan').textContent='关闭相机';let reading=false;
 state.scanTimer=setInterval(async()=>{if(reading||!state.scanStream||epoch!==state.scanEpoch)return;reading=true;try{const raw=await decode(video);if(epoch===state.scanEpoch&&raw){$('draftRedeemToken').value=raw;stopRedeemCamera();await scanDraftReward();}}catch(e){stopRedeemCamera();showNotice(errorText(e),true);}finally{reading=false;}},350);
 }catch(e){if(stream)stream.getTracks().forEach(t=>t.stop());stopRedeemCamera();throw Error(e.name==='NotAllowedError'?'请允许相机权限，或粘贴兑奖码':e.message||'相机暂时无法使用');}
}
let editPreviousFocus=null;
function closeEditDialog(){if(state.editBusy)return;state.editOrder=null;state.editPreviewEpoch=(state.editPreviewEpoch||0)+1;$('editOverlay').classList.add('hidden');document.body.classList.remove('sheet-open');editPreviousFocus?.focus();}
function editItems(){return [...state.
editCart.values()].filter(v=>v.quantity>0).map(v=>({item_id:v.item_id||null,product_id:v.product_id,quantity:v.quantity,unit_price_rm:Number(v.unit_price_rm)}));}
function editControls(){const cashier=typeof isCashier==='function'&&isCashier(),owner=typeof isOwner==='function'&&isOwner(),locked=!!state.editPending||!!state.adjustmentPending||state.editBusy;for(const el of $('editSettlementForm').querySelectorAll('input,select,button'))el.disabled=!!state.editBusy||!!state.adjustmentPending;const settle=$('editSettlementSubmit');settle.disabled=!!state.editBusy;settle.textContent=state.adjustmentPending?'重试确认原款项':state.adjustmentBalance>0?'记录实际补收':'记录实际退款';for(const el of $('editForm').querySelectorAll('input,textarea,select,button'))el.disabled=locked;const b=$('editForm').querySelector('[type=submit]');b.disabled=!!state.editBusy||!!state.adjustmentPending||((owner||cashier)&&!state.editPending&&!state.editPreview);b.textContent=state.editPending?(cashier?'重试提交原申请':'重试确认原改单'):cashier?'提交 Owner 审批':'保存改单并留下记录';}
async function previewOwnerEdit(){if(!state.editOrder||(!isOwner()&&!isCashier())||state.editPending)return;const epoch=(state.editPreviewEpoch||0)+1;state.editPreviewEpoch=epoch;state.editPreview=null;$('editAmountSummary').textContent='正在核对修改金额…';editControls();
 try{const q=unpack(await db.rpc('yt_pos_owner_revision_preview',{p_order:state.editOrder.id,p_items:editItems(),p_cancel:$('editCancelOrder').checked}));if(epoch!==state.editPreviewEpoch||!state.editOrder)return;state.editPreview=q;$('editAmountSummary').innerHTML=revisionSummary(q,state.editOrder.payment_status==='paid');$('editSum').textContent=money(q.net);$('editBenefits').innerHTML=benefitSummary(q.benefits);}
 catch(e){if(epoch===state.editPreviewEpoch){$('editAmountSummary').textContent=errorText(e);state.editPreview=null;}}
 finally{if(epoch===state.editPreviewEpoch)editControls();}
}
function renderEditRows(){const root=$('editLineList');root.replaceChildren();let total=0;
 for(const [key,line] of state.editCart){const p=state.catalog.find(x=>x.id===line.product_id);if(!p)continue;const price=Number(line.unit_price_rm??p.price_rm);line.unit_price_rm=price;total+=price*line.quantity;
  const row=document.createElement('div');row.className='revision-line';
  const select=document.createElement('select');select.dataset.editProduct=key;select.setAttribute('aria-label','商品');
  for(const prod of state.catalog.filter(x=>x.active||x.id===line.product_id))select.add(new Option(prod.name+(prod.active?'':'（已停售）'),prod.id));select.value=line.product_id;
  const qty=document.createElement('input');qty.type='number';qty.min=0;qty.max=20;qty.value=line.quantity;qty.dataset.editQty=key;qty.setAttribute('aria-label','数量，0为移除');row.append(select,qty);
  if(isOwner()){const unit=document.createElement('input');unit.type='number';unit.min=0;unit.max=5000;unit.step='.01';unit.value=price;unit.dataset.editPrice=key;unit.setAttribute('aria-label','单价 RM');row.append(unit);}else{const label=document.createElement('span');label.textContent=money(price);row.append(label);}
  root.append(row);
 }$('editSum').textContent=money(total);if(isOwner()||isCashier())previewOwnerEdit();
}
function editDialogChange(input){if(state.editPending||state.editBusy||state.adjustmentPending)return;const key=input.dataset.editQty||input.dataset.editProduct||input.dataset.editPrice;const line=state.editCart.get(key);if(!line)return;
 if(input.dataset.editQty){const v=Number(input.value);if(!Number.isInteger(v)||v<0||v>20)throw Error('数量应为 0–20');if(v===0)state.editCart.delete(key);else line.quantity=v;}
 else if(input.dataset.editPrice){const v=Number(input.value);if(!Number.isFinite(v)||v<0||v>5000||Math.abs(v*100-Math.round(v*100))>.00001)throw Error('请输入有效的单价，最多两位小数');line.unit_price_rm=v;}
 else{line.product_id=input.value;line.unit_price_rm=Number(state.catalog.find(p=>p.id===input.value)?.price_rm||0);}
 state.editDirty=true;$('editSettlement').classList.add('hidden');renderEditRows();
}
function renderAdjustment(row){const balance=Number(row.balance_rm||0);state.adjustmentBalance=balance;$('editSettlement').classList.toggle('hidden',!isOwner()||row.payment_status!=='paid'||balance===0||!!state.editDirty);
 $('editSettlementTitle').textContent=balance>0?'待补收 '+money(balance):'待退款 '+money(-balance);$('editSettlementAmount').value=Math.abs(balance).toFixed(2);$('editSettlementAmount').max=Math.abs(balance).toFixed(2);$('editSettlementConfirmed').checked=false;$('editSettlementNote').value='';$('editSettlementMethod').value=row.payment_method&&['cash','duitnow','foodcourt','bank_transfer','card','other'].includes(row.payment_method)?row.payment_method:'duitnow';$('editSettlementConfirmText').textContent=balance>0?'确认已经实际收到这笔补款':'确认已经实际退回这笔款项';$('editSettlementSubmit').textContent=balance>0?'记录实际补收':'记录实际退款';
}
async function openEditDialog(id){let row;if(isOwner()||isCashier()){row=unpack(await db.rpc('yt_pos_owner_order_context',{p_order:id}));}else{row=state.active.find(x=>x.id===id);if(!row)throw Error('请先刷新现场订单');if(!state.identity.can_edit_orders)throw Error('order_edit_permission_required');}
 editPreviousFocus=document.activeElement;state.editOrder=row;state.editPending=null;state.adjustmentPending=null;state.editDirty=false;state.editBusy=false;state.editPreview=null;
 state.editCart=new Map((row.items||[]).map((i,n)=>['line-'+n,{item_id:i.id,product_id:i.product_id,quantity:i.quantity,unit_price_rm:Number(i.price_rm)}]));
 $('editTable').value=row.table_label||'';$('editNote').value=row.notes||'';$('editReason').value='';$('editRevokeBenefits').checked=false;$('editCancelOrder').checked=false;$('editOwnerOptions').classList.toggle('hidden',!isOwner());$('editCancelOptions')?.classList.toggle('hidden',!isCashier()&&!isOwner());$('editAmountSummary').classList.toggle('hidden',!isOwner()&&!isCashier());$('editRevisions').innerHTML=isOwner()?revisionHistory(row.revisions||[]):'';
 $('editHint').textContent=isOwner()?'左起：商品、数量、单价。数量设0可移除；款项需另外确认实际补收／退款。':isCashier()?'可申请修改或取消任意未退款订单；Owner 批准后才会生效，Cashier 不会直接改动账单。':'仅修改未付款、未出品订单；修改已接受订单后会按权限回到待审核。';
 $('editTitle').textContent=`改单 · ${row.order_no}`;renderEditRows();renderAdjustment(row);$('editOverlay').classList.remove('hidden');document.body.classList.add('sheet-open');$('editTable').focus();editControls();
}
async function submitEditOrder(e){e.preventDefault();const btn=$('editForm').querySelector('[type=submit]');if(state.editBusy)return;
 await busy(btn,async()=>{
  if(!state.editOrder)throw Error('请先选择订单');
  if(isOwner()){
   if(!state.editPending){await previewOwnerEdit();if(!state.editPreview)throw Error('请先核对修改金额');const balance=Number(state.editPreview.balance_rm);const paid=state.editOrder.payment_status==='paid';
    const description=paid?(balance>0?'需另行补收 '+money(balance):balance<0?'需另行退款 '+money(-balance):'款项已对齐'):'尚未收款';
    if(!confirm('确认保存改单？\n'+description+'\n'+($('editRevokeBenefits').checked?'撤销本单发出的权益':'保留本单发出的权益')))return;
    state.editPending={p_order:state.editOrder.id,p_items:editItems(),p_reason:$('editReason').value.trim(),p_table:$('editTable').value.trim()||null,p_note:$('editNote').value.trim()||null,p_expected_updated:state.editOrder.updated_at,p_request:crypto.randomUUID(),p_revoke:$('editRevokeBenefits').checked,p_cancel:$('editCancelOrder').checked};
   }
   state.editBusy
=true;editControls();let result;try{result=unpack(await db.rpc('yt_pos_owner_revision_apply',state.editPending));}catch(e){if(e.code)state.editPending=null;throw e;}finally{state.editBusy=false;editControls();}
   const id=state.editOrder.id;state.editPending=null;await refreshOrders(false);if(result.payment_status==='paid'&&Number(result.balance_rm)!==0){await openEditDialog(id);showNotice('改单已保存，请确认实际补收／退款');}else{closeEditDialog();showNotice('改单已保存，前后内容及权益选择已记录');}
  }else{
   if(isCashier()){
    if(!state.editPending){if(!state.editPreview)await previewOwnerEdit();if(!state.editPreview)throw Error('请先核对修改内容');if(!confirm($('editCancelOrder').checked?'确认提交整单取消申请给 Owner 审批？':'确认提交改单给 Owner 审批？'))return;state.editPending={p_order:state.editOrder.id,p_items:editItems(),p_reason:$('editReason').value.trim(),p_table:$('editTable').value.trim()||null,p_note:$('editNote').value.trim()||null,p_expected_updated:state.editOrder.updated_at,p_cancel:$('editCancelOrder').checked,p_request:crypto.randomUUID()};}
    state.editBusy=true;editControls();try{unpack(await db.rpc('yt_pos_owner_revision_request_submit',state.editPending));}finally{state.editBusy=false;editControls();}
    state.editPending=null;closeEditDialog();await refreshOrders(false);showNotice('改单申请已送交 Owner，批准前订单内容不会改变');return;
   }
   const counts=new Map();for(const v of state.editCart.values()){if(v.quantity)counts.set(v.product_id,(counts.get(v.product_id)||0)+v.quantity);}const items=[...counts].map(([product_id,quantity])=>({product_id,quantity}));if(!items.length)throw Error('请保留至少一个商品');if(!confirm('确认更改这张未付款订单？'))return;
   const result=unpack(await db.rpc('yt_pos_edit_order',{p_order:state.editOrder.id,p_items:items,p_reason:$('editReason').value.trim(),p_table:$('editTable').value.trim()||null,p_note:$('editNote').value.trim()||null,p_expected_updated:state.editOrder.updated_at}));closeEditDialog();await refreshOrders(false);showNotice(result.must_be_reaccepted?'改单成功，订单已回到待审核':'改单已保存');
  }
 }).catch(()=>{});if(state.editOrder)editControls();
}
async function submitAdjustment(e){e.preventDefault();const btn=e.submitter;await busy(btn,async()=>{
 if(state.editBusy)return;if(!isOwner()||!state.editOrder||!state.adjustmentBalance||state.editDirty)throw Error('请先保存改单');
 if(!state.adjustmentPending){const amount=Number($('editSettlementAmount').value);if(!$('editSettlementConfirmed').checked)throw Error('请先确认款项已经实际完成');if(!Number.isFinite(amount)||amount<=0||amount>Math.abs(state.adjustmentBalance)||Math.abs(amount*100-Math.round(amount*100))>.00001)throw Error('adjustment_exceeds_balance');if(!confirm('确认已经实际'+(state.adjustmentBalance>0?'收到':'退回')+' '+money(amount)+'？'))return;
  state.adjustmentPending={p_order:state.editOrder.id,p_amount:Math.sign(state.adjustmentBalance)*amount,p_method:$('editSettlementMethod').value,p_note:$('editSettlementNote').value.trim(),p_request:crypto.randomUUID()};
 }
 state.editBusy=true;editControls();let result;try{result=unpack(await db.rpc('yt_pos_adjustment_pay',state.adjustmentPending));}catch(e){if(e.code)state.adjustmentPending=null;throw e;}finally{state.editBusy=false;editControls();}
 const id=state.editOrder.id,wasRefund=state.adjustmentBalance<0;state.adjustmentPending=null;await refreshOrders(false);if(wasRefund)await playUpgrade.refundDecision(id);if(result.payment_status==='paid'&&Number(result.balance_rm)!==0)await openEditDialog(id);else closeEditDialog();showNotice('实际款项已记录，并计入当前营业日');
 }).catch(()=>{});if(state.editOrder)editControls();}

// POS V4 - Cart-integrated reward preflight. The 60-second Wallet QR only authenticates
// the reservation; actual user_rewards redemption is committed by DB checkout trigger.
function escapeOrderCart(){stopRedeemCamera();clearDuitnowProof();state.selectedOrderCart=null;cashierPackageQuote=null;cashierPackageOrder=null;state.activeRewardHold=null;
 $('orderCartOverlay').classList.add('hidden');document.body.classList.remove('sheet-open');}
async function openOrderCart(id){
 clearDuitnowProof();
 state.selectedOrderCart=id;cashierPackageQuote=null;cashierPackageOrder=null;state.activeRewardHold=null;state.duitnowQrLoaded=false;state.duitnowQrError=null;$('cartRedeemToken').value='';
 $('cartRedeemChoices').innerHTML='';$('orderCartClaims').replaceChildren();$('orderCartClaims').classList.add('hidden');$('orderCartOverlay').classList.remove('hidden');
 document.body.classList.add('sheet-open');await refreshOrderCart();
}
async function refreshOrderCart(){if(!state.selectedOrderCart)return;
 const id=state.selectedOrderCart,row=[...state.active,...state.pending,...state.paid].find(x=>x.id===id),ambassador=isAmbassadorOrder(row);
 const [receipt,summary]=await Promise.all([
  db.rpc('yt_pos_receipt',{p_order:id}),ambassador?Promise.resolve({data:null,error:null}):db.rpc('yt_pos_cart_summary',{p_order:id})]);
 const bill=unpack(receipt),q=ambassador?{order_no:row.order_no,gross_rm:row.amount_rm,reserved_discount_rm:0,payable_rm:row.amount_rm,unresolved_count:0,minimum_met:true,status:row.status,payment_status:row.payment_status,store_box_only:false,can_pay:row.payment_status==='unpaid',moon_codes:[],holds:[]}:unpack(summary);
 $('orderCartTitle').textContent='#'+(q.order_no||bill.order_no)+' · '+(ambassador?'Freeflow 收款':'优惠与结账');
 $('orderCartItems').innerHTML=(bill.items||[]).map(item=>`<div class="cart-preview-item"><strong>${esc(item.item_name)} × ${Number(item.quantity)}</strong><span>${money(item.quantity*item.unit_price_rm)}</span></div>`).join('');
 $('orderCartHolds').innerHTML=ambassador?'<p class="muted">Freeflow Pass 按实际人数计价，不叠加其他奖券。</p>':(q.moon_codes||[]).map(x=>'<div class="cart-discount-line"><div><strong>'+esc(x.reward_name||(x.kind==='R0'?'RM5 Voucher':x.kind==='R3'?'彩虹 Shot 赠品':x.kind==='R5'?'断片指南赠品':'微醺特调赠品'))+'</strong><small>'+esc(x.code)+' · 已预留，收款后核销</small></div><b>'+ (x.kind==='R0'?'−'+money(x.discount_rm||5):'FREE') +'</b><button type="button" class="quiet" data-moon-release="'+esc(x.id)+'">释放</button></div>').join('')+((q.holds||[]).length?q.holds.map(h=>`<div class="cart-discount-line"><div><strong>− ${esc(h.reward_name)}</strong><small>${h.can_checkout?'已预留':h.state==='reserved'?'待选择商品':'已超时'} · ${stamp(h.expires_at)}</small></div><b>−${money(h.discount_rm)}</b>${q.payment_status==='unpaid'?`<button type="button" class="quiet" data-release-hold="${esc(h.id)}">释放</button>`:''}</div>`).join(''):'<p class="muted">无预留奖励</p>');
 $('orderCartGross').textContent=money(q.gross_rm);
 $('orderCartDiscount').textContent='−'+money(q.reserved_discount_rm);
 $('orderCartPayable').textContent=money(q.payable_rm);
 $('orderCartStatus').textContent=ambassador?'POS 原价销售 · 收款后计入 Daily Sales 并结算佣金':q.unresolved_count?'请先处理奖励。':q.minimum_met===false?'需保留至少一杯付费饮品。':q.status==='pending'?'等待 Cashier 接单。':q.payment_status==='paid'&&q.status==='confirmed'?'已收款，订单仍在吧台 KDS 等待出品。':q.payment_status==='paid'?'已结账。':q.status==='confirmed'&&q.store_box_only?'可直接结账；完成后立即生成顾客领取码。':q.status==='confirmed'?'可先收款；订单仍会保留在吧台 KDS。':'可结账。';
 $('orderCartStatus').classList.toggle('warn',q.unresolved_count>0||q.minimum_met===false);
 $('cartRedeemForm').classList.add('hidden');
 if(ambassador){cashierPackageQuote=null;cashierPackageOrder=null;$('cashierPackagePrep').classList.add('hidden');}else await loadCashierPackagePrep(id,q);
 $('cartCheckoutControls').classList.toggle('hidden',!(isCashier()||isOwner()||isStaff())||q.payment_status==='paid');
 const proofPending=!ambassador&&state.duitnowProofs?.some(proof=>proof.order_id===id&&proof.status==='pending');
 const memberBinding=row?.member_binding,memberBindingBox=$('cartMemberBinding'),memberBindingStatus=$('cartMemberBindingStatus'),memberScan=$('cartMemberScan');
 const memberBindingEligible=!ambassador&&state.luckyMode?.mode==='off'&&q.payment_status==='unpaid';
 memberBindingBox?.classList.toggle('hidden',!memberBindingEligible);
 if(memberBindingEligible){const isBound=!!memberBinding?.member_binding;memberScan?.classList.toggle('hidden',isBound);memberScan?.setAttribute('data-play-member-scan',id);memberBindingStatus.textContent=isBound?'本单已绑定会员，结账后按实付金额处理积分。':'可在收款前扫描顾客会员码绑定本单。';}
 $('cartCheckoutBtn').disabled=!q.can_pay||proofPending;$('cartCheckoutBtn').textContent=proofPending?'DuitNow 已提交，等待 Cashier 确认':ambassador?'确认 Freeflow 收款':q.store_box_only?'收款并生成领取码':isStaff()&&$('cartCheckoutPayment').value==='duitnow'?'上传截图并提交 Cashier 确认':'确认收款并正式核销奖励';
 $('orderCartStatus').textContent=proofPending?'DuitNow 交易记录已提交，等待 Cashier 确认；如资料不符，Cashier 会拒绝并恢复为未付款。':$('orderCartStatus').textContent;
 await refreshDuitNowQr();
}
function renderDuitNowQr(){
 const panel=$('cashierDuitNowQr'),image=$('cashierDuitNowQrImage'),status=$('cashierDuitNowQrStatus'),proofField=$('duitnowProofField');if(!panel||!image||!status)return;
 const show=(isCashier()||isOwner()||isStaff())&&$('cartCheckoutPayment').value==='duitnow',requiresProof=isStaff()&&!isCashier()&&!isOwner();panel.classList.toggle('hidden',!show);proofField?.classList.toggle('hidden',!show||!requiresProof);if(!show)return;
 image.classList.toggle('hidden',!state.duitnowQrPath);image.onerror=()=>{image.classList.add('hidden');status.textContent='二维码暂时无法显示，请联系 Owner 检查上传文件。';};
 if(state.duitnowQrPath){image.src=db.storage.from('yetipsy-payment-qr').getPublicUrl(state.duitnowQrPath).data.publicUrl;status.textContent=requiresProof?'请顾客扫描此 DuitNow 二维码付款，然后拍照或上传交易记录；提交后由 Cashier 确认。':'请顾客扫描此 DuitNow 二维码；确认款项到账后再点击收款。';}else status.textContent=state.duitnowQrError||'Owner 尚未上传 DuitNow 收款二维码，请联系 Owner 设置。';
}
async function refreshDuitNowQr(){if(!(isCashier()||isOwner()||isStaff())||$('cartCheckoutPayment').value!=='duitnow'){renderDuitNowQr();return;}if(!state.duitnowQrLoaded){const status=$('cashierDuitNowQrStatus');if(status)status.textContent='正在读取收款二维码…';try{const settings=unpack(await db.rpc('yt_receipt_settings_get'));state.duitnowQrPath=settings?.duitnow_qr_path||null;state.duitnowQrError=null;}catch(error){state.duitnowQrError='无法读取收款二维码：'+errorText(error);state.duitnowQrPath=null;}state.duitnowQrLoaded=true;}renderDuitNowQr();}

async function moonGuestRelease(id){
 if(!window.confirm('释放这张 Moon 旧码？取消预留后顾客仍能再次使用。'))return;
 unpack(await db.rpc('yt_moon_release',{p_id:id}));
 await refreshOrderCart();await refreshOrders(false);showNotice('Moon 兑换码已释放');
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
 $('cartRedeemChoices').innerHTML=`<div class="redeem-banner success"><strong>✓ 已预留 ${esc(hold.reward_name)}</strong><p>优惠 −${money(result.discount_rm)}</p></div>`;
 state.activeRewardHold=null;await refreshOrderCart();await refreshOrders(false);
 if(result.added_to_cart)showNotice('赠送饮品已加入购物车，请再次确认出品完成后才能结账');
}
async function releaseCartHold(id){
 if(!window.confirm('撤销本单的奖励预留？顾客 Wallet 不会扣券。'))return;
 unpack(await db.rpc('yt_pos_cart_release',{p_hold:id}));
 state.activeRewardHold=null;$('cartRedeemChoices').replaceChildren();
 await refreshOrderCart();await refreshOrders(false);showNotice('已释放预留，顾客奖品仍可使用');
}
let cashierPackageQuote=null,cashierPackageOrder=null;
async function promptCashierPackagePrep(orderId){
 if(!(isCashier()||isOwner())||!orderId)return;
 const quote=unpack(await db.rpc('yt_store_box_checkout_prep_quote',{p_order:orderId}));
 if(!quote?.can_prepare||!quote?.items?.length)return;
 const saved=unpack(await db.rpc('yt_store_box_prep_intent_get',{p_order:orderId}));
 if(saved?.preps)return;
 const layer=document.createElement('section');layer.className='edit-overlay package-prep-prompt';layer.setAttribute('role','dialog');layer.setAttribute('aria-modal','true');layer.setAttribute('aria-labelledby','packagePrepPromptTitle');
 layer.innerHTML='<article class="card edit-dialog"><div class="block-head"><div><p class="kicker">PACKAGE / CHALLENGE · KDS PREP</p><h2 id="packagePrepPromptTitle">这单要先出几杯？</h2></div></div><p class="field-note">选择要立即排进 KDS 的杯数；剩余数量会保留在存酒箱。Challenge 固定先出 1 杯。</p><div id="packagePrepPromptItems"></div><button id="packagePrepPromptSave" class="main-button" type="button">确认预出数量</button></article>';
 const root=layer.querySelector('#packagePrepPromptItems');
 root.innerHTML=quote.items.map(item=>{const choices=(item.available||[]).map((part,index)=>{const max=Number(part.quantity||0),value=item.mode==='challenge'&&index===0?1:0;return '<label>'+esc(part.name)+' <small>最多 '+max+' 杯</small><input type="number" data-prep-item="'+esc(item.item_id)+'" data-prep-key="'+esc(part.key)+'" min="0" max="'+Math.min(99,max)+'" step="1" value="'+value+'" '+(item.mode==='challenge'?'readonly':'')+'></label>';}).join('');return '<article class="cashier-prep-item"><strong>'+esc(item.name)+' · '+(item.mode==='challenge'?'Challenge（固定 1 杯）':'Package')+'</strong><div class="cashier-prep-grid">'+choices+'</div><small>总量 '+Number(item.capacity)+' 杯 · 未预出部分进入存酒箱</small></article>';}).join('');
 document.body.append(layer);layer.querySelector('#packagePrepPromptSave').focus();
 await new Promise(resolve=>{layer.querySelector('#packagePrepPromptSave').onclick=async event=>{const button=event.currentTarget;if(button.disabled)return;button.disabled=true;button.textContent='正在保存…';try{
  const preps=quote.items.map(item=>{const selected=[...root.querySelectorAll('input[data-prep-item]')].filter(input=>input.dataset.prepItem===item.item_id);if(selected.some(input=>!Number.isInteger(Number(input.value))||Number(input.value)<0||Number(input.value)>Number(input.max)))throw Error('Package 出杯数量不正确');const selections=selected.map(input=>({key:input.dataset.prepKey,quantity:Number(input.value)})).filter(entry=>entry.quantity>0);const count=selections.reduce((sum,entry)=>sum+entry.quantity,0);if(item.mode==='challenge'&&count!==1)throw Error('challenge_one_cup_only');if(count>Number(item.capacity)||count>99)throw Error('store_box_quantity_unavailable');return {item_id:item.item_id,selections};});
  unpack(await db.rpc('yt_store_box_prep_intent_save',{p_order:orderId,p_preps:preps}));cashierPackageQuote=quote;cashierPackageOrder=orderId;for(const row of state.active||[])if(row.id===orderId)row.package_preps=preps;notifyKds();renderOrders();updateAlertDots();showNotice('预出杯数量已保存；已进入 KDS，剩余数量会留在存酒箱。');layer.remove();resolve();
 }catch(error){showNotice(errorText(error),true);button.disabled=false;button.textContent='确认预出数量';}};});
}
async function loadCashierPackagePrep(id,q){
 const panel=$('cashierPackagePrep'),root=$('cashierPackagePrepItems');
 if(!(isCashier()||isOwner())||q.payment_status!=='unpaid'){cashierPackageQuote=null;cashierPackageOrder=null;panel.classList.add('hidden');return;}
 const quote=unpack(await db.rpc('yt_store_box_checkout_prep_quote',{p_order:id}));
 if(state.selectedOrderCart!==id)return;
 cashierPackageQuote=quote;cashierPackageOrder=id;
 const items=quote.can_prepare?quote.items||[]:[];
 panel.classList.toggle('hidden',items.length===0);
 root.innerHTML=items.map(item=>{
  const choices=(item.available||[]).map((part,index)=>{
   const value=item.mode==='challenge'&&index===0?1:0,max=Number(part.quantity||0);
   return '<label>'+esc(part.name)+' <small>最多 '+max+' 杯</small><input type="number" data-prep-item="'+esc(item.item_id)+'" data-prep-key="'+esc(part.key)+'" min="'+value+'" max="'+Math.min(99,max)+'" step="1" value="'+value+'" '+(item.mode==='challenge'?'readonly':'')+'></label>';
  }).join('');
  return '<article class="cashier-prep-item"><strong>'+esc(item.name)+' · '+(item.mode==='challenge'?'挑战 · 仅先出 1 杯':'Package')+'</strong><div class="cashier-prep-grid">'+choices+'</div><small>此套餐共 '+Number(item.capacity)+' 杯 · 其余保留存酒箱</small></article>';
 }).join('');
 const saved=unpack(await db.rpc('yt_store_box_prep_intent_get',{p_order:id}));
 if(state.selectedOrderCart!==id)return;
 for(const input of root.querySelectorAll('input[data-prep-item]')){const prep=saved?.preps?.find(entry=>entry.item_id===input.dataset.prepItem);const selection=prep?.selections?.find(entry=>entry.key===input.dataset.prepKey);if(selection)input.value=String(selection.quantity);}
}
function cashierPackageSelections(){
 if(!cashierPackageQuote?.items?.length)return[];
 const all=[...$('cashierPackagePrepItems').querySelectorAll('input[data-prep-item]')];
 return cashierPackageQuote.items.map(item=>{
  const selected=all.filter(el=>el.dataset.prepItem===item.item_id);
  if(selected.some(el=>!Number.isInteger(Number(el.value))||Number(el.value)<0||Number(el.value)>Number(el.max)))throw Error('Package 出杯数量不正确');
  const selections=selected.map(el=>({key:el.dataset.prepKey,quantity:Number(el.value)})).filter(s=>s.quantity>0);
  const count=selections.reduce((sum,s)=>sum+s.quantity,0);
  if(item.mode==='challenge'&&count!==1)throw Error('challenge_one_cup_only');
  if(count>Number(item.capacity)||count>99)throw Error('store_box_quantity_unavailable');
  return {item_id:item.item_id,selections};
 });
}
async function checkoutOrderCart(){const btn=$('cartCheckoutBtn');await busy(btn,async()=>{
 if(!(isCashier()||isOwner()||isStaff()))throw Error('staff_only');
 const row=[...state.active,...state.paid].find(x=>x.id===state.selectedOrderCart),ambassador=isAmbassadorOrder(row);
 const q=ambassador?{can_pay:row.payment_status==='unpaid',payable_rm:row.amount_rm,reserved_discount_rm:0}:unpack(await db.rpc('yt_pos_cart_summary',{p_order:state.selectedOrderCart}));
 if(!q.can_pay)throw Error('coupon_hold_not_ready_or_expired');
 const method=$('cartCheckoutPayment').value;
 if(method==='duitnow'&&!isCashier()&&!isOwner()){
  const file=state.duitnowProofFile||$('duitnowProofInput')?.files?.[0];if(!file)throw Error('请先拍照或上传 DuitNow 交易记录');
  if(!/^image\/(png|jpeg|webp)$/.test(file.type)||file.size>5*1024*1024)throw Error('交易截图需为 PNG/JPG/WEBP 且小于5MB');
  const path=`proof/${state.selectedOrderCart}/${crypto.randomUUID()}.${file.type==='image/png'?'png':file.type==='image/webp'?'webp':'jpg'}`;
  const uploaded=await db.storage.from('yetipsy-payment-proof').upload(path,file,{contentType:file.type,cacheControl:'60',upsert:false});if(uploaded.error)throw uploaded.error;
  let submitted;try{submitted=unpack(await db.rpc('yt_pos_duitnow_proof_submit',{p_order:state.selectedOrderCart,p_path:path}));}catch(error){await db.storage.from('yetipsy-payment-proof').remove([path]).catch(()=>{});throw error;}
  await refreshOrders(false);state.duitnowProofs=[...(state.duitnowProofs||[]),{order_id:state.selectedOrderCart,status:'pending'}];clearDuitnowProof();await refreshOrderCart();showNotice(`${submitted.order_no||'订单'} 的 DuitNow 记录已提交，等待 Cashier 确认。`);return;
 }
 if(!window.confirm(`确认已实际收到 ${money(q.payable_rm)}？\n收款方式：${method.toUpperCase()}${method==='duitnow'?'\n请先确认 DuitNow 款项已到账。':''}${ambassador?'\nFreeflow Male / Female 将按 POS 销售入账，并计入 Ambassador 佣金。':'\n本单优惠：−'+money(q.reserved_discount_rm)+'\n确认后才正式核销所有预留奖励，此动作不能随意撤销。'}`))return;
 const prepEnabled=!ambassador&&cashierPackageOrder===state.selectedOrderCart&&!!cashierPackageQuote?.items?.length;
 const result=unpack(await db.rpc(prepEnabled?'yt_pos_checkout_with_prep':'yt_pos_action',
  prepEnabled?{p_order:state.selectedOrderCart,p_method:method,p_preps:cashierPackageSelections()}:
  {p_order:state.selectedOrderCart,p_action:'paid',p_method:method,p_reason:null}));
 await refreshOrders(false);await refreshOrderCart();
 if(result.cashier_managed_packages){showNotice('已收款，Package / Challenge 已由 Cashier 排进 KDS，无需顾客扫码');}
 else if(result.store_box_claims?.length){await showCheckoutStoreBoxClaims(result.store_box_claims
);showNotice('已结账，顾客领取码已生成');}
 else showNotice(ambassador?'Freeflow 销售与 AB 收款已登记，佣金已记入 Ambassador。':'Foodcourt／Cashier 收款已登记，奖券已随结账正式核销');
 }).catch(()=>{});}
async function showCheckoutStoreBoxClaims(claims){
 const root=$('orderCartClaims');root.replaceChildren();root.classList.remove('hidden');
 const heading=document.createElement('h3');heading.textContent='请顾客扫码领取';root.append(heading);
 const ready=await qrLibrary();
 for(const claim of claims){const card=document.createElement('article');card.className='storebox-checkout-claim';
  const title=document.createElement('strong');title.textContent=claim.name||'Package／挑战';
  const meta=document.createElement('small');meta.textContent=`${Number(claim.total_units||0)}${claim.unit_label||'杯'} · 2分钟内领取`;
  const square=document.createElement('div');square.className='qr-screen';const url=portalClientUrl();url.searchParams.set('box',claim.claim_token);
  if(ready)new window.QRCode(square,{text:url.href,width:206,height:206,colorDark:'#1d251f',colorLight:'#fff',correctLevel:window.QRCode.CorrectLevel.M});else square.textContent='二维码载入失败，请到存酒箱重新显示。';
  card.append(title,meta,square);root.append(card);
 }
 root.scrollIntoView({behavior:'smooth',block:'center'});
}
// Compact Owner issuance: only rewards with an active SKU/series binding are selectable.
async function loadOwnerRewardOffers(){
 if(!isOwner())return;
 const eligible=(state.rewardRules||[]).filter(r=>r.active&&['product','series','any_drink'].includes(r.mode));
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
 if(!until||new Date(until+':00+08:00').getTime()<=Date.now()+60000)throw Error('设置有效的领取截止时间');
 const token=crypto.randomUUID();
 const cap=Number($('ownerGiftTotal').value);if(!Number.isInteger(cap)||cap<1||cap>10000)throw Error('数量需为 1–10000');
 const offer=unpack(await db.rpc('yt_create_offer_v5',{
  p_reward:reward,p_token:token,p_from:$('ownerGiftFrom')?.value?$('ownerGiftFrom').value+':00+08:00':new Date().toISOString(),p_until:until+':00+08:00',
  p_max:cap,p_per_user:Number($('ownerGiftPerUser')?.value||1)
 }));
 const link=portalClientUrl();link.searchParams.set('gift',token);
 const root=$('ownerGiftLink');root.replaceChildren();root.classList.remove('hidden');
 const t=document.createElement('strong');t.textContent='Reward Claim · 顾客可扫码，或在客户端输入领取短码';
 const qr=document.createElement('div');qr.className='qr-screen';const code=document.createElement('strong');code.textContent=offer.display_code;code.className='claim-short-code';
 const copy=document.createElement('button');copy.type='button';copy.className='quiet';copy.textContent='复制领取码';copy.onclick=()=>navigator.clipboard.writeText(offer.display_code).then(()=>showNotice('领取短码已复制')).catch(()=>showNotice('请手动复制上方领取码',true));
 const expiry=document.createElement('p');expiry.className='muted';expiry.textContent='领取截止：'+stamp(offer.expires_at);root.append(t,qr,code,copy,expiry);
 if(await qrLibrary())new window.QRCode(qr,{text:link.href,width:204,height:204});
 else qr.textContent='二维码图片暂时无法加载，请使用下方领取短码。';
 showNotice('已创建 Reward Claim，奖励绑定规则将在 POS 结账时验证');
 }).catch(()=>{});}
function startPolling(){stopPolling();state.interval=setInterval(()=>{if(state.activeView==='dashboard'){refreshOrders(true);if(state.currentTab==='benefits'&&!state.benefitLoading){state.benefitLoading=true;loadBenefits(null,true).catch(()=>{}).finally(()=>{state.benefitLoading=false;});}if(state.currentTab==='storebox')storeBox?.loadStaff(true).catch(()=>{});playUpgrade.poll();}},6500);}
function stopPolling(){if(state.interval){clearInterval(state.interval);state.interval=null;}}
const customPricing=createCustomPricing({db,isOwner,isCashier,notice:(message,bad)=>showNotice(message,bad),onAddProduct:async d=>{if(!state.catalog.some(x=>x.id===d.product_id))state.catalog.push({id:d.product_id,name:d.name,price_rm:d.price_rm,active:true,category:'CUSTOM',is_drink:true});state.cart.set(d.product_id,(state.cart.get(d.product_id)||0)+1);saveDraft();await refreshDraftSummary();}});
function bind(){
 customPricing.init();
 if(!$('editCancelOptions'))$('editOwnerOptions')?.insertAdjacentHTML('beforebegin','<div id="editCancelOptions" class="hidden"></div>');
 $('noticeDismiss')?.addEventListener('click',()=>{$('notice').classList.add('hidden');clearTimeout(state.noticeTimer);});
 document.addEventListener('pointerdown',unlockAudio,{once:true});
 $('signinForm').addEventListener('submit',e=>{unlockAudio();login(e).catch(()=>{});});window.YT_WORK_READY=true;
 $('paidDateForm').onsubmit=e=>{e.preventDefault();refreshOrders(false);};$('paidToday').onclick=async()=>{try{const c=unpack(await db.rpc('yt_business_context'));state.businessDay=c.day;$('paidDate').value=c.day;if($('kdsHistoryDate'))$('kdsHistoryDate').value=c.day;await refreshOrders(false);}catch(e){showNotice(errorText(e),true);}};
 if($('kdsHistoryForm'))$('kdsHistoryForm').onsubmit=e=>{e.preventDefault();loadKdsHistory();};if($('kdsHistoryRefresh'))$('kdsHistoryRefresh').onclick=()=>loadKdsHistory();$('kdsHistoryDetails')?.addEventListener('toggle',()=>{if($('kdsHistoryDetails').open&&state.kdsHistoryDay!==$('kdsHistoryDate').value)loadKdsHistory();});
 storeBox=createStoreBox({db,ownerRoot:$('storeBoxOwnerRoot'),staffRoot:$('storeBoxStaffRoot'),orderRoot:$('storeBoxOrderQueue'),isOwner,isCashier,isCashierAccount:()=>state.identity?.role==='cashier',notice:(message,bad)=>showNotice(errorText(Error(message)),bad),getBusinessDay:()=>state.businessDay,onQueueChange:updateStoreBoxQueue});
 if(document.body.dataset.unified==='true')consoleUI=createConsole({db,work,isOwner,isOwnerLimited,isCashier,loadAdmin,loadOffers:loadOwnerRewardOffers,loadRights,loadStoreBoxOwner:()=>storeBox.loadOwner(),notice:(message,bad)=>showNotice(errorText(Error(message)),bad),getBusinessDay:()=>state.businessDay,onOwnerEdit:openEditDialog,onOrdersChanged:()=>refreshOrders(false),onReset:async(scopes)=>{
  stopPolling();if(scopes?.includes('records')){state.cart.clear();state.pendingSubmit=null;state.draftSummary=null;for(let i=sessionStorage.length-1;i>=0;i--){const key=sessionStorage.key(i);if(key?.startsWith('yt-pos-'))sessionStorage.removeItem(key);}}
  showNotice('所选范围已重置',false,true);location.reload();
 }});
  $('firstPasswordForm').onsubmit=changeCashierFirstPassword;$('firstPasswordBack').onclick=()=>{db.auth.signOut().finally(resetLogin);};
 $('logout').onclick=async()=>{saveDraft();stopRedeemCamera();stopPolling();if(db)await db.auth.signOut();resetLogin();};
 $('searchProduct').oninput=renderCatalog;$('categoryProduct').onchange=renderCatalog;
 $('categoryProductButtons').onclick=e=>{const b=e.target.closest('button[data-category]');if(!b)return;$('categoryProduct').value=b.dataset.category;renderCatalog();};
 $('catalog').onclick=e=>{const btn=e.target.closest('[data-add]');if(btn)adjustCart(btn.dataset.add,1);};
 $('cartRows').onclick=e=>{const amb=e.target.closest('[data-amb-dec],[data-amb-inc],[data-amb-remove]');if(amb){if(amb.dataset.ambRemove!==undefined){state.ambassadorDraft=null;saveDraft();renderCart();return;}adjustAmbassadorCart(amb.dataset.ambInc||amb.dataset.ambDec,amb.dataset.ambInc?1:-1);return;}const btn=e.target.closest('[data-dec],[data-inc]');if(btn)adjustCart(btn.dataset.dec||btn.dataset.inc,btn.dataset.inc?1:-1);};
 $('createOrderBtn').onclick=()=>createOrder();
 $('draftRedeemCheck').onclick=()=>scanDraftReward().catch(()=>{});$('draftRedeemScan').onclick=()=>startRedeemCamera().catch(e=>showNotice(errorText(e),true));$('draftRefresh').onclick=()=>refreshDraftSummary().catch(e=>showNotice(errorText(e),true));$('draftRewardRows').onclick=e=>{const b=e.target.closest('[data-release-draft]');if(b)releaseDraftReward(b.dataset.releaseDraft).catch(()=>{});};$('draftRedeemToken').onkeydown=e=>{if(e.key==='Enter'&&!$('draftRedeemCheck').disabled){e.preventDefault();scanDraftReward().catch(()=>{});}};$('tableInput').oninput=saveDraft;$('orderNote').oninput=saveDraft;$('checkoutPayNow').onchange=()=>{saveDraft();updateCreateHint();};$('checkoutPayLater').onchange=()=>{saveDraft();updateCreateHint();};
 $('cartDock').onclick=openCartDrawer;$('cartShade').onclick=closeCartDrawer;$('cartCloseBtn').onclick=closeCartDrawer;
 $('cashierDirect').onchange=()=>{saveDraft();updateCreateHint();};
 $('refreshPending').onclick=()=>refreshOrders(false);$('refreshDuitNowProofs')?.addEventListener('click',()=>loadDuitNowProofs(false));$('duitnowProofList')?.addEventListener('click',handleDuitNowProofAction);$('refreshOrders').onclick=()=>refreshOrders(false);$('refreshUnpaid').onclick=()=>refreshOrders(false);$('refreshHistory').onclick=()=>refreshOrders(false);
 $('jumpPending').onclick=()=>showTab('pending');
 $('ownerDashboardRefresh').onclick=()=>loadOwnerDashboard(true).catch(e=>showNotice(errorText(e),true));
 document.body.addEventListener('click',e=>{const b=e.target.closest('button[data-action][data-order]');if(b)orderAction(b.dataset.order,b.dataset.action,b);});
 $('productForm').onsubmit=saveProduct;$('clearProduct').onclick=clearProduct;
 $('productAdminList').onclick=e=>{const copy=e.target.closest('[data-copy-product]');if(copy){copyProduct(copy.dataset.copyProduct);return;}const b=e.target.closest('[data-product]');if(b)editProduct(b.dataset.product);};
 $('staffRights').onchange=e=>{const cashier=e.target.closest('input[data-cashier]');if(cashier)changeRight(cashier.dataset.cashier,cashier.checked,cashier);const edit=e.target.closest('input[data-edit-staff]');if(edit)changeEditRight(edit.dataset.editStaff,edit.checked,edit);};
  $('seriesForm').onsubmit=saveSeries;
  $('seriesList').onclick=e=>{const b=e.target.closest('[data-series]');if(b)editSeries(b.dataset.series);};
  $('benefitOrderSelect').onchange=()=>loadSelectedPaidUnits().catch(e=>showNotice(errorText(e),true));
  $('cancelWholePass').onclick=e=>{if(state.bundleQuote?.active_bundle)cancelBenefitCode({bundle:state.bundleQuote.active_bundle.id},e.currentTarget);};$('refreshBenefits').onclick=()=>loadBenefits().catch(e=>showNotice(errorText(e),true));
  $('benefitUnits').onclick=e=>{const b=e.target.closest('[data-issue-unit]');if(b)issuePaidUnit(b.dataset.item,Number(b.dataset.unit),b).catch(()=>{});};
  $('benefitWholeMode').onclick=()=>benefitMode('whole');$('benefitSingleMode').onclick=()=>benefitMode('single');$('issueWholePass').onclick=()=>issueWholePass($('issueWholePass')).catch(e=>showNotice(errorText(e),true));
  $('redeemLookup').onclick=()=>lookupPOSRedeem().catch(e=>showNotice(errorText(e),true));
  $('redeemScanCamera').onclick=()=>startRedeemCamera().catch(e=>showNotice(errorText(e),true));
  $('redeemCheck').onclick=e=>{const b=e.target.closest('[data-confirm-redeem]');if(b)confirmPOSRedeem(b).catch(()=>{});const u=e.target.closest('[data-pos-redeem]');if(u)confirmPOSItemRedeem(u).catch(()=>{});};
  document.body.addEventListener('click',e=>{const summary=e.target.closest('[data-order-benefit-summary]');if(summary){toggleOrderBenefitSummary(summary).catch(error=>showNotice(errorText(error),true));return;}const receipt=e.target.closest('[data-receipt]');if(receipt)viewReceipt(receipt.dataset.receipt).catch(e=>showNotice(errorText(e),true));
   const edit=e.target.closest('[data-edit]');if(edit)openEditDialog(edit.dataset.edit).catch(e=>showNotice(errorText(e),true));
   const benefit=e.target.closest('[data-benefits]');if(benefit)showTab('benefits',benefit.dataset.benefits);});
  $('editClose').onclick=closeEditDialog;$('editForm').onsubmit=submitEditOrder;$('editSettlementForm').onsubmit=submitAdjustment;$('editCancelOrder').onchange=()=>{state.editDirty=true;$('editSettlement').classList.add('hidden');previewOwnerEdit();};$('editRevokeBenefits').onchange=()=>{state.editDirty=true;$('editSettlement').classList.add('hidden');};
 $('receiptClose').onclick=closeReceipt;$('receiptPrint').onclick=()=>window.print();$('receiptOverlay').onclick=e=>{if(e.target===$('receiptOverlay'))closeReceipt();};
 $('rewardModeCreate').onclick=()=>setRewardEditorMode('create');$('rewardModeEdit').onclick=()=>setRewardEditorMode('edit');$('mapReward').onchange=()=>{if($('mapReward').value)setRewardEditorMode('edit',{rewardId:$('mapReward').value});};$('mapMode').onchange=toggleMapInputs;$('mapDiscountType').onchange=toggleMapInputs;$('ownerNewRewardForm').onsubmit=saveOwnerReward;$('cancelRewardEdit').onclick=cancelRewardEdit;
 $('rewardMappingList').onclick=e=>{const edit=e.target.closest('[data-reward-edit]'),copy=e.target.closest('[data-reward-copy]');if(edit){setRewardEditorMode('edit',{rewardId:edit.dataset.rewardEdit});$('mapReward').scrollIntoView({behavior:'smooth',block:'center'});}else if(copy){copyRewardToEditor(copy.dataset.rewardCopy);$('ownerNewRewardForm').scrollIntoView({behavior:'smooth',block:'center'});}};
 $('resetPinForm').onsubmit=preparePinReset;document.querySelectorAll('[data-go-tab]').forEach(b=>b.onclick=()=>showTab(b.dataset.goTab));
 document.addEventListener('keydown',e=>{if(e.key==='Tab'&&!$('editOverlay').classList.contains('hidden')){const list=[...$('editOverlay').querySelectorAll('button,input,select,textarea,summary')].filter(x=>!x.disabled&&x.getClientRects().length);const first=list[0],last=list.at(-1);if(e.shiftKey&&document.activeElement===first){e.preventDefault();last?.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus();}}if(e.key==='Escape'){if(!$('editOverlay').classList.contains('hidden')){if(!state.editBusy&&!state.editPending&&!state.adjustmentPending)closeEditDialog();return;}if(document.body.classList.contains('cart-open'))closeCartDrawer();else if(!$('orderCartOverlay').classList.contains('hidden'))escapeOrderCart();else if(!$('receiptOverlay').classList.contains('hidden'))closeRec
eipt();}});
  $('editLineList').onchange=event=>{const inp=event.target.closest('[data-edit-qty],[data-edit-product],[data-edit-price]');if(inp)editDialogChange(inp);};
  $('editAddProduct').onclick=()=>{const p=state.catalog.find(p=>p.active);if(p){state.editCart.set(crypto.randomUUID(),{product_id:p.id,quantity:1,unit_price_rm:Number(p.price_rm)});state.editDirty=true;$('editSettlement').classList.add('hidden');renderEditRows();}};
 $('orderCartClose').onclick=escapeOrderCart;
 $('orderCartOverlay').onclick=e=>{if(e.target===$('orderCartOverlay'))escapeOrderCart();};
 $('cartReserveBtn').onclick=reserveInCart;
 $('cartScanCamera').onclick=()=>startRedeemCamera().catch(e=>showNotice(errorText(e),true));
 $('cartCheckoutBtn').onclick=checkoutOrderCart;$('cartCheckoutPayment').onchange=()=>{clearDuitnowProof();renderDuitNowQr();refreshDuitNowQr();if(state.selectedOrderCart)refreshOrderCart().catch(e=>showNotice(errorText(e),true));};$('duitnowProofInput')?.addEventListener('change',()=>{try{setDuitnowProof($('duitnowProofInput').files?.[0]);}catch(error){clearDuitnowProof();showNotice(errorText(error),true);}});$('duitnowCameraOpen')?.addEventListener('click',()=>openDuitnowCamera().catch(error=>showNotice(errorText(error),true)));$('duitnowCameraCapture')?.addEventListener('click',event=>busy(event.currentTarget,captureDuitnowPhoto).catch(()=>{}));$('duitnowCameraRetake')?.addEventListener('click',()=>{clearDuitnowProof();openDuitnowCamera().catch(error=>showNotice(errorText(error),true));});
 $('orderCartHolds').onclick=e=>{const moon=e.target.closest('button[data-moon-release]');if(moon){moonGuestRelease(moon.dataset.moonRelease).catch(error=>showNotice(errorText(error),true));return;}const b=e.target.closest('button[data-release-hold]');if(b)releaseCartHold(b.dataset.releaseHold).catch(err=>showNotice(errorText(err),true));};
 $('ownerSendGift').onclick=ownerDirectGift;$('ownerIssueGiftQR').onclick=ownerGiftClaimQR;
 document.body.addEventListener('click',e=>{const prep=e.target.closest('[data-order-prep]');if(prep){promptCashierPackagePrep(prep.dataset.orderPrep).catch(err=>showNotice(errorText(err),true));return;}const btn=e.target.closest('[data-order-cart]');if(btn)openOrderCart(btn.dataset.orderCart).catch(err=>showNotice(errorText(err),true));});

 document.addEventListener('visibilitychange',()=>{if(document.visibilityState!=='visible')stopRedeemCamera();if(document.visibilityState==='visible'&&state.activeView==='dashboard')refreshOrders(true);});
}
async function boot(){bind();playUpgrade.bindOrderClicks();window.YT_WORK_READY=true;if(!usable){resetLogin();showNotice('请检查 /play/config.js，POS 尚未连上 Supabase',true,true);return;}
 const {data,error}=await db.auth.getSession();if(!error&&data?.session){try{await launch();return;}catch(e){showNotice('请重新登录工作账号：'+errorText(e),true);}}
 resetLogin();}
boot().catch(e=>{window.YT_WORK_READY='failed';resetLogin();showNotice(errorText(e),true,true);});

