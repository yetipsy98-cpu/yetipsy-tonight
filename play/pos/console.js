import {createFactoryReset} from './factory-reset.js?v=20261012-reset-fix-v23';
const $=id=>document.getElementById(id);
 const titles={catalog:'商品与系列',storebox:'存酒箱',rewards:'奖励',team:'团队与权限',campaign:'活动与奖池',loyalty:'会员与积分',banners:'轮播广告',insights:'报表中心',ambassador:'Ambassador Pass',receipt:'账单样式',paymentqr:'DuitNow 收款二维码',home:'客户端设计',moon:'Moon 旧码录入',lucky:'Lucky Box',factory:'系统重置',pin:'顾客 PIN 重设',dayclose:'营业日结',orderapprovals:'改单审批'};
export function createConsole({db,work,isOwner,isOwnerLimited=()=>false,isCashier,loadAdmin,loadOffers,loadRights,loadStoreBoxOwner,notice,onReset,onOrdersChanged,getBusinessDay,onOwnerEdit}){
 let previousFocus=null,activeKey=null,loadEpoch=0,ownerTools=null,ownerReports=null,dayClose=null,pointsAdmin=null,receiptSettings=null,paymentQrSettings=null,homeEditor=null,moonEditor=null,luckyEditor=null,orderApprovals=null;
 const overlay=$('toolDrawerOverlay'),drawer=$('toolDrawer'),main=document.querySelector('main'),head=document.querySelector('.site-head');
 if(typeof document.createElement==='function'&&!document.querySelector('[data-owner-tool="receipt"]')){const tile=document.createElement('button');tile.type='button';tile.dataset.ownerTool='receipt';tile.innerHTML='<strong>账单样式</strong><span>店名 · 内容 · 打印</span>';document.querySelector('.owner-grid')?.append(tile);}
 if(typeof document.createElement==='function'&&!drawer.querySelector('[data-pane="receipt"]')){const pane=document.createElement('section');pane.className='tool-pane hidden';pane.dataset.pane='receipt';pane.innerHTML='<div id="receiptSettingsRoot"></div>';drawer.querySelector('.tool-body')?.append(pane);}
 if(typeof document.createElement==='function'&&!document.querySelector('[data-owner-tool="paymentqr"]')){const tile=document.createElement('button');tile.type='button';tile.dataset.ownerTool='paymentqr';tile.innerHTML='<strong>DuitNow 收款二维码</strong><span>Cashier 结账 · 上传与更换</span>';document.querySelector('.owner-grid')?.append(tile);}
 if(typeof document.createElement==='function'&&!drawer.querySelector('[data-pane="paymentqr"]')){const pane=document.createElement('section');pane.className='tool-pane hidden';pane.dataset.pane='paymentqr';pane.innerHTML='<div id="paymentQrSettingsRoot"></div>';drawer.querySelector('.tool-body')?.append(pane);}
 if(typeof document.createElement==='function'&&!document.querySelector('[data-owner-tool="home"]')){const tile=document.createElement('button');tile.type='button';tile.dataset.ownerTool='home';tile.innerHTML='<strong>客户端设计</strong><span>首页 · 排版 · 文案 · 发布</span>';document.querySelector('.owner-grid')?.append(tile);}
 if(typeof document.createElement==='function'&&!drawer.querySelector('[data-pane="home"]')){const pane=document.createElement('section');pane.className='tool-pane hidden';pane.dataset.pane='home';pane.innerHTML='<div id="homeEditorRoot"></div>';drawer.querySelector('.tool-body')?.append(pane);}
 if(typeof document.createElement==='function'&&!document.querySelector('[data-owner-tool="moon"]')){const tile=document.createElement('button');tile.type='button';tile.dataset.ownerTool='moon';tile.innerHTML='<strong>Moon 旧码录入</strong><span>逐张输入 · 无需会员</span>';document.querySelector('.owner-grid')?.append(tile);}
 if(typeof document.createElement==='function'&&!drawer.querySelector('[data-pane="moon"]')){const pane=document.createElement('section');pane.className='tool-pane hidden';pane.dataset.pane='moon';pane.innerHTML='<div id="moonCodeEditorRoot"></div>';drawer.querySelector('.tool-body')?.append(pane);}
 if(typeof document.createElement==='function'&&!document.querySelector('[data-owner-tool="lucky"]')){const tile=document.createElement('button');tile.type='button';tile.dataset.ownerTool='lucky';tile.innerHTML='<strong>Lucky Box</strong><span>GamePass 模式 · 概率 · 积分</span>';document.querySelector('.owner-grid')?.append(tile);}
 if(typeof document.createElement==='function'&&!drawer.querySelector('[data-pane="lucky"]')){const pane=document.createElement('section');pane.className='tool-pane hidden';pane.dataset.pane='lucky';pane.innerHTML='<div id="luckyBoxOwnerRoot"></div>';drawer.querySelector('.tool-body')?.append(pane);}
 if(typeof document.createElement==='function'&&!document.querySelector('[data-owner-tool="orderapprovals"]')){const tile=document.createElement('button');tile.type='button';tile.dataset.ownerTool='orderapprovals';tile.innerHTML='<strong>改单审批</strong><span>Cashier 提交 · Owner 确认</span>';document.querySelector('.owner-grid')?.append(tile);}
 if(typeof document.createElement==='function'&&!drawer.querySelector('[data-pane="orderapprovals"]')){const pane=document.createElement('section');pane.className='tool-pane hidden';pane.dataset.pane='orderapprovals';pane.innerHTML='<div id="ownerOrderApprovalsRoot"></div>';drawer.querySelector('.tool-body')?.append(pane);}
 const reset=createFactoryReset({work,notice,onReset,onOrdersChanged,getBusinessDay,onOwnerEdit});
 if(typeof document.createElement==='function'&&!document.querySelector('[data-ytaOwnerTool="ambassador"]')){const tile=document.createElement('button');tile.type='button';tile.dataset.ytaOwnerTool='ambassador';tile.innerHTML='<strong>Ambassador</strong><span>价格 · 权限 · 佣金结算</span>';document.querySelector('.owner-grid')?.append(tile);tile.onclick=e=>{e.stopPropagation();if(isOwnerLimited())globalThis.ytAmbassadorTools?.open?.().catch(err=>notice(err.message,true));else globalThis.ytAmbassadorTools?.openOwner?.().catch(err=>notice(err.message,true));};}
 async function loadStaffOrderReview(){const input=$('staffOrderReviewEnabled'),status=$('staffOrderReviewStatus');if(!input)return;status.textContent='正在读取审核设置…';const result=await db.rpc('yt_pos_order_review_setting_get');if(result.error)throw result.error;input.checked=Boolean(result.data?.require_review);status.textContent=input.checked?'Staff 订单目前需要 Cashier 审核。':'Staff 订单目前会直接进入 KDS。';}
 async function saveStaffOrderReview(button){const input=$('staffOrderReviewEnabled'),status=$('staffOrderReviewStatus');if(!input||!button)return;button.disabled=true;status.textContent='正在保存…';try{const result=await db.rpc('yt_pos_order_review_setting_save',{p_require_review:input.checked});if(result.error)throw result.error;input.checked=Boolean(result.data?.require_review);status.textContent=input.checked?'已保存：Staff 订单需要 Cashier 审核。':'已保存：Staff 订单会直接进入 KDS。';notice('Staff 订单审核设置已保存');}catch(error){status.textContent=error.message||'保存失败，请重试。';notice(error.message||'保存审核设置失败',true);}finally{button.disabled=false;}}
 function setSub(key){const pane=drawer.querySelector('[data-pane="'+activeKey+'"]');if(!pane)return;for(const sub of pane.querySelectorAll('[data-subpane]'))sub.classList.toggle('hidden',sub.dataset.subpane!==key);for(const b of pane.querySelectorAll('[data-sub]'))b.classList.toggle('active',b.dataset.sub===key);}
 function close(){if(reset.busy)return;ownerReports?.cancel();dayClose?.cancel();pointsAdmin?.cancel();receiptSettings?.cancel();paymentQrSettings?.cancel();homeEditor?.cancel();loadEpoch++;reset.cancel();overlay.classList.add('hidden');document.body.classList.remove('tool-open');main.inert=false;head.inert=false;activeKey=null;previousFocus?.focus();}
 async function open(key,sub){
  if(isOwnerLimited()&&!['insights','ambassador'].includes(key)){notice('Owner Limited 仅可查看报表及签发 Ambassador Pass',true);return;}
  if(key==='dayclose'&&!isCashier()){notice('需要收银权限',true);return;}
  if(!['pin','dayclose','insights','ambassador','orderapprovals'].includes(key)&&!isOwner()){notice('仅限 Owner 使用',true);return;}
  if(key==='orderapprovals'&&!isOwner()){notice('仅限 Owner 审批改单',true);return;}
  if(key==='ambassador'&&!isOwner()&&!isOwnerLimited()){notice('仅限 Owner Limited 或 Owner 使用',true);return;}
  ownerReports?.cancel();dayClose?.cancel();pointsAdmin?.cancel();receiptSettings?.cancel();paymentQrSettings?.cancel();homeEditor?.cancel();const epoch=++loadEpoch;activeKey=key;previousFocus=document.activeElement;reset.cancel();
  $('toolDrawerTitle').textContent=titles[key]||'工具';for(const p of drawer.querySelectorAll('[data-pane]'))p.classList.toggle('hidden',p.dataset.pane!==key);
  if(key==='pin')$('tab-reset').classList.remove('hidden');
  if(sub)setSub(sub);else{const first=drawer.querySelector('[data-pane="'+key+'"] [data-sub]');if(first)setSub(first.dataset.sub);}
  overlay.classList.remove('hidden');document.body.classList.add('tool-open');main.inert=true;head.inert=true;drawer.focus();
  try{
   if(['catalog','rewards','team','banners'].includes(key))await loadAdmin();
   if(key==='storebox')await loadStoreBoxOwner?.();
   if(epoch!==loadEpoch)return;if(key==='rewards')await loadOffers();
   if(['team','campaign','loyalty'].includes(key)){
    ownerTools||=await import('../shared/owner-tools.js?v=20261010-copy-v15-4');if(epoch!==loadEpoch)return;
    const identityResult=await db.rpc('yt_pos_identity');if(identityResult.error)throw identityResult.error;
    if(!identityResult.data?.can_owner)throw Error('owner_only');ownerTools.initOwnerTools(db,identityResult.data);await ownerTools.loadOwnerTool(key);
    if(key==='team'){await loadRights();await loadStaffOrderReview();}if(key==='loyalty'){const module=await import('./owner-points.js?v=20261012-points-rewards-v18');if(epoch!==loadEpoch)return;pointsAdmin||=module.createPointsAdmin({db,root:$('ownerPointsRoot'),isOwner,notice});await pointsAdmin.load();}
   }
   if(key==='insights'){const module=await import('./owner-reports.js?v=20261014-limited-report-v2');if(epoch!==loadEpoch)return;ownerReports||=module.createOwnerReports({db,root:$('ownerReportsRoot'),isOwner:()=>isOwner()||isOwnerLimited(),allowExport:()=>isOwner(),notice,businessDay:getBusinessDay?.()});await ownerReports.load();}
   if(key==='ambassador'){if(isOwnerLimited())await globalThis.ytAmbassadorTools?.open();else await globalThis.ytAmbassadorTools?.openOwner?.();}
   if(key==='orderapprovals'){const module=await import('./owner-order-approvals.js?v=20261014-cashier-approval-v1');if(epoch!==loadEpoch)return;orderApprovals||=module.createOwnerOrderApprovals({db,root:$('ownerOrderApprovalsRoot'),notice,onChange:onOrdersChanged});await orderApprovals.load();}
   if(key==='home'){const module=await import('./home-editor.js?v=20261012-v22');if(epoch!==loadEpoch)return;homeEditor||=module.createHomeEditor({db,root:$('homeEditorRoot'),notice});await homeEditor.load();}
   if(key==='lucky'){const module=await import('./lucky-box-owner.js?v=20261013-lucky-v2');if(epoch!==loadEpoch)return;luckyEditor||=module.createLuckyOwner({db,root:$('luckyBoxOwnerRoot'),isOwner,notice});await luckyEditor.load();}
   if(key==='moon'){const module=await import('./moon-code-editor.js?v=20261013-moon-code-reward-v3');if(epoch!==loadEpoch)return;moonEditor||=module.createMoonCodeEditor({db,root:$('moonCodeEditorRoot'),isOwner,notice});await moonEditor.load();}
   if(key==='receipt'){const module=await import('./receipt-settings.js?v=20261012-v22');if(epoch!==loadEpoch)return;receiptSettings||=module.createReceiptSettings({db,root:$('receiptSettingsRoot'),isOwner,notice});await receiptSettings.load();}
   if(key==='paymentqr'){const module=await import('./payment-qr-settings.js?v=20261013-cashier-qr-v1');if(epoch!==loadEpoch)return;paymentQrSettings||=module.createPaymentQrSettings({db,root:$('paymentQrSettingsRoot'),isOwner,notice});await paymentQrSettings.load();}
   if(key==='dayclose'){const module=await import('./day-close.js?v=20261014-ambassador-pos-sales-v3');if(epoch!==loadEpoch)return;dayClose||=module.createDayClose({db,root:$('dayCloseRoot'),isOwner,notice,onOrdersChanged,onOwnerEdit:id=>{close();return onOwnerEdit?.(id);}});await dayClose.load();}
   if(key==='factory')await reset.resume();
  }catch(e){notice(e.message||'加载失败，请重试',true);}
 }
 function roleChanged(){
  if(!isOwner()&&!isOwnerLimited()){ownerReports?.clear();pointsAdmin?.clear();receiptSettings?.clear();paymentQrSettings?.clear();homeEditor?.cancel();moonEditor?.clear();luckyEditor?.clear();}dayClose?.clear();for(const b of document.querySelectorAll('[data-cashier-tool]'))b.classList.toggle('hidden',!isCashier());
  for(const button of document.querySelectorAll('[data-go-tab="admin"],[data-owner-tool]'))button.classList.toggle('hidden',!isOwner()&&!(isOwnerLimited()&&button.dataset.ownerTool==='ambassador'));
  for(const button of document.querySelectorAll('[data-go-tab="pending"]'))button.classList.toggle('hidden',!isCashier());
  for(const tile of document.querySelectorAll('[data-ytaOwnerTool="ambassador"]')){tile.classList.toggle('hidden',!isOwner()&&!isOwnerLimited());tile.innerHTML=isOwnerLimited()?'<strong>Ambassador Pass</strong><span>签发 · 查看 · 无佣金</span>':'<strong>Ambassador</strong><span>价格 · 权限 · 佣金结算</span>';}
  $('workspaceTitle').textContent=isOwnerLimited()?'Owner Limited 工作台':isOwner()?'店铺工作台':isCashier()?'收银工作台':'服务工作台';
 }
 document.addEventListener('click',e=>{const daily=e.target.closest('[data-cashier-tool]');if(daily)open(daily.dataset.cashierTool);const tile=e.target.closest('[data-owner-tool]');if(tile)open(tile.dataset.ownerTool,tile.dataset.ownerSub);const sub=e.target.closest('[data-sub]');if(sub)setSub(sub.dataset.sub);});
 $('saveStaffOrderReview')?.addEventListener('click',event=>saveStaffOrderReview(event.currentTarget));
 $('toolDrawerClose').onclick=close;overlay.onclick=e=>{if(e.target===overlay)close();};
 drawer.addEventListener('keydown',e=>{if(e.key!=='Tab')return;const focusables=[...drawer.querySelectorAll('button,input,select,textarea,a[href]')].filter(el=>!el.disabled&&el.getClientRects().length);const first=focusables[0],last=focusables.at(-1);if(!first){e.preventDefault();return;}if(e.shiftKey&&(document.activeElement===first||document.activeElement===drawer)){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}});
 document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!overlay.classList.contains('hidden')&&$('ops_modalBackdrop').classList.contains('hide'))close();});
 return {open,close,roleChanged};
}
