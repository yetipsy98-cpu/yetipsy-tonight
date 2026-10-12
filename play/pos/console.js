import {createFactoryReset} from './factory-reset.js?v=20261012-reset-fix-v23';
const $=id=>document.getElementById(id);
const titles={catalog:'商品与系列',storebox:'存酒箱',rewards:'奖励',team:'团队与权限',campaign:'活动与奖池',loyalty:'会员与积分',banners:'轮播广告',insights:'报表中心',receipt:'账单样式',home:'客户端设计',moon:'Moon 旧码录入',factory:'系统重置',pin:'顾客 PIN 重设',dayclose:'营业日结'};
export function createConsole({db,work,isOwner,isCashier,loadAdmin,loadOffers,loadRights,loadStoreBoxOwner,notice,onReset,onOrdersChanged,getBusinessDay,onOwnerEdit}){
 let previousFocus=null,activeKey=null,loadEpoch=0,ownerTools=null,ownerReports=null,dayClose=null,pointsAdmin=null,receiptSettings=null,homeEditor=null,moonEditor=null;
 const overlay=$('toolDrawerOverlay'),drawer=$('toolDrawer'),main=document.querySelector('main'),head=document.querySelector('.site-head');
 if(typeof document.createElement==='function'&&!document.querySelector('[data-owner-tool="receipt"]')){const tile=document.createElement('button');tile.type='button';tile.dataset.ownerTool='receipt';tile.innerHTML='<strong>账单样式</strong><span>店名 · 内容 · 打印</span>';document.querySelector('.owner-grid')?.append(tile);}
 if(typeof document.createElement==='function'&&!drawer.querySelector('[data-pane="receipt"]')){const pane=document.createElement('section');pane.className='tool-pane hidden';pane.dataset.pane='receipt';pane.innerHTML='<div id="receiptSettingsRoot"></div>';drawer.querySelector('.tool-body')?.append(pane);}
 if(typeof document.createElement==='function'&&!document.querySelector('[data-owner-tool="home"]')){const tile=document.createElement('button');tile.type='button';tile.dataset.ownerTool='home';tile.innerHTML='<strong>客户端设计</strong><span>首页 · 排版 · 文案 · 发布</span>';document.querySelector('.owner-grid')?.append(tile);}
 if(typeof document.createElement==='function'&&!drawer.querySelector('[data-pane="home"]')){const pane=document.createElement('section');pane.className='tool-pane hidden';pane.dataset.pane='home';pane.innerHTML='<div id="homeEditorRoot"></div>';drawer.querySelector('.tool-body')?.append(pane);}
 if(typeof document.createElement==='function'&&!document.querySelector('[data-owner-tool="moon"]')){const tile=document.createElement('button');tile.type='button';tile.dataset.ownerTool='moon';tile.innerHTML='<strong>Moon 旧码录入</strong><span>逐张输入 · 无需会员</span>';document.querySelector('.owner-grid')?.append(tile);}
 if(typeof document.createElement==='function'&&!drawer.querySelector('[data-pane="moon"]')){const pane=document.createElement('section');pane.className='tool-pane hidden';pane.dataset.pane='moon';pane.innerHTML='<div id="moonCodeEditorRoot"></div>';drawer.querySelector('.tool-body')?.append(pane);}
 const reset=createFactoryReset({work,notice,onReset,onOrdersChanged,getBusinessDay,onOwnerEdit});
 function setSub(key){const pane=drawer.querySelector('[data-pane="'+activeKey+'"]');if(!pane)return;for(const sub of pane.querySelectorAll('[data-subpane]'))sub.classList.toggle('hidden',sub.dataset.subpane!==key);for(const b of pane.querySelectorAll('[data-sub]'))b.classList.toggle('active',b.dataset.sub===key);}
 function close(){if(reset.busy)return;ownerReports?.cancel();dayClose?.cancel();pointsAdmin?.cancel();receiptSettings?.cancel();homeEditor?.cancel();loadEpoch++;reset.cancel();overlay.classList.add('hidden');document.body.classList.remove('tool-open');main.inert=false;head.inert=false;activeKey=null;previousFocus?.focus();}
 async function open(key,sub){
  if(key==='dayclose'&&!isCashier()){notice('需要收银权限',true);return;}
  if(!['pin','dayclose'].includes(key)&&!isOwner()){notice('仅限 Owner 使用',true);return;}
  ownerReports?.cancel();dayClose?.cancel();pointsAdmin?.cancel();receiptSettings?.cancel();homeEditor?.cancel();const epoch=++loadEpoch;activeKey=key;previousFocus=document.activeElement;reset.cancel();
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
    if(key==='team')await loadRights();if(key==='loyalty'){const module=await import('./owner-points.js?v=20261012-points-rewards-v18');if(epoch!==loadEpoch)return;pointsAdmin||=module.createPointsAdmin({db,root:$('ownerPointsRoot'),isOwner,notice});await pointsAdmin.load();}
   }
   if(key==='insights'){const module=await import('./owner-reports.js?v=20261010-copy-v15-4');if(epoch!==loadEpoch)return;ownerReports||=module.createOwnerReports({db,root:$('ownerReportsRoot'),isOwner,notice,businessDay:getBusinessDay?.()});await ownerReports.load();}
   if(key==='home'){const module=await import('./home-editor.js?v=20261012-v22');if(epoch!==loadEpoch)return;homeEditor||=module.createHomeEditor({db,root:$('homeEditorRoot'),notice});await homeEditor.load();}
   if(key==='moon'){const module=await import('./moon-code-editor.js?v=20261012-moon-manual-v2');if(epoch!==loadEpoch)return;moonEditor||=module.createMoonCodeEditor({db,root:$('moonCodeEditorRoot'),isOwner,notice});await moonEditor.load();}
   if(key==='receipt'){const module=await import('./receipt-settings.js?v=20261012-v22');if(epoch!==loadEpoch)return;receiptSettings||=module.createReceiptSettings({db,root:$('receiptSettingsRoot'),isOwner,notice});await receiptSettings.load();}
   if(key==='dayclose'){const module=await import('./day-close.js?v=20261010-copy-v15-4');if(epoch!==loadEpoch)return;dayClose||=module.createDayClose({db,root:$('dayCloseRoot'),isOwner,notice,onOrdersChanged,onOwnerEdit:id=>{close();return onOwnerEdit?.(id);}});await dayClose.load();}
   if(key==='factory')await reset.resume();
  }catch(e){notice(e.message||'加载失败，请重试',true);}
 }
 function roleChanged(){
  if(!isOwner()){ownerReports?.clear();pointsAdmin?.clear();receiptSettings?.clear();homeEditor?.cancel();moonEditor?.clear();}dayClose?.clear();for(const b of document.querySelectorAll('[data-cashier-tool]'))b.classList.toggle('hidden',!isCashier());
  for(const button of document.querySelectorAll('[data-go-tab="admin"],[data-owner-tool]'))button.classList.toggle('hidden',!isOwner());
  for(const button of document.querySelectorAll('[data-go-tab="pending"]'))button.classList.toggle('hidden',!isCashier());
  $('workspaceTitle').textContent=isOwner()?'店铺工作台':isCashier()?'收银工作台':'服务工作台';
 }
 document.addEventListener('click',e=>{const daily=e.target.closest('[data-cashier-tool]');if(daily)open(daily.dataset.cashierTool);const tile=e.target.closest('[data-owner-tool]');if(tile)open(tile.dataset.ownerTool,tile.dataset.ownerSub);const sub=e.target.closest('[data-sub]');if(sub)setSub(sub.dataset.sub);});
 $('toolDrawerClose').onclick=close;overlay.onclick=e=>{if(e.target===overlay)close();};
 drawer.addEventListener('keydown',e=>{if(e.key!=='Tab')return;const focusables=[...drawer.querySelectorAll('button,input,select,textarea,a[href]')].filter(el=>!el.disabled&&el.getClientRects().length);const first=focusables[0],last=focusables.at(-1);if(!first){e.preventDefault();return;}if(e.shiftKey&&(document.activeElement===first||document.activeElement===drawer)){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}});
 document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!overlay.classList.contains('hidden')&&$('ops_modalBackdrop').classList.contains('hide'))close();});
 return {open,close,roleChanged};
}
