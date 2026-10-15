Warning: truncated output (original token count: 45410)
Total output lines: 1210

import {createPlayWork} from './play-upgrade.js?v=20261015-service-bell-cashier-only-v1';
import {revisionSummary,benefitSummary,revisionHistory} from './owner-order-edit.js?v=20261010-copy-v15-4';
import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';
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
  ownerDashboard:null,ownerDashboardDay:null,ownerDashboardLoading:false,duitnowQrPath:null,duitnowQrLoaded:false,duitnowQrError:null,kdsHistory:null,kdsHistoryDay:null,kdsHistoryLoading:false,duitnowProofFile:null,duitnowProofUrl:null,duitnowProofStream:null,duitnowProofs:[]};
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
const playUpgrade=createPlayWork({db,notice:(message,bad)=>showNotice(message,bad),isOwner,isCashier,qrLibrary:()=>qrLibrary(),getOrders:()=>[...state.active,...state.paid],refreshOrders:()=>refreshOrders(false),onMemberBound:()=>state.selectedOrderCart?refreshOrderCart():undefined});
globalThis.ytPlayWork=playUpgrade;
function showNotice(message,bad=false,persist=false){const n=$('notice'),label=$('noticeMessage');if(!n)return;if(label)label.textContent=message;else n.textContent=message;n.dataset.message=message;n.classList.remove('hidden');n.classList.toggle('error',bad);n.setAttribute('role',bad?'alert':'status');n.setAttribute('aria-live',bad?'assertive':'polite');clearTimeout(state.noticeTimer);if(!persist)state.noticeTimer=setTimeout(()=>n.classList.add('hidden'),bad?8000:6200);}
function busy(btn,fn){if(btn?.disabled)return Promise.resolve();if(btn)btn.disabled=true;return Promise.resolve().then(fn).catch(e=>{showNotice(errorText(e),true);throw e}).finally(()=>{if(btn)btn.disabled=false});}
async function getBearer(){const {data,error}=await db.auth.getSession();if(error||!data.session?.access_token)throw Error('not_authenticated');return data.session.access_token;}
async function work(action,data={},signed=false){const headers={'Content-Type':'application/json',apikey:conf.publishableKey};if(signed)headers.Authorization='Bearer '+await getBearer();const endpoint=action.startsWith('reset_')?(conf.url||'')+'/functions/v1/yt-owner-reset':workURL;const resp=await fetch(endpoint,{method:'POST',headers,cache:'no-store',body:JSON.stringify({action,...data})});const res=await resp.json().catch(()=>({ok:false,error:'server_unavailable'}));if(!resp.ok||!res.ok)throw Error(res.error||'server_unavailable');return res;}
function resetLogin(){clearInterval(state.benefitTimer);state.shownBenefit=null;state.benefitLoading=false;state.benefitListEpoch=(state.benefitListEpoch||0)+1;benefitEpoch++;state.editBusy=false;closeEditDialog();state.revisionRequests=[];state.editCart.clear();state.editPending=null;state.adjustmentPending=null;stopRedeemCamera();stopPolling();storeBox?.clear();limitedReportView?.clear();limitedReportView=null;state.cart.clear();state.ambassadorDraft=null;state.draftSummary=null;state.draftSelection=null;state.pendingSubmit=null;state.draftEpoch++;state.ownerDashboard=null;state.ownerDashboardDay=null;state.ownerDashboardLoading=false;state.storeBoxQueue=[];state.seenStoreBox=new Set();state.seenStoreBoxInitialized=false;state.seenKds=new Set();state.seenKdsInitialized=false;state.seenPending=new Set();state.seenInitialized=false;state.activeView='login';state.identity=null;consoleUI?.roleChanged();buildNav();$('revisionApprovalTab')?.classList.toggle('hidden',!isOwner());if(!isOwner()){approvalCount=null;$('revisionApprovalCount')?.classList.add('hidden');}$('accountMenu').classList.add('hidden');$('accountMenu').open=false;$('signinForm').classList.remove('hidden');$('firstPasswordForm').classList.add('hidden');$('signin').classList.remove('hidden');$('dashboard').classList.add('hidden');$('logout').classList.add('hidden');$('accountName').textContent='WORK ACCOUNT';}
async function login(e){e.preventDefault();await busy($('signinBtn'),async()=>{
 const username=$('username').value.trim().toLowerCase(),password=$('password').value;
 const result=await work('login',{username,password});
  const {error}=await db.auth.setSession({access_token:result.access_token,refresh_token:result.refresh_token});if(error)throw error;
 if(result.must_change_password){$('signinForm').classList.add('hidden');$('firstPasswordForm').classList.remove('hidden');$('firstOldPassword').value=password;return;}
 $('password').value='';await launch();
});}
async function launch(){if(!usable){showNotice('尚未配置 /play/config.js 的 Supabase 连接',true,true);return;}
 const identity=unpack(await db.rpc('yt_pos_identity'));if(!identity)throw Error('staff_only');
  state.identity={...identity,can_owner:identity.role==='owner'||identity.can_owner===true,can_cashier:identity.role==='owner'||identity.can_cashier===true,can_edit_orders:identity.role==='owner'||identity.can_edit_orders===true};state.activeView='dashboard';$('signin').classList.add('hidden');$('dashboard').classList.remove('hidden');$('logout').classList.remove('hidden');
 $('accountName').textContent=identity.username+' · '+(isOwner()?'OWNER':identity.can_owner_l…35410 tokens truncated…'image/webp'?'webp':'jpg'}`;
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
function bind(){
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



