const money=v=>'RM'+Number(v||0).toFixed(2);
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const errs={ambassador_member_only:'此会员账号没有 Ambassador 权限',invalid_reservation_day:'请选择有效的预约营业日',invalid_planned_pax:'预登记人数需介于 1 至 500',pass_not_editable:'已有核销后不能修改 Pass'};
const errorText=e=>errs[e?.message]||String(e?.message||e||'操作失败').replaceAll('_',' ');
const css=String.raw`
.yta-client-entry{display:none!important}.yta-client-entry.ready{display:flex!important;width:100%;align-items:center;justify-content:space-between;padding:14px 16px;border:1px solid #c5a56c;border-radius:15px;background:linear-gradient(110deg,#23372c,#17271f);color:#f3e1b6;text-align:left;cursor:pointer}
.yta-client-entry strong{display:block;font-size:1rem}.yta-client-entry small{display:block;color:#c2c9c0;margin-top:3px}
.yta-client-pass{border:1px solid #3e5a4c;background:#162b22;border-radius:16px;padding:15px;margin:12px 0}.yta-client-pass .code{font:600 .78rem ui-monospace,monospace;word-break:break-all;color:#e2c385}
.yta-client-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}
@media(max-width:600px){.yta-client-grid{grid-template-columns:1fr}}
`;
function addStyle(){if(document.getElementById('ytaClientStyles'))return;const s=document.createElement('style');s.id='ytaClientStyles';s.textContent=css;document.head.append(s);}
function overlay(){
 let el=document.getElementById('ytaClientOverlay');if(el)return el;
 el=document.createElement('div');el.id='ytaClientOverlay';el.className='yta-overlay';el.innerHTML='<section class="yta-dialog" role="dialog" aria-modal="true"><header class="yta-head"><div><p class="yta-kicker">MEMBER · AMBASSADOR</p><h2>Ambassador 工作台</h2></div><button type="button" class="yta-close" data-yta-client-close>关闭</button></header><div class="yta-body" id="ytaClientBody"></div></section>';
 el.addEventListener('click',e=>{if(e.target===el||e.target.closest('[data-yta-client-close]'))el.classList.remove('open');});document.body.append(el);return el;
}
async function qrLib(){if(window.qrcode)return;await new Promise((resolve,reject)=>{const s=document.createElement('script');s.src='https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js';s.onload=resolve;s.onerror=()=>reject(Error('二维码组件载入失败'));document.head.append(s);});}
function qr(code){try{if(!window.qrcode)return '<p class="yta-muted">二维码载入中…</p>';const q=window.qrcode(0,'M');q.addData('YTAMB:'+code);q.make();return '<div class="yta-qr">'+q.createImgTag(5,8)+'</div>';}catch{return '<p class="yta-muted">二维码暂时无法生成，请复制下方代码。</p>';}}
export function createAmbassadorClient({db,toast=()=>{}}){
 addStyle();const host=document.querySelector('#homePage .home-shortcuts')||document.getElementById('homePage');if(!host)return {refresh:async()=>{}};
 let button=document.getElementById('ambassadorClientEntry');
 if(!button){button=document.createElement('button');button.id='ambassadorClientEntry';button.type='button';button.className='yta-client-entry';button.innerHTML='<span><strong>Ambassador</strong><small>预登记 Pass · 查看佣金</small></span><span>↗</span>';host.prepend(button);}
 const modal=overlay(),body=document.getElementById('ytaClientBody');let data=null,editing=null,openCode=null;
 const notify=(e)=>toast(errorText(e),true);
 button.onclick=()=>open().catch(notify);
 async function refresh(){
  if(!db){button.classList.remove('ready');return;}
  const session=await db.auth.getSession().catch(()=>null);if(!session?.data?.session){button.classList.remove('ready');return;}
  const r=await db.rpc('yt_ambassador_portal');if(r.error){button.classList.remove('ready');return;}
  data=r.data||{};button.classList.toggle('ready',data.enabled===true);return data;
 }
 function ratesFor(day){
  const special=data?.prices?.specials?.find(x=>x.business_day===day);if(special)return {male:Number(special.male),female:Number(special.female),name:'特别日期'};
  const dow=new Date(day+'T00:00:00Z').getUTCDay(),weekend=dow===5||dow===6,p=data?.prices||{};
  return weekend?{male:Number(p.weekend_male||0),female:Number(p.weekend_female||0),name:'周末'}:{male:Number(p.weekday_male||0),female:Number(p.weekday_female||0),name:'平日'};
 }
 function passCard(x){
  const current=x.id===openCode;
  return '<article class="yta-client-pass"><div class="yta-row"><strong>'+esc(x.reservation_day)+' · '+esc(x.pass_type==='individual'?'Individual':'Group')+'</strong><span class="yta-muted">'+(x.status==='issued'?'有效':'已取消')+'</span></div><p class="yta-muted">预登记 '+Number(x.planned_pax)+' 位 · 已核销 '+Number(x.checked_pax||0)+' 位'+(Number(x.checked_pax||0)>Number(x.planned_pax)?' · 已超过预登记人数':'')+'</p>'+(x.guest_name?'<p>'+esc(x.guest_name)+(x.guest_phone?' · '+esc(x.guest_phone):'')+'</p>':'')+(x.remark?'<p class="yta-muted">'+esc(x.remark)+'</p>':'')+(x.status==='issued'?'<div class="code">YTAMB:'+esc(x.pass_code)+'</div>'+ (current?qr(x.pass_code):'')+'<div class="yta-actions">'+(Number(x.checked_pax||0)===0?'<button class="yta-btn" type="button" data-pass-edit="'+esc(x.id)+'">修改预登记</button>':'')+'<button class="yta-btn" type="button" data-pass-show="'+esc(x.id)+'">'+(current?'隐藏二维码':'显示二维码')+'</button></div>':'')+'</article>';
 }
 function render(){
  const a=data.ambassador||{},p=data.prices||{},d=data.business_day||'',rates=ratesFor(d);
  body.innerHTML='<div class="yta-grid"><section class="yta-card"><p class="yta-kicker">COMMISSION WALLET</p><h3>'+esc(a.display_name||'Ambassador')+'</h3><div class="yta-metric">'+money(data.wallet_balance)+'</div><p class="yta-muted">佣金比例 '+Number(a.commission_rate||0).toFixed(2)+'% · 已核销销售按男女人数及对应价格计算。</p></section><section class="yta-card"><p class="yta-kicker">PRICE GUIDE</p><h3>'+esc(rates.name)+' · '+esc(d)+'</h3><p>男士 '+money(rates.male)+'　女士 '+money(rates.female)+'</p><p class="yta-muted">营业日以店铺 cutoff 计算，当前规则由 Owner 设置。</p></section></div><section class="yta-card"><h3>'+(editing?'修改预登记':'预登记新 Pass')+'</h3><form id="ytaClientPassForm" class="yta-form"><input type="hidden" name="id" value="'+esc(editing?.id||'')+'"><label>预约营业日<input id="ytaClientDay" name="reservation_day" type="date" min="'+esc(d)+'" max="'+esc(new Date(new Date(d+'T00:00:00Z').getTime()+180*86400000).toISOString().slice(0,10))+'" value="'+esc(editing?.reservation_day||d)+'" required></label><p id="ytaClientPriceHint" class="yta-muted"></p><div class="yta-client-grid"><label>预登记人数<input name="planned_pax" type="number" min="1" max="500" step="1" value="'+esc(editing?.planned_pax||1)+'" required></label><label>Pass 类型<select name="pass_type"><option value="group"'+(!editing||editing.pass_type==='group'?' selected':'')+'>Group</option><option value="individual"'+(editing?.pass_type==='individual'?' selected':'')+'>Individual</option></select></label><label>顾客姓名（选填）<input name="guest_name" maxlength="100" value="'+esc(editing?.guest_name||'')+'"></label><label>联系方式（选填）<input name="guest_phone" maxlength="40" value="'+esc(editing?.guest_phone||'')+'"></label></div><label>备注（选填）<textarea name="remark" maxlength="500" rows="2">'+esc(editing?.remark||'')+'</textarea></label><div class="yta-actions"><button class="yta-btn gold" type="submit">'+(editing?'保存修改':'生成 Pass 二维码')+'</button>'+(editing?'<button class="yta-btn" type="button" id="ytaClientCancelEdit">取消</button>':'')+'</div></form></section><section class="yta-card"><div class="yta-row"><h3>我的 Pass</h3><span class="yta-muted">'+(data.passes||[]).length+' 个</span></div>'+((data.passes||[]).length?(data.passes||[]).map(passCard).join(''):'<p class="yta-muted">还没有预登记 Pass。</p>')+'</section>';
  const form=document.getElementById('ytaClientPassForm');const hint=document.getElementById('ytaClientPriceHint'),day=document.getElementById('ytaClientDay');
  const updatePrice=()=>{const r=ratesFor(day.value||d);hint.textContent=r.name+'价格：男士 '+money(r.male)+' · 女士 '+money(r.female);};day.onchange=updatePrice;updatePrice();
  form.onsubmit=savePass;body.querySelectorAll('[data-pass-show]').forEach(b=>b.onclick=()=>{openCode=openCode===b.dataset.passShow?null:b.dataset.passShow;render();if(openCode)ensureQR().then(()=>render());});
  body.querySelectorAll('[data-pass-edit]').forEach(b=>b.onclick=()=>{editing=data.passes.find(x=>x.id===b.dataset.passEdit);render();});
  document.getElementById('ytaClientCancelEdit')?.addEventListener('click',()=>{editing=null;render();});
 }
 async function ensureQR(){try{await qrLib();}catch{}}
 async function savePass(e){
  e.preventDefault();const f=new FormData(e.currentTarget),payload={id:f.get('id')||null,reservation_day:f.get('reservation_day'),planned_pax:Number(f.get('planned_pax')),pass_type:f.get('pass_type'),guest_name:f.get('guest_name'),guest_phone:f.get('guest_phone'),remark:f.get('remark')};
  const btn=e.submitter;btn.disabled=true;const r=await db.rpc('yt_ambassador_pass_save',{p_payload:payload});btn.disabled=false;if(r.error)throw r.error;
  editing=null;openCode=r.data?.id||null;await refresh();render();if(openCode){await ensureQR();render();}
 }
 async function open(){await refresh();if(!data?.enabled)throw Error('ambassador_member_only');modal.classList.add('open');await ensureQR();render();}
 const auth=db?.auth?.onAuthStateChange?.((_e,session)=>{setTimeout(()=>{if(session)refresh().catch(()=>{});else button.classList.remove('ready');},0);});
 refresh().catch(()=>{});
 return {refresh,open,destroy(){if(auth?.data?.subscription)auth.data.subscription.unsubscribe();button.remove();modal.remove();}};
}

