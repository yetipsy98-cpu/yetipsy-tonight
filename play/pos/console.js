import {createFactoryReset} from './factory-reset.js?v=20261009-console-v7-1';
const $=id=>document.getElementById(id);
const titles={catalog:'商品与系列',rewards:'奖励',team:'团队与权限',campaign:'活动与奖池',loyalty:'会员与积分',banners:'轮播广告',insights:'运营概览',factory:'系统重置',pin:'顾客 PIN 重设'};
export function createConsole({db,work,isOwner,isCashier,loadAdmin,loadOffers,loadRights,notice,onReset}){
 let previousFocus=null,activeKey=null,loadEpoch=0,ownerTools=null;
 const overlay=$('toolDrawerOverlay'),drawer=$('toolDrawer'),main=document.querySelector('main'),head=document.querySelector('.site-head');
 const reset=createFactoryReset({work,notice,onReset});
 function setSub(key){const pane=drawer.querySelector('[data-pane="'+activeKey+'"]');if(!pane)return;for(const sub of pane.querySelectorAll('[data-subpane]'))sub.classList.toggle('hidden',sub.dataset.subpane!==key);for(const b of pane.querySelectorAll('[data-sub]'))b.classList.toggle('active',b.dataset.sub===key);}
 function close(){if(reset.busy)return;loadEpoch++;reset.cancel();overlay.classList.add('hidden');document.body.classList.remove('tool-open');main.inert=false;head.inert=false;activeKey=null;previousFocus?.focus();}
 async function open(key,sub){
  if(key!=='pin'&&!isOwner()){notice('仅限 Owner 使用',true);return;}
  const epoch=++loadEpoch;activeKey=key;previousFocus=document.activeElement;reset.cancel();
  $('toolDrawerTitle').textContent=titles[key]||'工具';for(const p of drawer.querySelectorAll('[data-pane]'))p.classList.toggle('hidden',p.dataset.pane!==key);
  if(key==='pin')$('tab-reset').classList.remove('hidden');
  if(sub)setSub(sub);else{const first=drawer.querySelector('[data-pane="'+key+'"] [data-sub]');if(first)setSub(first.dataset.sub);}
  overlay.classList.remove('hidden');document.body.classList.add('tool-open');main.inert=true;head.inert=true;drawer.focus();
  try{
   if(['catalog','rewards','team','banners'].includes(key))await loadAdmin();
   if(epoch!==loadEpoch)return;if(key==='rewards')await loadOffers();
   if(['team','campaign','loyalty','insights'].includes(key)){
    ownerTools||=await import('../shared/owner-tools.js?v=20261009-console-v7-1');if(epoch!==loadEpoch)return;
    const identityResult=await db.rpc('yt_pos_identity');if(identityResult.error)throw identityResult.error;
    if(!identityResult.data?.can_owner)throw Error('owner_only');ownerTools.initOwnerTools(db,identityResult.data);await ownerTools.loadOwnerTool(key);
    if(key==='team')await loadRights();
   }
   if(key==='factory')await reset.resume();
  }catch(e){notice(e.message||'加载失败，请重试',true);}
 }
 function roleChanged(){
  for(const button of document.querySelectorAll('[data-go-tab="admin"],[data-owner-tool]'))button.classList.toggle('hidden',!isOwner());
  for(const button of document.querySelectorAll('[data-go-tab="pending"]'))button.classList.toggle('hidden',!isCashier());
  $('workspaceTitle').textContent=isOwner()?'店铺工作台':isCashier()?'收银工作台':'服务工作台';
 }
 document.addEventListener('click',e=>{const tile=e.target.closest('[data-owner-tool]');if(tile)open(tile.dataset.ownerTool);const sub=e.target.closest('[data-sub]');if(sub)setSub(sub.dataset.sub);});
 $('toolDrawerClose').onclick=close;overlay.onclick=e=>{if(e.target===overlay)close();};
 drawer.addEventListener('keydown',e=>{if(e.key!=='Tab')return;const focusables=[...drawer.querySelectorAll('button,input,select,textarea,a[href]')].filter(el=>!el.disabled&&el.getClientRects().length);const first=focusables[0],last=focusables.at(-1);if(!first){e.preventDefault();return;}if(e.shiftKey&&(document.activeElement===first||document.activeElement===drawer)){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}});
 document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!overlay.classList.contains('hidden')&&$('ops_modalBackdrop').classList.contains('hide'))close();});
 return {open,close,roleChanged};
}
