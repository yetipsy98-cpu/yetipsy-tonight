const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
class El{constructor(){this.value='';this.disabled=false;this.checked=false;this.innerHTML='';this.textContent='';this.classList={toggle(){},add(){},remove(){}};}replaceChildren(){this.innerHTML='';}querySelector(){return new El();}scrollIntoView(){}}
const keys=['range','day','today','status','summary','pending','close','closed','resolve','settings','cutoffForm','cutoff','cutoffNote','opening','out','actual','notes','confirmed','expected','submit'];
const els=Object.fromEntries(keys.map(k=>[k,new El()]));const root={innerHTML:'',querySelector:s=>els[s.match(/data-dc="([^"]+)"/)?.[1]]||new El(),querySelectorAll:()=>Object.values(els),addEventListener(){}};
let owner=true,notices=[],calls=[],response,fail=false;const ctx={console,Date,Number,crypto:require('node:crypto').webcrypto,confirm:()=>true};vm.createContext(ctx);vm.runInContext(fs.readFileSync('play/pos/day-close.js','utf8').replace(/export /g,'')+'\nglobalThis.create=createDayClose;',ctx);
const sample={day:'2026-10-09',start_at:'2026-10-08T22:00:00Z',end_at:'2026-10-09T22:00:00Z',context:{cutoff_minutes:360},stats:{net_rm:70,cash_rm:20,orders:2,refunded_rm:0},methods:[{method:'cash',net_rm:20},{method:'duitnow',net_rm:50}],pending_count:1,blocker_count:0,pending:[{id:'order1',order_no:'<script>',table_label:'T1',created_at:'2026-10-09T01:00:00Z',amount_rm:10,overdue:false}],fingerprint:'f1'};
response=sample;const api=ctx.create({root,isOwner:()=>owner,notice:(m,b)=>notices.push({m,b}),db:{rpc:async(name,args)=>{calls.push({name,args});if(fail)return{error:{message:'cashier_only'}};return{data:name==='yt_pos_day_preview'?response:{}};}}});
const tick=()=>new Promise(setImmediate);
(async()=>{
 await api.load();assert.equal(calls[0].name,'yt_pos_day_preview');assert.equal(els.day.value,'2026-10-09');assert(els.summary.innerHTML.includes('RM 70.00'));assert(els.pending.innerHTML.includes('&lt;script&gt;'));assert(!els.pending.innerHTML.includes('<script>'));assert(!els.submit.disabled);
 els.opening.value='100';els.out.value='10';els.actual.value='110';els.opening.oninput();assert(els.expected.textContent.includes('RM 110.00'));assert(els.expected.textContent.includes('差额 RM 0.00'));
 response={...sample,blocker_count:1};await api.load();assert(els.submit.disabled);assert(els.pending.innerHTML.includes('禁止日结'));
 response=sample;await api.load();els.notes.value='核对未付款订单';els.close.onsubmit({preventDefault(){}});await tick();const close=calls.find(x=>x.name==='yt_pos_day_close');assert(close);assert.equal(close.args.p_actual,110);assert.equal(close.args.p_fingerprint,'f1');assert(close.args.p_request);
 fail=true;await api.load();assert(els.submit.disabled);assert(notices.some(x=>x.m==='cashier_only'));fail=false;await api.load();api.clear();assert.equal(els.pending.innerHTML,'');assert(els.submit.disabled);
 console.log('PASS: server business date, escaped unpaid rows, cash reconciliation, 72h blocking, guarded close payload, load failure and logout clearing.');
})().catch(e=>{console.error(e);process.exitCode=1;});
