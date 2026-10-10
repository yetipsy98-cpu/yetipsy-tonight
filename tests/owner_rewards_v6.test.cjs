const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),{webcrypto}=require('node:crypto');
const base=path.join(__dirname,'../play');
class El{constructor(){this.value='';this.textContent='';this.children=[];this.options=[{}];this.classList={add(){},remove(){}};}append(...items){this.children.push(...items);}replaceChildren(){this.children=[];}}
const nodes={giftQR:new El(),issueReward:{value:'reward'},offerFrom:{value:''},offerUntil:{value:'2099-01-01T12:00'},offerTotal:{value:'10'},offerPerPerson:{value:'1'}};
const calls=[];let copied,verified;
const work=fs.readFileSync(path.join(base,'shared/owner-tools.js'),'utf8');
const c={document:{createElement:()=>new El()},$:id=>nodes[id],copy:v=>copied=v,fmt:v=>v,uuid:()=>webcrypto.randomUUID(),busy:(_,fn)=>fn(),Date,console,ensureQRLibrary:async()=>{throw Error('offline');},codeLink:(kind,t)=>'https://example.test/?'+kind+'='+t,toMyTimestamp:s=>s?s+':00+08:00':null,unpack:r=>r.data,verifyIssuedCode:async(kind,token,card)=>verified={kind,token,card},db:{rpc:async(name,args)=>{calls.push({name,args});return {data:{display_code:'7K3M-9X2P',expires_at:'2099-01-01T04:00:00Z'}};}}};
vm.createContext(c);vm.runInContext(work.slice(work.indexOf('async function showQR('),work.indexOf('async function verifyIssuedCode('))+work.slice(work.indexOf('async function createOffer('),work.indexOf('async function directReward('))+'\nglobalThis.issue=createOffer;',c);
(async()=>{
 await c.issue({currentTarget:{}});assert.equal(calls[0].name,'yt_create_offer_v5');assert.equal(verified.kind,'gift');assert.equal(verified.card.shortCode,'7K3M-9X2P');
 assert(nodes.giftQR.children.some(e=>e.textContent==='7K3M-9X2P'));assert(!nodes.giftQR.children.some(e=>e.href));const copy=nodes.giftQR.children.find(e=>e.textContent==='复制领取短码');copy.onclick();assert.equal(copied,'7K3M-9X2P');
 const keys=['source','template','mode','product','series','type','value','minimum','spend','summary'],fields=Object.fromEntries(keys.map(k=>[k,new El()])),wraps=Object.fromEntries(['template','manual','product','series','value'].map(k=>[k,new El()]));
 Object.assign(fields.source,{value:'new'});Object.assign(fields.mode,{value:'product'});Object.assign(fields.type,{value:'free'});fields.value.value='5';fields.minimum.value='1';fields.spend.value='0';
 const root={classList:{add(){}},querySelector:s=>{const m=s.match(/data-(bind|wrap)="(\w+)"/);return (m[1]==='bind'?fields:wraps)[m[2]];}};
 const requests=[];let fail=true;const db={rpc:async(name,args)=>{if(name==='yt_pos_owner_reward_rules')return {data:[{reward_id:'old',reward_name:'RM5',active:true,mode:'any_drink',discount_type:'fixed',discount_value:5,min_paid_drinks:1,min_spend_rm:0}]};if(name==='yt_pos_catalog')return {data:[{id:'cup',name:'Cup',price_rm:28,active:true}]};if(name==='yt_pos_series_catalog')return {data:[]};requests.push(args);return fail?{error:{message:'network'}}:{data:'new-reward'};}};
 const cc={crypto:webcrypto};vm.createContext(cc);vm.runInContext(fs.readFileSync(path.join(base,'reward-binding.js'),'utf8').replace(/export /g,'')+'\nglobalThis.create=createRewardBindingEditor;',cc);const editor=cc.create({db,root});await editor.load();
 const args={p_name:'RM5',p_category:'voucher',p_validity:30,p_next_day:false};await assert.rejects(editor.create(args),/请选择权益/);fields.product.value='cup';fields.minimum.value='0';await assert.rejects(editor.create(args),/至少保留/);assert.equal(requests.length,0);
 fields.minimum.value='1';await assert.rejects(editor.create(args),/network/);fail=false;assert.equal(await editor.create(args),'new-reward');assert.equal(requests[0].p_request,requests[1].p_request);assert.equal(requests[1].p_binding.product_id,'cup');
 fields.source.value='existing';fields.template.value='old';fields.source.onchange();await editor.create(args);assert.equal(requests.at(-1).p_binding.template_reward_id,'old');assert(wraps.manual.hidden);assert.match(fields.summary.textContent,/RM5/);
 for(const p of ['index.html','owner/index.html','pos/index.html','cashier/index.html'])assert(fs.readFileSync(path.join(base,p),'utf8').includes('rewardBindingRoot'));
 console.log('PASS: independent Owner QR fallback shows and copies short code; creation requires rights, retries safely and supports existing rights in all entry points.');
})().catch(e=>{console.error(e);process.exitCode=1;});
