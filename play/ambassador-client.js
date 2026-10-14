const money=v=>'RM'+Number(v||0).toFixed(2);
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const errs={ambassador_member_only:'此会员账号没有 Ambassador 权限',invalid_reservation_day:'请选择有效的预约营业日',invalid_planned_pax:'预登记人数需介于 1 至 500',pass_not_editable:'已有核销后不能修改 Pass'};
const errorText=e=>errs[e?.message]||String(e?.message||e||'操作失败').replaceAll('_',' ');
const css=String.raw`
.yta-overlay{position:fixed;inset:0;z-index:9999;background:#06100de8;display:none;align-items:center;justify-content:center;padding:14px;backdrop-filter:blur(8px)}
.yta-overlay.open{display:flex}.yta-dialog{box-sizing:border-box;width:min(760px,100%);max-height:min(92dvh,900px);overflow:auto;background:#12241d;color:#f4f1e8;border:1px solid #476455;border-radius:22px;box-shadow:0 24px 80px #0009;padding:20px}
.yta-head{display:flex;justify-content:space-between;align-items:center;gap:12px;border-bottom:1px solid #294337;padding-bottom:12px;margin-bottom:16px}
.yta-head h2{font-size:1.25rem;margin:0}.yta-kicker{color:#d6b879;font-size:.72rem;letter-spacing:.13em;font-weight:700;margin:0 0 6px}
.yta-close,.yta-btn{border:1px solid #506d5d;border-radius:12px;background:#1b3429;color:#f4f1e8;padding:11px 14px;cursor:pointer;font:inherit}
.yta-btn.gold{background:#e2c385;color:#15231c;border-color:#e2c385;font-weight:800}.yta-btn:disabled{opacity:.55;cursor:wait}
.yta-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.yta-card,.yta-client-pass{border:1px solid #3e5a4c;background:#162b22;border-radius:16px;padding:15px;margin:10px 0}
.yta-card h3{margin:0 0 12px;font-size:1.05rem}.yta-muted{color:#b8c5bd;font-size:.88rem}.yta-row{display:flex;align-items:center;justify-content:space-between;gap:10px}.yta-actions{display:flex;flex-wrap:wrap;gap:8px;margin-top:12px}
.yta-form{display:grid;gap:10px}.yta-form label{display:grid;gap:5px;font-size:.88rem;color:#d5ddd7}.yta-form input,.yta-form select,.yta-form textarea{box-sizing:border-box;width:100%;padding:11px 12px;border:1px solid #547161;border-radius:11px;background:#0e1d16;color:#f4f1e8;font:inherit}
.yta-pair{display:grid;grid-template-columns:1fr 1fr;gap:10px}.yta-metric{font-size:1.4rem;color:#e5c98e;font-weight:800}.yta-qr{display:flex;justify-content:center;margin:12px auto}.yta-qr img{width:180px;height:180px;background:#fff;padding:7px;border-radius:10px}
.yta-client-pass .code{font:600 .78rem ui-monospace,monospace;word-break:break-all;color:#e2c385}.yta-pass-ticket{margin:12px auto;padding:18px;max-width:340px;border:1px solid #d8bc7d;border-radius:18px;background:radial-gradient(circle at top,#293f32,#101d16 72%);text-align:center}.yta-pass-brand{color:#e4ca91;font-weight:900;letter-spacing:.18em}.yta-pass-ticket h4{margin:8px 0 4px;color:#f4f1e8;font-size:1.05rem}.yta-pass-ticket .yta-qr{display:flex;justify-content:center;margin:14px auto 8px}.yta-pass-ticket .yta-qr img{width:190px;height:190px;background:#fff;padding:8px;border-radius:12px}.yta-pass-ticket .yta-pass-meta{color:#c2cbc4;font-size:.84rem;line-height:1.5}.yta-pass-ticket .yta-actions{justify-content:center}
.yta-client-entry{display:none!important}.yta-client-entry.ready{display:flex!important;grid-column:1/-1;width:100%;align-items:center;justify-content:space-between;padding:14px 16px;border:1px solid #c5a56c;border-radius:15px;background:linear-gradient(110deg,#23372c,#17271f);color:#f3e1b6;text-align:left;cursor:pointer}
.yta-client-entry strong{display:block;font-size:1rem}.yta-client-entry small{display:block;color:#c2c9c0;margin-top:3px}
.yta-client-pass{border:1px solid #3e5a4c;background:#162b22;border-radius:16px;padding:15px;margin:12px 0}.yta-client-pass .code{font:600 .78rem ui-monospace,monospace;word-break:break-all;color:#e2c385}
.yta-client-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}
@media(max-width:600px){.yta-client-grid,.yta-grid,.yta-pair{grid-template-columns:1fr}.yta-overlay{padding:0;align-items:flex-end}.yta-dialog{max-height:94dvh;border-radius:20px 20px 0 0;padding:16px 14px calc(18px + env(safe-area-inset-bottom))}.yta-qr img{width:160px;height:160px}}
`;
function addStyle(){if(document.getElementById('ytaClientStyles'))return;const s=document.createElement('style');s.id='ytaClientStyles';s.textContent=css;document.head.append(s);}
function overlay(){
 let el=document.getElementById('ytaClientOverlay');if(el)return el;
 el=document.createElement('div');el.id='ytaClientOverlay';el.className='yta-overlay';el.innerHTML='<section class="yta-dialog" role="dialog" aria-modal="true"><header class="yta-head"><div><p class="yta-kicker">MEMBER · AMBASSADOR</p><h2>Ambassador 工作台</h2></div><button type="button" class="yta-close" data-yta-client-close>关闭</button></header><div class="yta-body" id="ytaClientBody"></div></section>';
 el.addEventListener('click',e=>{if(e.target===el||e.target.closest('[data-yta-client-close]'))el.classList.remove('open');});document.body.append(el);return el;
}
async function qrLib(){if(window.qrcode)return;await new Promise((resolve,reject)=>{const s=document.createElement('script');s.src='https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js';s.onload=resolve;s.onerror=()=>reject(Error('二维码组件载入失败'));document.head.append(s);});}
function qr(x,share=true){try{if(!window.qrcode)return '<p class="yta-muted">二维码载入中…</p>';const q=window.qrcode(0,'M');q.addData('YTAMB:'+x.pass_code);q.make();return '<div class="yta-pass-ticket"><div class="yta-pass-brand">YE · TIPSY</div><h4>FREE FLOW PASS</h4><div class="yta-pass-meta">'+esc(x.reservation_day)+' · '+esc(x.pass_type==='individual'?'Individual':'Group')+'<br>预登记 '+Number(x.planned_pax||0)+' 位'+(x.guest_name?'<br>'+esc(x.guest_name):'')+'</div><div class="yta-qr">'+q.createImgTag(5,8)+'</div><div class="yta-pass-meta">预约营业日有效 · 出示此二维码核销</div><div class="yta-actions"><button class="yta-btn gold" type="button" data-pass-share="'+esc(x.id)+'">分享二维码</button></div></div>';}catch{return '<p class="yta-muted">二维码暂时无法生成，请复制下方代码。</p>';}}
async function sharePassCard(x){await qrLib();const q=window.qrcode(0,'M');q.addData('YTAMB:'+x.pass_code);q.make();const src=q.createDataURL(8,4),img=new Image();img.src=src;await new Promise((ok,no)=>{img.onload=ok;img.onerror=no;});const canvas=document.createElement('canvas');canvas.width=1080;canvas.height=1350;const c=canvas.getContext('2d');c.fillStyle='#101d16';c.fillRect(0,0,1080,1350);c.strokeStyle='#d8bc7d';c.lineWidth=4;c.strokeRect(34,34,1012,1282);c.textAlign='center';c.fillStyle='#e4ca91';c.font='900 46px system-ui';c.fillText('YE · TIPSY',540,130);c.fillStyle='#f4f1e8';c.font='800 58px system-ui';c.fillText('FREE FLOW PASS',540,235);c.fillStyle='#d4ddd6';c.font='32px system-ui';c.fillText(x.reservation_day+'  ·  '+(x.pass_type==='individual'?'Individual':'Group'),540,300);c.font='30px system-ui';c.fillText('预登记 '+Number(x.planned_pax||0)+' 位'+(x.guest_name?'  ·  '+String(x.guest_name).slice(0,18):''),540,352);c.fillStyle='#fff';c.fillRect(210,410,660,660);c.drawImage(img,230,430,620,620);c.fillStyle='#d4ddd6';c.font='30px system-ui';c.fillText('预约营业日有效 · 出示二维码核销',540,1150);c.fillStyle='#e4ca91';c.font='22px system-ui';c.fillText('YTAMB:'+x.pass_code,540,1220);const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/png'));if(!blob)throw Error('二维码图片生成失败');const file=new File([blob],'Yetipsy-Freeflow-Pass.png',{type:'image/png'}),title='Yetipsy Free Flow Pass',text=x.reservation_day+' · '+(x.pass_type==='individual'?'Individual':'Group')+' · '+Number(x.planned_pax||0)+' 位';if(navigator.share&&navigator.canShare?.({files:[file]}))await navigator.share({files:[file],title,text});else{const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=file.name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);toast('已下载二维码卡片，可从相册分享。',false);}}
export function createAmbassadorClient({db,toast=()=>{}}){
 addStyle();const host=document.querySelector('#homePage .home-shortcuts')||document.getElementById('homePage');if(!host)return {refresh:async()=>{}};
 let button=document.getElementById('ambassadorClientEntry');
 if(!button){button=document.createElement('button');button.id='ambassadorClientEntry';button.type='button';button.className='yta-client-entry';button.innerHTML='<span><strong>Ambassador</strong><small>预登记 Pass · 查看佣金</small></span><span>↗</span>';host.append(button);}
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
  return '<article class="yta-client-pass"><div class="yta-row"><strong>'+esc(x.reservation_day)+' · '+esc(x.pass_type==='individual'?'Individual':'Group')+'</strong><span class="yta-muted">'+(x.status==='issued'?'有效':'已取消')+'</span></div><p class="yta-muted">预登记 '+Number(x.planned_pax)+' 位 · 已核销 '+Number(x.checked_pax||0)+' 位'+(Number(x.checked_pax||0)>Number(x.planned_pax)?' · 已超过预登记人数':'')+'</p>'+(x.guest_name?'<p>'+esc(x.guest_name)+(x.guest_phone?' · '+esc(x.guest_phone):'')+'</p>':'')+(x.remark?'<p class="yta-muted">'+esc(x.remark)+'</p>':'')+(x.status==='issued'?'<div class="code">YTAMB:'+esc(x.pass_code)+'</div>'+ (current?qr(x,true):'')+'<div class="yta-actions">'+(Number(x.checked_pax||0)===0?'<button class="yta-btn" type="button" data-pass-edit="'+esc(x.id)+'">修改预登记</button>':'')+'<button class="yta-btn" type="button" data-pass-show="'+esc(x.id)+'">'+(current?'隐藏二维码':'显示二维码')+'</button></div>':'')+'</article>';
 }
 function render(){
  const a=data.ambassador||{},p=data.prices||{},d=data.business_day||'',rates=ratesFor(d);
  body.innerHTML='<div class="yta-grid"><section class="yta-card"><p class="yta-kicker">COMMISSION WALLET</p><h3>'+esc(a.display_name||'Ambassador')+'</h3><div class="yta-metric">'+money(data.wallet_balance)+'</div><p class="yta-muted">佣金比例 '+Number(a.commission_rate||0).toFixed(2)+'% · 已核销销售按男女人数及对应价格计算。</p></section><section class="yta-card"><p class="yta-kicker">PRICE GUIDE</p><h3>'+esc(rates.name)+' · '+esc(d)+'</h3><p>男士 '+money(rates.male)+'　女士 '+money(rates.female)+'</p><p class="yta-muted">营业日以店铺 cutoff 计算，当前规则由 Owner 设置。</p></section></div><section class="yta-card"><h3>'+(editing?'修改预登记':'预登记新 Pass')+'</h3><form id="ytaClientPassForm" class="yta-form"><input type="hidden" name="id" value="'+esc(editing?.id||'')+'"><label>预约营业日<input id="ytaClientDay" name="reservation_day" type="date" min="'+esc(d)+'" max="'+esc(new Date(new Date(d+'T00:00:00Z').getTime()+180*86400000).toISOString().slice(0,10))+'" value="'+esc(editing?.reservation_day||d)+'" required></label><p id="ytaClientPriceHint" class="yta-muted"></p><div class="yta-client-grid"><label>预登记人数<input name="planned_pax" type="number" min="1" max="500" step="1" value="'+esc(editing?.planned_pax||1)+'" required></label><label>Pass 类型<select name="pass_type"><option value="group"'+(!editing||editing.pass_type==='group'?' selected':'')+'>Group</option><option value="individual"'+(editing?.pass_type==='individual'?' selected':'')+'>Individual</option></select></label><label>顾客姓名（选填）<input name="guest_name" maxlength="100" value="'+esc(editing?.guest_name||'')+'"></label><label>联系方式（选填）<input name="guest_phone" maxlength="40" value="'+esc(editing?.guest_phone||'')+'"></label></div><label>备注（选填）<textarea name="remark" maxlength="500" rows="2">'+esc(editing?.remark||'')+'</textarea></label><div class="yta-actions"><button class="yta-btn gold" type="submit">'+(editing?'保存修改':'生成 Pass 二维码')+'</button>'+(editing?'<button class="yta-btn" type="button" id="ytaClientCancelEdit">取消</button>':'')+'</div></form></section><section class="yta-card"><div class="yta-row"><h3>我的 Pass</h3><span class="yta-muted">'+(data.passes||[]).length+' 个</span></div>'+((data.passes||[]).length?(data.passes||[]).map(passCard).join(''):'<p class="yta-muted">还没有预登记 Pass。</p>')+'</section>';
  const form=document.getElementById('ytaClientPassForm');const hint=document.getElementById('ytaClientPriceHint'),day=document.getElementById('ytaClientDay');
  const updatePrice=()=>{const r=ratesFor(day.value||d);hint.textContent=r.name+'价格：男士 '+money(r.male)+' · 女士 '+money(r.female);};day.onchange=updatePrice;updatePrice();
  form.onsubmit=savePass;body.querySelectorAll('[data-pass-show]').forEach(b=>b.onclick=()=>{openCode=openCode===b.dataset.passShow?null:b.dataset.passShow;render();if(openCode)ensureQR().then(()=>render());});
  body.querySelectorAll('[data-pass-share]').forEach(b=>b.onclick=()=>{const x=data.passes.find(v=>v.id===b.dataset.passShare);if(x)sharePassCard(x).catch(notify);});body.querySelectorAll('[data-pass-edit]').forEach(b=>b.onclick=()=>{editing=data.passes.find(x=>x.id===b.dataset.passEdit);render();});
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


