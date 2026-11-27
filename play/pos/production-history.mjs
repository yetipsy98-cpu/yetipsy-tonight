import {createRefreshGate} from './live-refresh.mjs?v=20261124-live-refresh-v27';
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const sources={order:'现场点单',freeflow:'FREEFLOW',storebox:'存酒箱叫酒'};
const time=v=>new Intl.DateTimeFormat('zh-MY',{timeZone:'Asia/Kuala_Lumpur',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false}).format(new Date(v));
export function createProductionHistory({db,root,getDay,getActor,isActive,notice,canManage=()=>false}){
 let access=null,generation=0,rows=[],total=0,loading=false,loaded=false,more=false,timer=null,searchTimer=null;
 const q=s=>root.querySelector(s);
 const filters=()=>({p_day:q('#kdsHistoryDate').value||getDay(),p_status:q('[data-production-status][aria-pressed=true]')?.dataset.productionStatus||'served',p_source:q('#productionSource').value,p_search:q('#productionSearch').value.trim()});
 const fingerprint=()=>JSON.stringify(filters());
 const gate=createRefreshGate(async()=>{
  if(!getActor())return;const epoch=generation,actor=getActor(),key=fingerprint(),append=more;more=false;loading=true;renderControls();q('#productionHistoryStatus').textContent=rows.length||loaded?'':'正在读取…';
  try{const wanted=append?80:Math.max(80,rows.length),incoming=[];let offset=append?rows.length:0,nextTotal=0;
   do{const result=await db.rpc('yt_kds_production_history',{...filters(),p_offset:offset,p_limit:Math.min(500,wanted-incoming.length)});if(result.error)throw Error(result.error.message);if(epoch!==generation||actor!==getActor()||key!==fingerprint())return;
    access=result.data.permissions||{can_view_cancelled:canManage(),can_view_actor:canManage()};applyAccess();nextTotal=Number(result.data.total);incoming.push(...result.data.rows);offset+=result.data.rows.length;if(!result.data.rows.length)break;
   }while(incoming.length<wanted&&offset<nextTotal);
   rows=append?[...rows,...incoming]:incoming;total=nextTotal;loaded=true;render();
  }catch(e){if(epoch===generation&&actor===getActor()){q('#productionHistoryStatus').textContent='记录暂时无法读取，请重试。';notice(e.message,true);}}
  finally{if(epoch===generation){loading=false;renderControls();}}
 });
 function renderControls(){q('#productionLoadMore').disabled=loading;q('#productionLoadMore').hidden=rows.length>=total;q('#kdsHistoryRefresh').disabled=loading;}
 function render(){const state=filters().p_status,served=state==='served';q('#productionHistoryCount').textContent=`${total} 条记录 · 已显示 ${rows.length} 条`;q('#productionHistoryStatus').textContent='';
  const list=q('#kdsHistoryList'),anchor=readingAnchor(list);const markup=rows.map(r=>({key:String(r.id??`${r.kind}:${r.order_no}:${r.completed_at}:${r.name}`),html:`<article class="kds-ticket production-history-ticket ${r.kind==='freeflow'?'ff-kds':''}"><header><div><span class="kds-source">${sources[r.kind]||'出品'}</span><h3>${esc(r.table_label||'待填桌号')}</h3><small>#${esc(r.order_no||'—')}</small></div><div class="production-event-time"><strong>${time(r.completed_at)}</strong><span>${served?'已出品':'已取消'}</span></div></header><div class="production-history-drink"><h4>${esc(r.name)}</h4><b>× ${Number(r.quantity)}</b></div>${r.note?`<p class="kds-note">备注：${esc(r.note)}</p>`:''}${access?.can_view_cancelled&&r.reason?`<p class="kds-note">取消原因：${esc(r.reason)}</p>`:''}<footer>${access?.can_view_actor?`<span>${served?'出品':'取消'}：${esc(r.actor_name)}</span>`:''}<small>${served?'按实际出品时间':'按取消时间'}</small></footer></article>`}));
  const existing=new Map([...list.children].map(el=>[el.dataset.productionId,el]));let cursor=list.firstElementChild;
  for(const item of markup){let el=existing.get(item.key);existing.delete(item.key);if(!el){const template=document.createElement('template');template.innerHTML=item.html;el=template.content.firstElementChild;el.dataset.productionId=item.key;el._productionMarkup=item.html;}else if(el._productionMarkup!==item.html){const template=document.createElement('template');template.innerHTML=item.html;el.replaceChildren(...template.content.firstElementChild.childNodes);el.className=template.content.firstElementChild.className;el._productionMarkup=item.html;}
   if(el!==cursor)list.insertBefore(el,cursor);cursor=el.nextElementSibling;
  }
  for(const el of existing.values())if(markup.length||el.dataset.productionId)el.remove();
  if(!markup.length){const message=`这个营业日没有符合条件的${served?'出品':'取消'}记录。`;if(list.firstElementChild?.textContent!==message){const empty=document.createElement('div');empty.className='empty';empty.textContent=message;list.replaceChildren(empty);}}
  restoreReadingAnchor(anchor);
  renderControls();
 }
 function readingAnchor(list){
  const view=document.defaultView;let scroller=list.parentElement;
  while(scroller&&scroller!==document.documentElement&&!(scroller.scrollHeight>scroller.clientHeight&&/(auto|scroll)/.test(view.getComputedStyle(scroller).overflowY)))scroller=scroller.parentElement;
  const page=!scroller||scroller===document.documentElement||scroller===document.body;scroller=page?(document.scrollingElement||document.documentElement):scroller;if(scroller.scrollTop<=0)return null;
  const top=page?0:scroller.getBoundingClientRect().top,bottom=page?view.innerHeight:top+scroller.clientHeight;
  const card=[...list.children].find(el=>{const r=el.getBoundingClientRect();return el.dataset.productionId&&r.bottom>top&&r.top<bottom;});return card?{scroller,card,top:card.getBoundingClientRect().top}:null;
 }
 function restoreReadingAnchor(anchor){if(!anchor?.card.isConnected)return;const delta=anchor.card.getBoundingClientRect().top-anchor.top;if(Math.abs(delta)>1)anchor.scroller.scrollTop+=delta;}
 function refresh(){return gate.request();}
 function reset(){generation++;more=false;loaded=false;rows=[];total=0;render();return refresh();}
 function applyAccess(){const manager=access?.can_view_cancelled??canManage();q('[data-production-status=cancelled]').hidden=!manager;q('[data-production-status=cancelled]').classList.toggle('hidden',!manager);q('#productionSearch').placeholder=manager?'桌号、单号、酒款或操作账号':'桌号、单号或酒款';if(!manager){q('[data-production-status=served]').setAttribute('aria-pressed','true');q('[data-production-status=cancelled]').setAttribute('aria-pressed','false');}}
 function mount(){applyAccess();if(!q('#kdsHistoryDate').value)q('#kdsHistoryDate').value=getDay()||'';
  q('#kdsHistoryForm').onsubmit=e=>{e.preventDefault();reset();};q('#kdsHistoryRefresh').onclick=()=>refresh();q('#kdsHistoryDate').onchange=()=>reset();q('#productionSource').onchange=()=>reset();
  q('#productionSearch').oninput=()=>{clearTimeout(searchTimer);searchTimer=setTimeout(reset,200);};
  root.querySelectorAll('[data-production-status]').forEach(b=>b.onclick=()=>{root.querySelectorAll('[data-production-status]').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));reset();});
  q('#productionLoadMore').onclick=()=>{if(loading)return;more=true;refresh();};
 }
 function start(){mount();clearInterval(timer);timer=setInterval(()=>{if(isActive()&&!document.hidden)refresh();},5000);}
 function clear(){generation++;gate.clear();clearInterval(timer);clearTimeout(searchTimer);timer=searchTimer=null;access=null;rows=[];total=0;more=false;loading=false;loaded=false;q('#kdsHistoryList').replaceChildren();q('#productionHistoryCount').textContent='';q('#productionHistoryStatus').textContent='';}
 return {start,refresh,clear};
}
