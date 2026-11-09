import {ffError,freezeFreeflowRequest,freeflowLabels} from './freeflow-core.mjs?v=20261110-freeflow-v1';
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const time=v=>new Intl.DateTimeFormat('zh-MY',{timeZone:'Asia/Kuala_Lumpur',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false}).format(new Date(v));
export function createCustomerFreeflow({db,getUser,showSheet,sheetHtml,toast,openScanner}){
 let timer=null,button=null,epoch=0,inflight=false;
 const rpc=async(action,data={})=>{const r=await db.rpc('yt_freeflow',{p_action:action,p_data:data});if(r.error)throw Error(r.error.message);return r.data;};
 function mount(){if(button)return;button=document.createElement('button');button.type='button';button.id='accountFreeflow';button.innerHTML='<span>🍸</span><b>FREEFLOW · 自助点单</b><i>↗</i>';button.onclick=()=>open().catch(e=>toast(ffError(e),true));document.querySelector('#accountPage .account-actions')?.prepend(button);
 const home=document.createElement('button');home.type='button';home.className='button button-outline wide';home.id='homeFreeflow';home.textContent='🍸 FreeFlow · 自助点单';home.onclick=button.onclick;document.querySelector('#homePage .page-wrap, #homePage .home-content, #homePage')?.append(home);}
 async function bind(token){if(!getUser())throw Error('请先登录会员。');await rpc('bind',{token});const u=new URL(location.href);u.searchParams.delete('freeflow');history.replaceState(null,'',u.href);toast('FreeFlow 已绑定，桌号由 Cashier 设置。');await open();}
 async function open(){clearInterval(timer);mount();const view=++epoch;showSheet('FreeFlow 自助点单','ONE CUP AT A TIME');sheetHtml('<div class="sheet-content" id="freeflowCustomer"><p>正在读取…</p></div>');
 async function refresh(){const actor=getUser()?.id;if(!actor)return;const data=await rpc('mine');if(view!==epoch)return;if(getUser()?.id!==actor||!document.getElementById('freeflowCustomer')||document.getElementById('sheetBackdrop')?.classList.contains('hide')){clearInterval(timer);return;}
 const root=document.getElementById('freeflowCustomer');if(inflight)return;
 root.innerHTML='<p class="tiny-help">每次一杯，店员确认出品后即可继续。桌号由 Cashier 设置。</p><button type="button" class="button button-outline wide" id="ffScanBind">扫描 Cashier 绑定码</button>'+(data.length?data.map(s=>`<article class="ff-customer-card"><div class="ff-card-head"><h3>${esc(s.name)}</h3><span>${esc(freeflowLabels[s.status]||s.status)}</span></div><p>桌号 <strong>${esc(s.table_label)}</strong> · 有效至 ${esc(time(s.ends_at))}</p><div class="ff-cup-total"><strong>${Number(s.cups)}</strong><span>本场已享用 / 杯</span></div><p>${s.drinks.map(d=>esc(d.name)+' × '+Number(d.quantity)).join(' · ')||'还没有已出品饮品'}</p>${s.pending?`<div class="ff-pending">${esc(s.pending.name)} · 待出品<br><small>确认出品后解锁下一杯</small></div>`:s.status==='active'?`<div class="ff-drink-grid">${s.products.map(p=>`<button type="button" class="button button-outline" data-ff-drink="${esc(p.id)}" data-ff-member="${esc(s.member_id)}">${esc(p.name)}<small>点一杯 ↗</small></button>`).join('')||'<p>暂无可供应酒款，请联系店员。</p>'}</div>`:`<p>${esc(freeflowLabels[s.status])}</p>`}</article>`).join(''):'<p>尚未绑定 FreeFlow。请先让 Cashier 完成挂单或结账，再扫码绑定。</p>');
 root.querySelector('#ffScanBind').onclick=()=>{clearInterval(timer);openScanner();};
 root.querySelectorAll('[data-ff-drink]').forEach(b=>b.onclick=()=>order(b,view,refresh));
 }
 await refresh();if(view===epoch)timer=setInterval(()=>{if(document.hidden)return;refresh().catch(()=>{});},5000);
 }
 async function order(b,view,refresh){if(inflight)return;inflight=true;const root=document.getElementById('freeflowCustomer');root?.querySelectorAll('button').forEach(x=>x.disabled=true);const key='yt-ff-order:'+getUser().id;let accepted=false;
 try{const draft=freezeFreeflowRequest(sessionStorage,key,b.dataset.ffMember,b.dataset.ffDrink);b.textContent='正在定位…';if(!navigator.geolocation)throw Error('location_required');const p=await new Promise((ok,no)=>navigator.geolocation.getCurrentPosition(ok,no,{enableHighAccuracy:true,timeout:12000,maximumAge:0}));if(view!==epoch)return;await rpc('order',{...draft,lat:p.coords.latitude,lng:p.coords.longitude});accepted=true;sessionStorage.removeItem(key);toast('已送到吧台，请等待出品。');}
 catch(e){if(e.code===1||e.code===2||e.code===3)toast('定位失败，请允许定位并重新尝试。',true);else toast(ffError(e),true);}
 finally{inflight=false;if(view===epoch){try{await refresh();}catch{root?.querySelectorAll('button').forEach(x=>x.disabled=false);toast(accepted?'订单已提交，状态刷新失败，请重新打开 FreeFlow 查看。':'请重新打开 FreeFlow 查看状态。',true);}}}
 }
 function clear(){epoch++;clearInterval(timer);inflight=false;}
 return {mount,open,bind,clear};
}
