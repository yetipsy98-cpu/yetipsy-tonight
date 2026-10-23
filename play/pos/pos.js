import {createPlayWork} from './play-upgrade.js?v=20261016-refresh-settings-v1';
import {isRefreshWindowOpen} from './refresh-schedule.mjs?v=20261016-refresh-settings-v1';
import {revisionSummary,benefitSummary,revisionHistory} from './owner-order-edit.js?v=20261010-copy-v15-4';
import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';
import {createCustomPricing} from './custom-pricing.js?v=20261016-cart-visible-delete-v1';
import {createBannerManager} from '../owner-banners.js?v=20261017-banner-create-mode-v1';
import {createConsole} from './console.js?v=20261020-receipt-compact-v3';
import {applyReceiptLayout} from './receipt-layout.js?v=20261020-receipt-compact-v3';
import {createOwnerOrderApprovals} from './owner-order-approvals.js?v=20261023-one-code-adjustment-v1';
import {createStoreBox} from './store-box.js?v=20261020-storebox-expiry-void-kds-fold-v1&layout=drink-name-v1';
import {createAmbassadorTools} from './ambassador.js?v=20261023-ambassador-short-ref-v1';

// Yetipsy POS V1. Order creation and payment transitions always execute on Supabase.
// The browser never chooses product prices or changes a paid status directly.
const $=id=>document.getElementById(id);
const POLL_CLOCK_TICK_MS=5000;
let lastOwnerApprovalCountPollAt=0;
const conf=window.YETIPSY_PLAY_CONFIG||{};
const portal='work';
// Keep an existing Cashier login when all entry points adopt the shared workspace.
try{if(!localStorage.getItem('yt-work-session-v1')&&localStorage.getItem('yt-cashier-session-v2'))localStorage.setItem('yt-work-session-v1',localStorage.getItem('yt-cashier-session-v2'));localStorage.removeItem('yt-cashier-session-v2');}catch{}
const usable=/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(conf.url||'')&&/^sb_publishable_/.test(conf.publishableKey||'');
const db=usable?createClient(conf.url,conf.publishableKey,{auth:{storageKey:'yt-work-session-v1',persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}}):null;
const workURL=(conf.url||'')+'/functions/v1/yt-work-auth';
const state={identity:null,catalog:[],cart:new Map(),currentTab:'benefits',
  active:[],paid:[],pending:[],revisionRequests:[],seenPending:new Set(),seenInitialized:false,seenKds:new Set(),seenKdsInitialized:false,storeBoxQueue:[],seenStoreBox:new Set(),seenStoreBoxInitialized:false,ambassadorAccess:false,ambassadorDraft:null,
  currentRequestId:null,refreshing:false,interval:null,refreshSchedule:null,lastAutoPollAt:0,noticeTimer:null,activeView:'login',
  series:[],rewardRules:[],editOrder:null,editCart:new Map(),redeemPending:null,scanStream:null,scanTimer:null,luckyMode:null,luckyModeLoadedAt:0,
  selectedOrderCart:null,activeRewardHold:null,ownerMemberList:[],draftId:null,draftSummary:null,draftEpoch:0,draftLoading:false,draftSaving:false,draftMutating:false,draftSelection:null,pendingSubmit:null,scanEpoch:0,
  ownerDashboard:null,ownerDashboardDay:null,ownerDashboardLoading:false,duitnowQrPath:null,duitnowQrLoaded:false,duitnowQrError:null,kdsHistory:null,kdsHistoryDay:null,kdsHistoryLoading:false,duitnowProofFile:null,duitnowProofUrl:null,duitnowProofStream:null,duitnowProofs:[],authUserId:null};
const msgMap={game_points_already_used:'本单积分已花费或到期，不能撤销；可保留权益后改单',benefits_current_day_only:'只能分配当前营业日订单的 GamePass',pass_already_claimed:'顾客已领取，不能取消或再次发码',pass_changed_reload:'二维码已更新，请刷新后再取消',invalid_pass_cancellation:'请填写至少两个字的取消原因',default_campaign_not_available:'默认活动需已开放并包含可用游戏',order_not_editable:'该订单已取消或退款，不能再次改单',invalid_revision_price:'单价需为0至5000，最多两位小数',issued_reward_already_redeemed:'关联奖励已经核销，不能撤销；可关闭撤销选项保留权益',issued_reward_locked:'关联奖励已锁在其他订单，请先释放后再撤销',issued_points_balance_insufficient:'会员积分余额不足，不能撤回；可保留权益并记录人工处理',invalid_adjustment_payment:'请填写有效金额、收退款方式及说明',adjustment_exceeds_balance:'金额超过当前待补收／退款余额，请刷新核对',order_payment_adjustment_pending:'本单还有补收／退款未完成，暂不能发 GamePass',pass_revoked:'这次游戏权益已由 Owner 撤销',aged_order_owner_required:'这张订单已超过72小时，需要 Owner 批准处理',aged_orders_block_day_close:'有超过72小时未完成的订单，Owner 处理后才能完成 Closing',invalid_cutoff:'请选择有效的截止时间',invalid_business_day:'营业日日期不正确',day_close_changed_reload:'收款或订单状态已变化，请刷新 Daily Statement 后再确认',business_day_already_closed:'本营业日已经完成 Closing',day_close_note_required:'有未完成款项时请填写 Closing 备注',cash_out_exceeds_expected:'现金记录不正确',invalid_day_close:'Daily Statement 内容无效，请刷新后重试',business_day_not_closed:'本营业日尚未完成 Closing',order_not_unpaid:'该订单已经处理，请刷新',invalid_reset_scope:'请先选择有效的清空范围，旧页面请刷新后再试',reset_scope_conflict:'本次确认的范围已经锁定，请取消后重新选择',active_order_bundle_exists:'这张订单已有整单 QR，请从原设备找回，或等待到期',no_eligible_bundle_units:'这张订单没有尚可分配的 Game Pass',bundle_request_conflict:'发码请求不一致，请刷新核对',reset_confirmation_expired:'本次重置确认已过期，请从第一次密码确认重新开始',reset_cleanup_pending:'上一次重置的账号清理尚未完成，请继续清理',reset_cleanup_failed:'旧账号或广告文件清理暂未完成，请稍后重试',invalid_reset_request:'重置确认无效，请重新开始',short_code_invalid_or_expired:'兑换码不正确或已过期，请顾客重新生成',short_code_rate_limited:'输入次数过多，请一分钟后再试，或扫描二维码',minimum_paid_drink_required:'最低付费饮品数需为 0–20 杯；0 表示无需购买',minimum_one_paid_drink:'请按奖励设置补足最低付费饮品数',minimum_purchase_not_met:'请按奖励设置补足最低付费饮品数或最低消费金额',cart_requires_paid_drink:'请添加产品，或使用最低付费饮品为 0 的奖励',ambassador_clear_cart_first:'请先清空普通购物车，再单独核销 Ambassador Pass',ambassador_pass_not_found:'找不到有效的 Ambassador Pass',ambassador_pass_not_valid_today:'此 Pass 只在预约营业日有效',cannot_redeem_own_pass:'不能核销自己签发的 Pass',ambassador_prices_not_configured:'Owner 尚未完成这天的 Freeflow 男女价格设置',invalid_guest_count:'请填写至少一位顾客',token_invalid_rescan_wallet:'兑奖码已失效，请让顾客在 Wallet 重新生成',reward_reserved_by_another_order:'这份奖励已锁定在另一张订单，请先取消原订单',draft_already_submitted:'这份购物车已提交，请到订单页面核对',paid_cart_item_already_discounted:'这杯已经使用其他优惠，请选择另一杯',paid_cart_item_missing:'原优惠饮品已不在购物车，请移除奖励后重新选择',cart_price_changed_rescan:'商品价格已变化，请移除奖励并重新扫码',preorder_coupon_not_ready_or_expired:'奖励未选好或已过期，请移除后重新扫码',too_many_cart_rewards:'单笔最多使用二十份奖励',staff_only:'需要有效员工账号',cashier_only:'需要 Cashier 权限',backdate_approval_pending:'等待 Owner 批准营业日回填后才能收款',custom_code_not_found:'找不到订制二维码，请刷新顾客的订制码',custom_reprice_required:'材料价格已更新，请重新计价后再下单',custom_reprice_cancelled:'请完成重新计价后再提交订单',custom_material_unavailable:'材料已停用或不存在，请刷新后重试',custom_quote_below_cost:'订制报价不能低于材料成本',custom_name_invalid:'订制饮品名称需填写 2–100 个字',custom_recipe_invalid:'请至少选择一种材料并检查材料数量',not_authenticated:'登录已过期，请重新登录',
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
Object.assign(msgMap,{only_one_code_per_order:'每张订单只能使用一个兑换码，请先移除当前兑换码。',manual_adjustment_cannot_combine_code:'已使用兑换码的订单不能再申请 FOC 或 Discount。',foc_item_required:'请选择要申请 FOC 的饮品。',discount_invalid:'请输入有效的折扣金额或百分比。',adjustment_zero_total:'FOC / Discount 不能把订单金额减到 RM0.00。',adjustment_request_pending:'这张购物车已有待审批申请，请先查看申请记录。',adjustment_price_changed:'商品价格已变化，请重新开单并提交申请。',adjustment_request_not_found:'找不到这项申请，请刷新 Owner 审批列表。',invalid_adjustment_request:'申请资料不正确，请检查后重试。',rejection_note_required:'拒绝申请时请填写原因。'});
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const money=v=>'RM'+Number(v||0).toFixed(2);
const stamp=v=>v?new Intl.DateTimeFormat('zh-MY',{timeZone:'Asia/Kuala_Lumpur',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'}).format(new Date(v)):'—';
const unpack=r=>{if(r?.error){const e=Error(r.error.message||r.error.code||'server_unavailable');e.code=r.error.code;throw e;}return r.data};
const errorText=e=>{let s=String(e?.message||e||'server_unavailable');if(s==='member_binding_window_closed')return '订单付款已超过 24 小时，不能再补绑积分。';if(/yt pos payment entries method check/i.test(s))return '付款方式未被系统识别，这笔收款没有完成。请先刷新订单核对付款状态，再重试；不要连续重复收款。';return msgMap[s]||s.replaceAll('_',' ')};
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
 playUpgrade.mount();buildNav();consoleUI?.roleChanged();if(typeof createAmbassadorTools==='function'){globalThis.ytAmbassadorTools?.destroy();globalThis.ytAmbassadorTools=createAmbassadorTools({db,isOwner,isCashier,role:()=>state.identity?.role,notice:(message,bad)=>showNotice(message,bad),onRedeemPass:token=>scanAmbassadorPass(token),onClosePage:tab=>showTab(tab||defaultTab()),onAccessChange:enabled=>{state.ambassadorAccess=enabled;if(state.identity){buildNav();if(!enabled&&state.currentTab==='ambassador')showTab(defaultTab());}}});}
 if(typeof isOwnerLimited==='function'&&isOwnerLimited()){ensureLimitedHome();showTab('limited');await loadLimitedReports();return;}
 restoreDraft();try{const mode=await db.rpc('yt_lucky_public_mode');if(mode.error)throw mode.error;state.luckyMode=unpack(mode);}catch{state.luckyMode={mode:'game'};}state.luckyModeLoadedAt=Date.now();buildNav();const context=unpack(await db.rpc('yt_business_context'));state.businessDay=context.day;$('paidDate').value=context.day;if($('kdsHistoryDate'))$('kdsHistoryDate').value=context.day;if($('orderBusinessDay')){$('orderBusinessDay').max=context.day;$('orderBusinessDayControl')?.classList.toggle('hidden',!(isOwner()||isCashier()));if(!$('orderBusinessDay').value)$('orderBusinessDay').value=context.day;}await Promise.all([loadCatalog(),refreshOrders(false),loadRefreshSchedule()]);showTab(new URL(location.href).searchParams.get('tab')||defaultTab());startPolling();
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
 if(isOwner()||isCashier())tabs.push(['custompricing','订制计价']);
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
function productionRows(){return (state.active||[]).filter(row=>row.status==='confirmed'&&!isAmbassadorOrder(row)&&!['pending','approved'].includes(row.backdate_approval_status)&&productionItems(row).some(item=>!item.fulfilled));}
function unpaidRows(){return (state.active||[]).filter(row=>row.payment_status==='unpaid'&&(row.status==='fulfilled'||row.status==='confirmed'));}
function updateAlertDots(){const pending=isCashier()&&Number(state.pending?.length)>0,kds=productionRows().length+Number(state.storeBoxQueue?.length),unpaid=unpaidRows().length;const orders=[...($('nav')?.querySelectorAll?.('button')||[])].find(button=>button.dataset.tab==='orders'),pendingTab=$('orderPendingTab'),activeTab=[...($('orderTabs')?.querySelectorAll?.('button')||[])].find(button=>button.dataset.goTab==='orders'),unpaidTab=$('orderUnpaidTab');orders?.classList.toggle('has-alert',pending||kds||unpaid);pendingTab?.classList.toggle('has-alert',pending);activeTab?.classList.toggle('has-alert',kds>0);unpaidTab?.classList.toggle('has-alert',unpaid>0);}
function renderKdsEmpty(){const count=productionRows().length+Number(state.storeBoxQueue?.length);$('kdsCount').textContent=String(count);$('kdsEmpty').classList.toggle('hidden',count>0);}
function updateStoreBoxQueue(rows){const list=rows||[],ids=new Set(list.map(row=>row.request_id));if(state.seenStoreBoxInitialized){const added=list.filter(row=>!state.seenStoreBox.has(row.request_id));const audibleCalls=added.filter(row=>row.request_source!=='cashier_checkout');if(audibleCalls.length){showNotice(`🔔 收到 ${audibleCalls.length} 个存酒箱叫酒请求`,false,true);announceNewOrder();}}state.storeBoxQueue=list;state.seenStoreBox=ids;state.seenStoreBoxInitialized=true;renderKdsEmpty();updateAlertDots();}
function showTab(tab,orderId=null){
 if(limitedRole()&&!['limited','insights','ambassador'].includes(tab))tab='limited';
 if(tab==='insights'&&limitedRole())tab='limited';
 if(tab==='more')tab=isOwner()?'admin':'benefits';
 if(tab==='redeem')tab='create';

 if(!['create','pending','orders','unpaid','history','approvals','benefits','storebox','ambassador','bell','redeem','reset','admin','limited','custompricing'].includes(tab)||(tab==='pending'&&!isCashier())||(tab==='approvals'&&!isOwner())||(tab==='admin'&&!isOwner())||(tab==='limited'&&!limitedRole())||(tab==='ambassador'&&!state.ambassadorAccess&&!limitedRole())||(tab==='custompricing'&&!isOwner()&&!isCashier()))tab=defaultTab();
 $('accountMenu').open=false;
 if(tab==='reset'&&consoleUI){consoleUI.open('pin');return;}
 if(tab!=='create'){closeCartDrawer();stopRedeemCamera();}if(tab!=='redeem')globalThis.ytAmbassadorTools?.pause?.();state.currentTab=tab;
 for(const section of ['create','pending','orders','unpaid','history','approvals','benefits','storebox','ambassador','bell','redeem','reset','admin','limited','custompricing'])$('tab-'+section)?.classList.toggle('hidden',section!==tab);
 const orderView=['pending','orders','unpaid','history','approvals'].includes(tab);$('orderTabs').classList.toggle('hidden',!orderView);
 for(const b of $('orderTabs').querySelectorAll('button'))b.classList.toggle('active',b.dataset.goTab===tab);
 for(const b of $('nav').querySelectorAll('button'))b.classList.toggle('active',b.dataset.tab===tab||(orderView&&b.dataset.tab==='orders'));
 if(tab==='admin'&&!consoleUI)loadAdmin().then(loadOwnerRewardOffers).catch(e=>showNotice(errorText(e),true));
 if(tab==='admin')loadOwnerDashboard().catch(e=>showNotice(errorText(e),true));
 if(tab==='admin')playUpgrade.mapRefresh();
 if(tab==='custompricing')customPricing?.open().catch(e=>showNotice(errorText(e),true));
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
 try{const oldKey=`yt-pos-v5-draft:cashier:${state.identity?.username||''}`;if(state.identity?.role==='cashier'&&!sessionStorage.getItem(draftKey())&&sessionStorage.getItem(oldKey)){sessionStorage.setItem(draftKey(),sessionStorage.getItem(oldKey));sessionStorage.removeItem(oldKey);}const d=JSON.parse(sessionStorage.getItem(draftKey())||'null');if(d?.draftId){state.draftId=d.draftId;state.cart=new Map(d.items||[]);for(const x of d.customProducts||[])if(x?.id&&!state.catalog.some(p=>p.id===x.id))state.catalog.push({...x,active:true,category:'CUSTOM',is_drink:true});state.ambassadorDraft=d.ambassador||null;state.draftSelection=d.selection||null;state.pendingSubmit=d.pending||null;$('tableInput').value=d.table||'';$('orderNote').value=d.note||'';if($('orderBusinessDay'))$('orderBusinessDay').value=(d.items?.length||d.ambassador||d.pending)?(d.businessDay||''):'';const mode=state.pendingSubmit?.p_checkout_mode||'pay_now';$('checkoutPayNow').checked=mode==='pay_now';$('checkoutPayLater').checked=mode!=='pay_now';if(state.pendingSubmit)$('cashierDirect').checked=state.pendingSubmit.p_channel==='cashier';}}catch{}
}
function saveDraft(){if(!state.identity)return;try{sessionStorage.setItem(draftKey(),JSON.stringify({draftId:state.draftId,items:[...state.cart],customProducts:[...state.cart.keys()].map(id=>state.catalog.find(p=>p.id===id&&p.category==='CUSTOM')).filter(Boolean),ambassador:state.ambassadorDraft,selection:state.draftSelection,pending:state.pendingSubmit,table:$('tableInput').value,note:$('orderNote').value,businessDay:$('orderBusinessDay')?.value||state.businessDay,checkoutMode:$('checkoutPayNow').checked?'pay_now':'pay_later'}));}catch{}}
function updateDraftControls(){
 const locked=state.draftSaving||!!state.pendingSubmit,mutating=state.draftMutating;
 $('createOrderBtn').textContent=state.draftSaving?'正在提交…':state.pendingSubmit?'重试确认原订单 →':'提交订单 →';
 const zeroPurchaseFree=!state.cart.size&&!state.ambassadorDraft&&state.draftSummary?.can_submit&&(state.draftSummary?.holds||[]).some(h=>h.valid&&h.state==='chosen'&&h.discount_type==='free');
 $('createOrderBtn').disabled=state.draftSaving||mutating||(!state.pendingSubmit&&(state.draftLoading||(!state.cart.size&&!state.ambassadorDraft&&!zeroPurchaseFree)||!state.draftSummary?.can_submit));
 for(const id of ['tableInput','orderNote','cashierDirect','checkoutPayNow','checkoutPayLater','orderBusinessDay'])if($(id))$(id).disabled=locked;
 const noScan=locked||mutating||state.draftLoading||state.draftSummary?.holds?.some(h=>h.state==='pending');
 $('draftRedeemCheck').disabled=!!noScan;$('draftRedeemScan').disabled=locked||mutating;$('draftRedeemToken').disabled=locked||mutating;
 for(const b of $('draftRewardRows').querySelectorAll('button'))b.disabled=locked||mutating;
 for(const b of $('draftRewardChoices').querySelectorAll('button'))b.disabled=locked||mutating;
 if(state.pendingSubmit&&!state.draftSaving)$('draftStatus').textContent='提交状态待确认。点击重试会核对原订单，不会重复开单。';
 const adjustmentReady=(isCashier()||isOwner())&&state.cart.size>0&&!state.ambassadorDraft&&!state.draftSummary?.holds?.length&&!locked&&!mutating;
 $('manualAdjustmentActions')?.classList.toggle('hidden',!adjustmentReady);
 if($('focRequestBtn'))$('focRequestBtn').textContent=isOwner()?'直接执行 FOC':'申请 FOC';
 if($('discountRequestBtn'))$('discountRequestBtn').textContent=isOwner()?'直接执行 Discount':'申请 Discount';
 $('cashierAdjustmentHistoryDetails')?.classList.toggle('hidden',state.identity?.role!=='cashier');
}
let manualAdjustmentKind=null;
function openManualAdjustment(kind){
 if((!isCashier()&&!isOwner())||!state.cart.size||state.ambassadorDraft)return;
 if(state.draftSummary?.holds?.length){showNotice(isOwner()?'先移除兑换码，再执行 FOC 或 Discount。':'先移除兑换码，再申请 FOC 或 Discount。',true);return;}
 manualAdjustmentKind=kind;
 const ownerDirect=isOwner();
 const gross=[...state.cart].reduce((sum,[id,qty])=>sum+Number(state.catalog.find(p=>p.id===id)?.price_rm||0)*qty,0);
 $('manualAdjustmentTitle').textContent=ownerDirect?(kind==='foc'?'直接执行 FOC':'直接执行 Discount'):(kind==='foc'?'申请 FOC':'申请 Discount');
 $('manualAdjustmentSummary').textContent=ownerDirect?`购物车原价 RM${gross.toFixed(2)} · 确认后直接建立订单；当前营业日订单进入 KDS。`:`购物车原价 RM${gross.toFixed(2)} · Owner 批准后才会建立订单；当前营业日订单进入 KDS。`;
 $('manualAdjustmentFields').innerHTML=kind==='foc'?'<fieldset class="manual-adjustment-items"><legend>选择要免单的饮品（按整项数量）</legend>'+[...state.cart].map(([id,qty])=>{const p=state.catalog.find(x=>x.id===id);return `<label class="checkline"><input type="checkbox" value="${esc(id)}" data-foc-product> <span>${esc(p?.name||'饮品')} × ${qty} · RM${(Number(p?.price_rm||0)*qty).toFixed(2)}</span></label>`;}).join('')+'</fieldset>':'<div class="manual-discount-fields"><label>折扣类型<select id="manualDiscountType"><option value="rm">RM 金额</option><option value="percent">百分比</option></select></label><label>折扣值<input id="manualDiscountValue" type="number" min="0.01" step="0.01" required placeholder="输入金额或百分比"></label></div><p class="field-note">系统按订单金额计算折扣；最终应收至少保留 RM0.01。</p>';
 $('manualAdjustmentKicker').textContent=ownerDirect?'OWNER DIRECT ACTION':'CASHIER REQUEST';$('manualAdjustmentReason').value='';$('manualAdjustmentReason').placeholder=ownerDirect?'填写操作原因，方便之后查账':'请填写原因，Owner 审批时会看到';$('manualAdjustmentReasonLabel').textContent=ownerDirect?'操作原因':'申请原因';
 $('manualAdjustmentSubmit').textContent=ownerDirect?'确认并建立订单':'提交 Owner 审批';$('manualAdjustmentOverlay').classList.remove('hidden');$('manualAdjustmentReason').focus();
}
function closeManualAdjustment(){$('manualAdjustmentOverlay')?.classList.add('hidden');manualAdjustmentKind=null;}
async function submitManualAdjustment(event){event.preventDefault();if(!manualAdjustmentKind||state.draftSaving)return;const reason=$('manualAdjustmentReason').value.trim();if(reason.length<2){showNotice('请填写申请原因。',true);return;}
 for(const [id] of state.cart){const product=state.catalog.find(x=>x.id===id&&x.category==='CUSTOM');if(product?.share_token){const current=await customPricing.scan('CUSTOM:'+product.share_token);if(current?.cancelled)throw Error('custom_reprice_cancelled');if(current&&Number(current.price_rm)!==Number(product.price_rm)){Object.assign(product,current,{active:true,category:'CUSTOM',is_drink:true});renderCart();const gross=[...state.cart].reduce((sum,[key,qty])=>sum+Number(state.catalog.find(x=>x.id===key)?.price_rm||0)*qty,0);$('manualAdjustmentSummary').textContent=`订制饮品已重新计价。当前购物车原价 RM${gross.toFixed(2)}，请核对后再次${isOwner()?'执行':'提交申请'}。`;showNotice(`订制饮品价格已更新，请核对后再次${isOwner()?'执行':'提交申请'}。`,true);return;}}}
 const payload={kind:manualAdjustmentKind,draft_id:state.draftId,items:draftItems(),table_label:$('tableInput').value.trim(),order_note:$('orderNote').value.trim(),checkout_mode:$('checkoutPayNow').checked?'pay_now':'pay_later',business_day:$('orderBusinessDay')?.value||state.businessDay,reason};
 if(manualAdjustmentKind==='foc')payload.foc_product_ids=[...$('manualAdjustmentFields').querySelectorAll('[data-foc-product]:checked')].map(x=>x.value);
 else{payload.discount_type=$('manualDiscountType').value;payload.discount_value=$('manualDiscountValue').value;}
 state.draftSaving=true;$('manualAdjustmentSubmit').disabled=true;updateDraftControls();
 try{const ownerDirect=isOwner();const result=unpack(await db.rpc(ownerDirect?'yt_pos_owner_adjustment_execute':'yt_pos_cashier_adjustment_submit',{p_request:crypto.randomUUID(),p_payload:payload}));closeManualAdjustment();state.cart.clear();state.draftId=crypto.randomUUID();state.draftSummary=null;state.draftSelection=null;$('tableInput').value='';$('orderNote').value='';if($('orderBusinessDay'))$('orderBusinessDay').value=state.businessDay||'';$('checkoutPayNow').checked=true;$('checkoutPayLater').checked=false;$('draftRewardChoices').replaceChildren();saveDraft();renderCart();showNotice(ownerDirect?`FOC / Discount 已执行，订单 ${result?.order_no?'#'+result.order_no:''} 已建立。`:'申请已发送给 Owner；批准后才会建立订单并进入 KDS。');if(!ownerDirect&&$('cashierAdjustmentHistoryDetails').open)loadCashierAdjustmentHistory().catch(()=>{});}
 finally{state.draftSaving=false;$('manualAdjustmentSubmit').disabled=false;updateDraftControls();}
}
async function loadCashierAdjustmentHistory(){if(state.identity?.role!=='cashier')return;const root=$('cashierAdjustmentHistory');root.innerHTML='<div class="empty">正在读取申请记录…</div>';const rows=unpack(await db.rpc('yt_pos_cashier_adjustment_requests_mine'))||[];root.innerHTML=rows.length?rows.map(x=>`<article class="order"><div class="order-head"><div><h3>${x.kind==='foc'?'FOC 申请':'Discount 申请'} · ${esc(x.status==='pending'?'待 Owner 审批':x.status==='approved'?'已批准':'已拒绝')}</h3><small>${stamp(x.created_at)}${x.order_no?' · 订单 #'+esc(x.order_no):''}</small></div><strong>${money(x.net_rm)}</strong></div><p>原价 ${money(x.gross_rm)} · 优惠 ${money(x.adjustment_rm)}</p>${x.review_note?`<p>Owner 备注：${esc(x.review_note)}</p>`:''}</article>`).join(''):'<div class="empty">还没有 FOC / Discount 申请。</div>';}

function renderCart(){let count=0,total=0;const rows=[];const hideBackdate=!(isOwner()||isCashier())||Boolean(state.ambassadorDraft);$('orderBusinessDayControl')?.classList.toggle('hidden',hideBackdate);$('orderBusinessDayControl')?.parentElement?.classList.toggle('order-meta-single',hideBackdate);
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
 if(!state.cart.size){$('draftStatus').textContent='正在核对奖励的消费条件…';}
 state.draftLoading=true;updateDraftControls();$('draftStatus').textContent='正在核对购物车…';
 try{
  const q=unpack(await db.rpc('yt_moon_preorder_summary',{p_draft:state.draftId,p_cart:draftItems()}));if(epoch!==state.draftEpoch)return null;
  if((q.holds||[]).length>1){q.can_submit=false;q.unresolved_count=Number(q.unresolved_count||0)+1;q.error_code='only_one_code_per_order';}
  state.draftSummary=q;
  $('draftRedeemCount').textContent=q.holds?.length?`${q.holds.length} 项已加入`:'扫描奖励码 / Moon / 订制 QR';$('draftRewardRows').innerHTML=(q.holds||[]).map(h=>`<div class="draft-reward-row"><div><strong>${esc(h.reward_name)}</strong><small>${h.valid?'已选好 · 下单后锁码':h.state==='pending'?'请选择适用饮品':'选择已失效，请移除后重新扫码'}${h.chosen_product_name?' · '+esc(h.chosen_product_name)+(h.discount_type==='free'?'（赠饮）':''):''}</small></div><b>−${money(h.discount_rm)}</b><button type="button" class="quiet" data-release-draft="${esc(h.id)}">移除</button></div>`).join('');
  $('draftGross').textContent=money(q.gross_rm);$('draftDiscount').textContent='−'+money(q.reserved_discount_rm);$('cartTotal').textContent=money(q.payable_rm);$('cartDockTotal').textContent=money(q.payable_rm);
  $('draftStatus').textContent=q.error_code==='only_one_code_per_order'?'每张订单只能使用一个兑换码，请先移除多余兑换码。':q.unresolved_count?'请先处理奖励。':!q.can_submit?'请按奖励设置补足付费饮品或最低消费。':!state.cart.size&&!q.holds?.length?'可扫码；是否需要消费由奖励设置决定。':q.holds?.length?'奖励已加入。':'可以提交。';
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
function isAmbassadorToken(raw){const text=String(raw||'').trim();if(/^YTAMB\s*:/i.test(text)||/^ambassador:/i.test(text)||/^[0-9a-f]{10}$/i.test(text))return true;try{return new URL(text).searchParams.has('amb');}catch{return false;}}
async function scanAmbassadorPass(raw){
 if(state.cart.size||state.ambassadorDraft)throw Error('ambassador_clear_cart_first');
 const p=unpack(await db.rpc('yt_ambassador_pos_pass_lookup',{p_token:raw}));
 const root=$('ambassadorCheckinPanel');if(!root)throw Error('Ambassador 核销选择框未加载，请刷新点单页面');state.draftSelection=null;root.classList.remove('hidden');root.innerHTML=`<article class="redeem-banner"><strong>Freeflow · ${esc(p.ambassador_name||'Ambassador')}</strong><p>${esc(p.reservation_day)} · 已核销 ${Number(p.checked_pax||0)} 位 / 预登记 ${Number(p.planned_pax||0)} 位</p>${Number(p.checked_pax||0)>Number(p.planned_pax||0)?'<p>已超过预登记人数；仍可继续核销，请确认实际人数。</p>':''}${p.guest_name?`<small>${esc(p.guest_name)}${p.guest_phone?' · '+esc(p.guest_phone):''}</small>`:''}<div class="cart-redeem-choices"><label>男士 ${money(p.male_price)}<input id="ambassadorMaleCount" type="number" min="0" max="500" step="1" value="0" aria-label="Freeflow 男士人数"></label><label>女士 ${money(p.female_price)}<input id="ambassadorFemaleCount" type="number" min="0" max="500" step="1" value="0" aria-label="Freeflow 女士人数"></label></div><p id="ambassadorPassQuote">合计 RM0.00</p><p id="ambassadorPassWarning" role="status"></p><button class="primary" id="ambassadorPassCreate" type="button">加入购物车</button></article>`;root.scrollIntoView({behavior:'smooth',block:'start'});
 const total=()=>Number($('ambassadorMaleCount').value||0)*Number(p.male_price||0)+Number($('ambassadorFemaleCount').value||0)*Number(p.female_price||0);
 const update=()=>{$('ambassadorPassQuote').textContent='合计 '+money(total());};
 const planned=Number(p.planned_pax||0),checked=Number(p.checked_pax||0),warn=()=>{
  const next=Number($('ambassadorMaleCount').value||0)+Number($('ambassadorFemaleCount').value||0),host=$('ambassadorPassWarning');
  if(host)host.textContent=checked+next>planned?`提醒：本次后累计 ${checked+next} 位，超过预登记 ${planned} 位；仍可继续核销。`:'';
 };
 $('ambassadorMaleCount').oninput=()=>{update();warn();};$('ambassadorFemaleCount').oninput=()=>{update();warn();};
 $('ambassadorPassCreate').onclick=()=>busy($('ambassadorPassCreate'),async()=>{
  const m=Number($('ambassadorMaleCount').value||0),f=Number($('ambassadorFemaleCount').value||0);if(!Number.isInteger(m)||!Number.isInteger(f)||m<0||f<0||m+f<1||m+f>500)throw Error('invalid_guest_count');
  state.ambassadorDraft={token:p.pass_code,pass_id:p.pass_id,pass_code:p.pass_code,reservation_day:p.reservation_day,ambassador_name:p.ambassador_name,commission_rate:Number(p.commission_rate||0),male:m,female:f,male_price:Number(p.male_price),female_price:Number(p.female_price),planned_pax:planned,checked_pax:checked,guest_name:p.guest_name,guest_phone:p.guest_phone};
  state.draftSelection=null;$('draftRedeemToken').value='';root.replaceChildren();root.classList.add('hidden');saveDraft();renderCart();openCartDrawer();showNotice('Freeflow 已加入购物车；购物车已打开，可继续结账。');
 }).catch(()=>{});
}
function setDraftRedeemOpen(open){const panel=$('draftRedeemPanel'),button=$('draftRedeemToggle');if(!panel||!button)return;panel.classList.toggle('hidden',!open);panel.setAttribute('aria-hidden',String(!open));button.setAttribute('aria-expanded',String(open));if(open)$('draftRedeemToken')?.focus();}
async function scanDraftReward(){return draftOperation(async()=>{
 const raw=$('draftRedeemToken').value.trim();const custom=await customPricing?.scan(raw);if(custom){if(custom.cancelled){$('draftRedeemToken').value='';return;}if(!state.catalog.some(x=>x.id===custom.id))state.catalog.push({...custom,active:true,category:'CUSTOM',is_drink:true});state.cart.set(custom.id,(state.cart.get(custom.id)||0)+1);$('draftRedeemToken').value='';saveDraft();await refreshDraftSummary();showNotice('订制饮品已通过 Redeem 加入购物车');return;}if(isAmbassadorToken(raw)){await scanAmbassadorPass(raw);return;}
 
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
 if(h?.source==='moon'){ $('draftRedeemToken').value='';state.draftSelection=null;saveDraft();await refreshDraftSummary();$('draftRewardChoices').replaceChildren();setDraftRedeemOpen(false);showNotice(h.kind==='R0'?'Moon 抵扣已预留，结账才核销':'Moon 奖励已预留，结账才核销');return; }
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
    $('draftRedeemToken').value='';state.draftSelection=null;root.replaceChildren();saveDraft();await refreshDraftSummary();setDraftRedeemOpen(false);showNotice('Moon 奖励已按绑定商品预留，结账才核销');
   }).catch(()=>{});
   root.append(b);
  }
  if(!(h.products||[]).length)root.insertAdjacentHTML('beforeend','<p class="field-note">此 Moon 奖励尚未在 Owner 的现有兑奖规则中绑定商品或系列。</p>');
  return;
 }
 if(h.state==='chosen'){root.innerHTML='<p class="field-note">这份奖励已经选好，请在上方核对。</…20924 tokens truncated…)||file.size>5*1024*1024)throw Error('交易截图需为 PNG/JPG/WEBP 且小于5MB');stopDuitnowCamera();state.duitnowProofFile=file;if(state.duitnowProofUrl)URL.revokeObjectURL(state.duitnowProofUrl);state.duitnowProofUrl=URL.createObjectURL(file);const preview=$('duitnowProofPreview');preview.src=state.duitnowProofUrl;preview.classList.remove('hidden');$('duitnowCameraRetake')?.classList.remove('hidden');showNotice(`已选择交易记录：${file.name||'现场拍摄'}`);}
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
 $('editTable').value=row.table_label||'';$('editNote').value=row.notes||'';$('editReason').value='';$('editRevokeBenefits').checked=false;$('editCancelOrder').checked=false;const currentMethod=String(row.payment_method||'').toLowerCase();const editableMethod=(isOwner()||isCashier())&&['foodcourt','cash','duitnow','bank_transfer','card','other'].includes(currentMethod);$('editPaymentMethodLabel').classList.toggle('hidden',!editableMethod);$('editPaymentMethod').value=editableMethod?currentMethod:'duitnow';state.editOriginalPaymentMethod=editableMethod?currentMethod:null;$('editOwnerOptions').classList.toggle('hidden',!isOwner());$('editCancelOptions')?.classList.toggle('hidden',!isCashier()&&!isOwner());$('editAmountSummary').classList.toggle('hidden',!isOwner()&&!isCashier());$('editRevisions').innerHTML=isOwner()?revisionHistory(row.revisions||[]):'';
 $('editHint').textContent=isOwner()?'左起：商品、数量、单价。数量设0可移除；款项需另外确认实际补收／退款。':isCashier()?'可申请修改或取消任意未退款订单；Owner 批准后才会生效，Cashier 不会直接改动账单。':'仅修改未付款、未出品订单；修改已接受订单后会按权限回到待审核。';
 $('editTitle').textContent=`改单 · ${row.order_no}`;renderEditRows();renderAdjustment(row);$('editOverlay').classList.remove('hidden');document.body.classList.add('sheet-open');$('editTable').focus();editControls();
}
async function submitEditOrder(e){e.preventDefault();const btn=$('editForm').querySelector('[type=submit]');if(state.editBusy)return;
 await busy(btn,async()=>{
  if(!state.editOrder)throw Error('请先选择订单');
  if(isOwner()){
   if(!state.editPending){await previewOwnerEdit();if(!state.editPreview)throw Error('请先核对修改金额');const balance=Number(state.editPreview.balance_rm);const paid=state.editOrder.payment_status==='paid';
    const description=paid?(balance>0?'需另行补收 '+money(balance):balance<0?'需另行退款 '+money(-balance):'款项已对齐'):'尚未收款';
    const nextMethod=$('editCancelOrder').checked||$('editPaymentMethodLabel').classList.contains('hidden')?null:$('editPaymentMethod').value;const methodChanged=nextMethod&&nextMethod!==state.editOriginalPaymentMethod;
    if(!confirm('确认保存改单？\n'+description+(methodChanged?'\n收款方式：'+state.editOriginalPaymentMethod+' → '+nextMethod+'（只更正收款分类，不改变金额）':'')+'\n'+($('editRevokeBenefits').checked?'撤销本单发出的权益':'保留本单发出的权益')))return;
    state.editPending={p_order:state.editOrder.id,p_items:editItems(),p_reason:$('editReason').value.trim(),p_table:$('editTable').value.trim()||null,p_note:$('editNote').value.trim()||null,p_expected_updated:state.editOrder.updated_at,p_request:crypto.randomUUID(),p_revoke:$('editRevokeBenefits').checked,p_cancel:$('editCancelOrder').checked,p_payment_method:methodChanged?nextMethod:null};
   }
   state.editBusy
=true;editControls();let result;try{result=unpack(await db.rpc('yt_pos_owner_revision_apply_v2',state.editPending));}catch(e){if(e.code)state.editPending=null;throw e;}finally{state.editBusy=false;editControls();}
   const id=state.editOrder.id;state.editPending=null;await refreshOrders(false);if(result.payment_status==='paid'&&Number(result.balance_rm)!==0){await openEditDialog(id);showNotice('改单已保存，请确认实际补收／退款');}else{closeEditDialog();showNotice('改单已保存，前后内容及权益选择已记录');}
  }else{
   if(isCashier()){
    if(!state.editPending){if(!state.editPreview)await previewOwnerEdit();if(!state.editPreview)throw Error('请先核对修改内容');const nextMethod=$('editCancelOrder').checked||$('editPaymentMethodLabel').classList.contains('hidden')?null:$('editPaymentMethod').value;const methodChanged=nextMethod&&nextMethod!==state.editOriginalPaymentMethod;if(!confirm(($('editCancelOrder').checked?'确认提交整单取消申请给 Owner 审批？':'确认提交改单给 Owner 审批？')+(methodChanged?'\n收款方式：'+state.editOriginalPaymentMethod+' → '+nextMethod+'（只更正收款分类，不改变金额）':'')))return;state.editPending={p_order:state.editOrder.id,p_items:editItems(),p_reason:$('editReason').value.trim(),p_table:$('editTable').value.trim()||null,p_note:$('editNote').value.trim()||null,p_expected_updated:state.editOrder.updated_at,p_cancel:$('editCancelOrder').checked,p_request:crypto.randomUUID(),p_payment_method:methodChanged?nextMethod:null};}
    state.editBusy=true;editControls();try{unpack(await db.rpc('yt_pos_owner_revision_request_submit_v2',state.editPending));}finally{state.editBusy=false;editControls();}
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
 const backdatePending=row?.backdate_approval_status==='pending';
 const [receipt,summary]=await Promise.all([
  db.rpc('yt_pos_receipt',{p_order:id}),ambassador?Promise.resolve({data:null,error:null}):db.rpc('yt_pos_cart_summary',{p_order:id})]);
 const bill=unpack(receipt),q=ambassador?{order_no:row.order_no,gross_rm:row.amount_rm,reserved_discount_rm:0,payable_rm:row.amount_rm,unresolved_count:0,minimum_met:true,status:row.status,payment_status:row.payment_status,store_box_only:false,can_pay:row.payment_status==='unpaid',moon_codes:[],holds:[]}:unpack(summary);
 $('orderCartTitle').textContent='#'+(q.order_no||bill.order_no)+' · '+(ambassador?'Freeflow 收款':'优惠与结账');
 $('orderCartItems').innerHTML=(bill.items||[]).map(item=>`<div class="cart-preview-item"><strong>${esc(item.item_name)} × ${Number(item.quantity)}</strong><span>${money(item.quantity*item.unit_price_rm)}</span></div>`).join('');
 $('orderCartHolds').innerHTML=ambassador?'<p class="muted">Freeflow Pass 按实际人数计价，不叠加其他奖券。</p>':(q.moon_codes||[]).map(x=>'<div class="cart-discount-line"><div><strong>'+esc(x.reward_name||(x.kind==='R0'?'RM5 Voucher':x.kind==='R3'?'彩虹 Shot 赠品':x.kind==='R5'?'断片指南赠品':'微醺特调赠品'))+'</strong><small>'+esc(x.code)+' · 已预留，收款后核销</small></div><b>'+ (x.kind==='R0'?'−'+money(x.discount_rm||5):'FREE') +'</b><button type="button" class="quiet" data-moon-release="'+esc(x.id)+'">释放</button></div>').join('')+((q.holds||[]).length?q.holds.map(h=>`<div class="cart-discount-line"><div><strong>− ${esc(h.reward_name)}</strong><small>${h.can_checkout?'已预留':h.state==='reserved'?'待选择商品':'已超时'} · ${stamp(h.expires_at)}</small></div><b>−${money(h.discount_rm)}</b>${q.payment_status==='unpaid'?`<button type="button" class="quiet" data-release-hold="${esc(h.id)}">释放</button>`:''}</div>`).join(''):'<p class="muted">无预留奖励</p>');
 $('orderCartGross').textContent=money(q.gross_rm);
 $('orderCartDiscount').textContent='−'+money(q.reserved_discount_rm);
 $('orderCartPayable').textContent=money(q.payable_rm);
 $('orderCartStatus').textContent=backdatePending?'此单营业日回填尚待 Owner 批准，批准前不能收款。':ambassador?'POS 原价销售 · 收款后计入 Daily Sales 并结算佣金':q.unresolved_count?'请先处理奖励。':q.minimum_met===false?'需保留至少一杯付费饮品。':q.status==='pending'?'等待 Cashier 接单。':q.payment_status==='paid'&&q.status==='confirmed'?'已收款，订单仍在吧台 KDS 等待出品。':q.payment_status==='paid'?'已结账。':q.status==='confirmed'&&q.store_box_only?'可直接结账；完成后立即生成顾客领取码。':q.status==='confirmed'?'可先收款；订单仍会保留在吧台 KDS。':'可结账。';
 $('orderCartStatus').classList.toggle('warn',backdatePending||q.unresolved_count>0||q.minimum_met===false);
 $('cartRedeemForm').classList.add('hidden');
 if(ambassador){cashierPackageQuote=null;cashierPackageOrder=null;$('cashierPackagePrep').classList.add('hidden');}else await loadCashierPackagePrep(id,q);
 $('cartCheckoutControls').classList.toggle('hidden',!(isCashier()||isOwner()||isStaff())||q.payment_status==='paid');
 const proofPending=!ambassador&&state.duitnowProofs?.some(proof=>proof.order_id===id&&proof.status==='pending');
 const memberBinding=row?.member_binding,memberBindingBox=$('cartMemberBinding'),memberBindingStatus=$('cartMemberBindingStatus'),memberScan=$('cartMemberScan');
 const memberBindingEligible=!ambassador&&state.luckyMode?.mode==='off'&&q.payment_status==='unpaid';
 memberBindingBox?.classList.toggle('hidden',!memberBindingEligible);
 if(memberBindingEligible){const isBound=!!memberBinding?.member_binding;memberScan?.classList.toggle('hidden',isBound);memberScan?.setAttribute('data-play-member-scan',id);memberBindingStatus.textContent=isBound?'本单已绑定会员，结账后按实付金额处理积分。':'可在收款前扫描顾客会员码绑定本单。';}
 $('cartCheckoutBtn').disabled=!q.can_pay||proofPending||backdatePending;$('cartCheckoutBtn').textContent=backdatePending?'等待 Owner 批准营业日':proofPending?'DuitNow 已提交，等待 Cashier 确认':ambassador?'确认 Freeflow 收款':q.store_box_only?'收款并生成领取码':isStaff()&&$('cartCheckoutPayment').value==='duitnow'?'上传截图并提交 Cashier 确认':'确认收款并正式核销奖励';
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
  unpack(await db.rpc('yt_store_box_prep_intent_save',{p_order:orderId,p_preps:preps}));cashierPackageQuote=quote;cashierPackageOrder=orderId;let kdsLoaded=true;try{await refreshOrders(false);}catch(error){kdsLoaded=false;console.warn('Package / Challenge 已自动接单，但 KDS 刷新失败',error?.message||error);}showNotice(kdsLoaded?'预出杯数量已保存；无需接单，订单已进入 KDS 待出品，剩余数量会留在存酒箱。':'预出杯数量已保存，订单已自动接单；KDS 列表暂未刷新，请刷新订单页查看。',!kdsLoaded);layer.remove();resolve();
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
async function loadRefreshSchedule(){try{state.refreshSchedule=unpack(await db.rpc('yt_pos_refresh_schedule',{p_data:null}));}catch(error){state.refreshSchedule={enabled:false,start_time:'18:30',end_time:'00:30',interval_seconds:15};console.warn('Refresh schedule unavailable; automatic polling disabled.',error);}}
window.addEventListener('yt-pos-refresh-schedule-updated',event=>{state.refreshSchedule=event.detail||null;state.lastAutoPollAt=0;});
function pollVisibleWorkspace({force=false}={}){if(document.visibilityState==='hidden'||state.activeView!=='dashboard')return;const schedule=state.refreshSchedule;if(!schedule||!isRefreshWindowOpen(schedule,new Date()))return;const interval=Math.max(15,Number(schedule.interval_seconds)||15)*1000;if(!force&&Date.now()-state.lastAutoPollAt<interval)return;state.lastAutoPollAt=Date.now();refreshOrders(true);if(state.currentTab==='benefits'&&!state.benefitLoading){state.benefitLoading=true;loadBenefits(null,true).catch(()=>{}).finally(()=>{state.benefitLoading=false;});}if(state.currentTab==='storebox')storeBox?.loadStaff(true).catch(()=>{});playUpgrade.poll();}
function startPolling(){stopPolling();state.interval=setInterval(pollVisibleWorkspace,POLL_CLOCK_TICK_MS);}
function stopPolling(){if(state.interval){clearInterval(state.interval);state.interval=null;}}
const customPricing=createCustomPricing({db,isOwner,isCashier,notice:(message,bad)=>showNotice(message,bad),onClose:()=>showTab('create'),onAddProduct:async d=>{const productId=d?.product_id||d?.id;const customId=d?.custom_id||(d?.product_id?d.id:null);if(!productId)throw new Error('订制商品编号缺失，未加入购物车');const product={id:productId,custom_id:customId,share_token:d.share_token,name:d.name,price_rm:d.price_rm,active:true,category:'CUSTOM',is_drink:true};const existing=state.catalog.find(x=>x.id===productId);if(existing)Object.assign(existing,product);else state.catalog.push(product);state.cart.set(productId,(state.cart.get(productId)||0)+1);renderCart();showTab('create');openCartDrawer();}});
function bind(){
 document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')pollVisibleWorkspace({force:true});});
 customPricing.init();
 if(!$('editCancelOptions'))$('editOwnerOptions')?.insertAdjacentHTML('beforebegin','<div id="editCancelOptions" class="hidden"></div>');
 $('noticeDismiss')?.addEventListener('click',()=>{$('notice').classList.add('hidden');clearTimeout(state.noticeTimer);});
 document.addEventListener('pointerdown',unlockAudio,{once:true});
 $('signinForm').addEventListener('submit',e=>{unlockAudio();login(e).catch(()=>{});});window.YT_WORK_READY=true;
 document.addEventListener('click',e=>{const detail=e.target.closest('[data-custom-binding-details]');if(detail)showCustomBindingDetails(detail.dataset.customBindingDetails);});
 $('paidDateForm').onsubmit=e=>{e.preventDefault();refreshOrders(false);};$('paidToday').onclick=async()=>{try{const c=unpack(await db.rpc('yt_business_context'));state.businessDay=c.day;$('paidDate').value=c.day;if($('kdsHistoryDate'))$('kdsHistoryDate').value=c.day;await refreshOrders(false);}catch(e){showNotice(errorText(e),true);}};
 if($('kdsHistoryForm'))$('kdsHistoryForm').onsubmit=e=>{e.preventDefault();loadKdsHistory();};if($('kdsHistoryRefresh'))$('kdsHistoryRefresh').onclick=()=>loadKdsHistory();$('kdsHistoryDetails')?.addEventListener('toggle',()=>{if($('kdsHistoryDetails').open&&state.kdsHistoryDay!==$('kdsHistoryDate').value)loadKdsHistory();});
 storeBox=createStoreBox({db,ownerRoot:$('storeBoxOwnerRoot'),staffRoot:$('storeBoxStaffRoot'),orderRoot:$('storeBoxOrderQueue'),isOwner,isCashier,isCashierAccount:()=>state.identity?.role==='cashier',notice:(message,bad)=>showNotice(errorText(Error(message)),bad),getBusinessDay:()=>state.businessDay,onQueueChange:updateStoreBoxQueue});
 if(document.body.dataset.unified==='true')consoleUI=createConsole({db,work,isOwner,isOwnerLimited,isCashier,loadAdmin,loadOffers:loadOwnerRewardOffers,loadRights,loadStoreBoxOwner:()=>storeBox.loadOwner(),customPricing,notice:(message,bad)=>showNotice(errorText(Error(message)),bad),getBusinessDay:()=>state.businessDay,onOwnerEdit:openEditDialog,onOrdersChanged:()=>refreshOrders(false),onReset:async(scopes)=>{
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
 $('focRequestBtn').onclick=()=>openManualAdjustment('foc');$('discountRequestBtn').onclick=()=>openManualAdjustment('discount');$('manualAdjustmentForm').onsubmit=e=>submitManualAdjustment(e).catch(error=>showNotice(errorText(error),true));$('manualAdjustmentClose').onclick=closeManualAdjustment;$('manualAdjustmentOverlay').onclick=e=>{if(e.target===$('manualAdjustmentOverlay'))closeManualAdjustment();};$('manualAdjustmentOverlay').addEventListener('keydown',e=>{if(e.key==='Escape')closeManualAdjustment();});$('cashierAdjustmentHistoryDetails').addEventListener('toggle',()=>{if($('cashierAdjustmentHistoryDetails').open)loadCashierAdjustmentHistory().catch(error=>showNotice(errorText(error),true));});
 $('draftRedeemCheck').onclick=()=>scanDraftReward().catch(()=>{});$('draftRedeemScan').onclick=()=>startRedeemCamera().catch(e=>showNotice(errorText(e),true));$('draftRedeemToggle').onclick=()=>setDraftRedeemOpen($('draftRedeemPanel').classList.contains('hidden'));$('draftRedeemClose').onclick=()=>setDraftRedeemOpen(false);$('draftRefresh').onclick=()=>refreshDraftSummary().catch(e=>showNotice(errorText(e),true));$('draftRewardRows').onclick=e=>{const b=e.target.closest('[data-release-draft]');if(b)releaseDraftReward(b.dataset.releaseDraft).catch(()=>{});};$('draftRedeemToken').onkeydown=e=>{if(e.key==='Enter'&&!$('draftRedeemCheck').disabled){e.preventDefault();scanDraftReward().catch(()=>{});}};$('tableInput').oninput=saveDraft;$('orderNote').oninput=saveDraft;$('orderBusinessDay')?.addEventListener('change',saveDraft);$('checkoutPayNow').onchange=()=>{saveDraft();updateCreateHint();};$('checkoutPayLater').onchange=()=>{saveDraft();updateCreateHint();};
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

 document.addEventListener('visibilitychange',()=>{if(document.visibilityState!=='visible')stopRedeemCamera();});
}
async function boot(){bind();playUpgrade.bindOrderClicks();window.YT_WORK_READY=true;if(!usable){resetLogin();showNotice('请检查 /play/config.js，POS 尚未连上 Supabase',true,true);return;}
 const {data,error}=await db.auth.getSession();if(!error&&data?.session){try{await launch();return;}catch(e){showNotice('请重新登录工作账号：'+errorText(e),true);}}
 resetLogin();}
boot().catch(e=>{window.YT_WORK_READY='failed';resetLogin();showNotice(errorText(e),true,true);});

