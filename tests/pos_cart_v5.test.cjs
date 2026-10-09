const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {webcrypto} = require('node:crypto');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'play/pos/pos.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'play/pos/index.html'), 'utf8');
for (const page of ['pos', 'cashier']) {
 const h = fs.readFileSync(path.join(root, 'play', page, 'index.html'), 'utf8');
 const ids = [...h.matchAll(/id="([^"]+)"/g)].map(m => m[1]);
 assert.equal(ids.length, new Set(ids).size, `${page}: duplicate DOM IDs`);
 for (const id of ['draftRedeemToken','draftRedeemScan','draftRedeemCheck','draftRewardRows','draftGross','draftDiscount','draftStatus','draftRefresh']) assert(ids.includes(id));
 assert(h.includes('data-go-tab="create">⌗ 点单购物车兑奖'));
 assert(h.includes('class="cart-redeem-form hidden"'));
}
class Element {
 constructor(id='') { this.id=id; this.value=''; this.checked=false; this.disabled=false; this.children=[]; this.options=[]; this.dataset={}; this.textContent=''; this.innerHTML=''; this.flags=new Set(); this.classList={add:v=>this.flags.add(v),remove:v=>this.flags.delete(v),contains:v=>this.flags.has(v),toggle:(v,b)=>{if(b===undefined)b=!this.flags.has(v);b?this.flags.add(v):this.flags.delete(v);}}; }
 replaceChildren(...c){this.children=c;this.options=c;this.innerHTML='';}
 append(...c){this.children.push(...c);}
 add(o){this.options.push(o);}
 querySelectorAll(){return this.children.filter(x=>x instanceof Element);}
 addEventListener(){} setAttribute(){} focus(){} scrollIntoView(){}
 insertAdjacentHTML(_,h){this.innerHTML+=h;}
 getContext(){return {drawImage(){},getImageData:()=>({data:new Uint8ClampedArray(16)})};}
}
const P='11111111-1111-4111-8111-111111111111';
const T='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
function harness(role='staff') {
 const elements = Object.fromEntries([...html.matchAll(/id="([^"]+)"/g)].map(m=>[m[1],new Element(m[1])]));
 const backend={holds:[],calls:[],orders:new Map(),timeout:false,reject:false,summaryResolvers:null,shortError:null,rules:[]};
 const session=new Map();
 const rpc=async(name,args={})=>{
  backend.calls.push({name,args:structuredClone(args)});
  let data;
  if(name==='yt_pos_preorder_summary'){
   const g=args.p_cart.reduce((n,i)=>n+28*i.quantity,0),d=backend.holds.filter(h=>h.state==='chosen').reduce((n,h)=>n+h.discount_rm,0);
   data={gross_rm:g,reserved_discount_rm:d,payable_rm:g-d,unresolved_count:backend.holds.filter(h=>h.state==='pending').length,holds:structuredClone(backend.holds),can_submit:backend.holds.every(h=>h.state==='chosen')&&g-d>0};
   if(backend.summaryResolvers)return new Promise(resolve=>backend.summaryResolvers.push(()=>resolve({data,error:null})));
  } else if(name==='yt_pos_preorder_scan'||name==='yt_pos_preorder_scan_code'){
   if(name==='yt_pos_preorder_scan_code'&&backend.shortError)return {data:{error_code:backend.shortError},error:null};
   data={id:webcrypto.randomUUID(),reward_name:'RM5 Voucher',state:'pending',discount_type:'fixed',discount_value:5,discount_rm:0,valid:false,products:[{product_id:P,name:'Test drink',price_rm:28}]};backend.holds.push(structuredClone(data));
  } else if(name==='yt_pos_preorder_choose'){
   Object.assign(backend.holds.find(h=>h.id===args.p_hold),{state:'chosen',discount_rm:5,chosen_product_id:args.p_product,chosen_unit:args.p_unit,chosen_product_name:'Test drink',valid:true});data={ok:true};
  } else if(name==='yt_pos_preorder_release'){backend.holds=backend.holds.filter(h=>h.id!==args.p_hold);data=true;
  } else if(name==='yt_pos_create_order_with_rewards'){
   if(backend.reject)return {error:{code:'P0001',message:'reward_reserved_by_other_order'}};
   if(!backend.orders.has(args.p_request)){backend.orders.set(args.p_request,{id:webcrypto.randomUUID(),order_no:'YT-TEST-1',status:args.p_channel==='cashier'?'confirmed':'pending',reward_cart:{attached:backend.holds.length}});backend.holds=[];}
   data=backend.orders.get(args.p_request);
   if(backend.timeout){backend.timeout=false;return {error:{message:'Failed to fetch',code:''}};}
  } else if(name==='yt_pos_owner_save_reward_v43'){
   backend.rules=[{reward_id:args.p_reward,reward_name:'RM5 Voucher',active:true,mode:args.p_mode,discount_type:args.p_type,discount_value:args.p_value,min_paid_drinks:args.p_min_drinks,min_spend_rm:args.p_min_spend}];data=true;
  } else if(name==='yt_pos_owner_reward_rules')data=backend.rules;
  else if(name==='yt_pos_orders')data=[];
  else data=[];
  return {data,error:null};
 };
 const body=new Element();body.dataset.entry=role==='cashier'?'cashier':'work';
 const query={select(){return this;},not(){return this;},order(){return this;},limit:async()=>({data:[],error:null})};
 const context={console,crypto:webcrypto,URL,Intl,Option:function(label,value){this.label=label;this.value=value;},navigator:{},location:{href:'https://example.test/play/pos/'},window:{YETIPSY_PLAY_CONFIG:{url:'https://test.supabase.co',publishableKey:'sb_publishable_TEST'},confirm:()=>true},document:{body,head:new Element(),getElementById:id=>elements[id]||null,createElement:()=>new Element(),addEventListener(){},visibilityState:'visible'},sessionStorage:{getItem:k=>session.get(k)||null,setItem:(k,v)=>session.set(k,v)},setTimeout:()=>1,clearTimeout(){},setInterval:()=>1,clearInterval(){},createClient:()=>({rpc,from:()=>query})};
 vm.createContext(context);
 const js=source.replace(/^import .*?;\n/gm,'').replace("new URL('../',import.meta.url)","new URL('https://example.test/play/')").replace(/boot\(\)\.catch\(e=>\{resetLogin\(\);showNotice\(errorText\(e\),true,true\);\}\);/,'');
 vm.runInContext(js+'\nglobalThis.cartTest={state,restoreDraft,saveDraft,renderCart,refreshDraftSummary,scanDraftReward,releaseDraftReward,adjustCart,createOrder,parseRedeemToken,qrDecoder,stopRedeemCamera,saveRM5Preset,saveRewardMap,updateRewardMapForm};',context);
 const api=context.cartTest;api.state.identity={username:role,role,can_cashier:role==='cashier',can_owner:false};api.state.activeView='dashboard';api.state.currentTab='create';api.state.catalog=[{id:P,name:'Test drink',active:true,price_rm:28}];api.restoreDraft();
 return {api,e:elements,backend,context,session};
}
async function run(){
 let h=harness();h.api.state.cart.set(P,2);await h.api.refreshDraftSummary();assert.equal(h.e.cartTotal.textContent,'RM56.00');assert.equal(h.e.createOrderBtn.disabled,false);
 assert.equal(h.api.parseRedeemToken('redeem:'+T),T);assert.equal(h.api.parseRedeemToken('https://example.test/?redeem='+T),T);assert.throws(()=>h.api.parseRedeemToken('https://example.test/?claim='+T));
 h.e.draftRedeemToken.value=T;await h.api.scanDraftReward();assert.equal(h.e.createOrderBtn.disabled,true);assert.equal(h.e.draftRewardChoices.children.length,2);
 await h.e.draftRewardChoices.children[0].onclick();assert.equal(h.e.cartTotal.textContent,'RM51.00');assert.equal(h.e.draftDiscount.textContent,'−RM5.00');assert.equal(h.e.createOrderBtn.disabled,false);
 h.api.adjustCart(P,1);assert.equal(h.api.state.cart.get(P),2,'reward selection must freeze quantity');
 await h.api.releaseDraftReward(h.backend.holds[0].id);assert.equal(h.e.cartTotal.textContent,'RM56.00');h.api.adjustCart(P,1);assert.equal(h.api.state.cart.get(P),3);
 // Stale summary must not overwrite newer cart totals or enable submission early.
 h.backend.summaryResolvers=[];h.api.state.cart.set(P,1);const old=h.api.refreshDraftSummary();h.api.state.cart.set(P,2);const fresh=h.api.refreshDraftSummary();h.backend.summaryResolvers[1]();await fresh;h.backend.summaryResolvers[0]();await old;assert.equal(h.e.cartTotal.textContent,'RM56.00');h.backend.summaryResolvers=null;
 // Server committed but response was lost: replay the exact payload after a page reload.
 h.e.tableInput.value='A03';h.backend.timeout=true;await h.api.createOrder();assert.equal(h.backend.orders.size,1);assert(h.api.state.pendingSubmit);assert.equal(h.e.tableInput.disabled,true);assert.equal(h.e.createOrderBtn.disabled,false);
 const original=structuredClone(h.api.state.pendingSubmit);h.api.adjustCart(P,1);assert.equal(h.api.state.cart.get(P),2);h.api.restoreDraft();assert.equal(JSON.stringify(h.api.state.pendingSubmit),JSON.stringify(original));h.e.tableInput.value='changed';await h.api.createOrder();
 const submits=h.backend.calls.filter(c=>c.name==='yt_pos_create_order_with_rewards');assert.equal(submits.length,2);assert.deepEqual(submits[0].args,submits[1].args);assert.equal(h.backend.orders.size,1);assert.equal(h.api.state.pendingSubmit,null);assert.equal(h.api.state.cart.size,0);
 // A definite database rejection unlocks the draft so the reward can be corrected.
 h=harness('cashier');h.api.state.cart.set(P,1);h.e.cashierDirect.checked=true;await h.api.refreshDraftSummary();h.backend.reject=true;await h.api.createOrder();assert.equal(h.api.state.pendingSubmit,null);assert.equal(h.e.tableInput.disabled,false);assert.equal(h.backend.orders.size,0);
 h.backend.reject=false;await h.api.createOrder();assert.equal(h.backend.calls.filter(c=>c.name==='yt_pos_create_order_with_rewards').at(-1).args.p_channel,'cashier');
 // Browser without BarcodeDetector uses decoded pixel data rather than losing camera support.
 h=harness();let decoded=false;h.context.window.jsQR=(pixels,width,height)=>{decoded=pixels.length===16&&width===640&&height===480;return {data:'redeem:'+T};};const decode=await h.api.qrDecoder();assert.equal(await decode({videoWidth:1280,videoHeight:960}),'redeem:'+T);assert(decoded);
 assert(!h.backend.calls.some(c=>c.name==='yt_pos_cart_reserve'),'cart flow must not use post-order reservation');
 // Manual short codes use their own RPC; errors preserve the code for correction.
 h=harness();h.api.state.cart.set(P,1);h.e.draftRedeemToken.value=' 7k3m-9x2p ';await h.api.scanDraftReward();
 const manual=h.backend.calls.find(c=>c.name==='yt_pos_preorder_scan_code');assert.equal(manual.args.p_code,'7K3M9X2P');assert(!('p_token' in manual.args));
 await h.e.draftRewardChoices.children[0].onclick();assert.equal(h.e.cartTotal.textContent,'RM23.00');
 h=harness();h.api.state.cart.set(P,1);h.e.draftRedeemToken.value='7K3M9X2P';h.backend.shortError='short_code_invalid_or_expired';
 await assert.rejects(h.api.scanDraftReward(),/short_code_invalid_or_expired/);assert.equal(h.e.draftRedeemToken.value,'7K3M9X2P');assert.equal(h.api.state.draftSelection,null);assert.match(h.e.notice.textContent,/兑换码不正确/);
 // RM5 is a persisted configuration, and a zero-drink rule is rejected before RPC.
 h=harness('owner');h.api.state.identity.can_owner=true;h.e.mapReward.value=T;await h.api.saveRM5Preset();
 const preset=h.backend.calls.find(c=>c.name==='yt_pos_owner_save_reward_v43');assert.deepEqual(preset.args,{p_reward:T,p_mode:'any_drink',p_product:null,p_series:null,p_type:'fixed',p_value:5,p_min_drinks:1,p_min_spend:0});
 assert.equal(h.e.mapMode.value,'any_drink');assert.equal(h.e.mapMinDrinks.value,1);assert(h.e.ownerGiveReward.options.some(o=>o.value===T));
 const before=h.backend.calls.length;h.e.mapMinDrinks.value='0';await h.api.saveRewardMap({preventDefault(){},submitter:new Element()});assert.equal(h.backend.calls.length,before);assert.match(h.e.notice.textContent,/至少一杯/);
 h.e.mapMinDrinks.value='2';h.e.mapMinSpend.value='50';await h.api.saveRewardMap({preventDefault(){},submitter:new Element()});const saved=h.backend.calls.filter(c=>c.name==='yt_pos_owner_save_reward_v43').at(-1);assert.equal(saved.args.p_min_drinks,2);assert.equal(saved.args.p_min_spend,50);
 console.log('PASS: both entry points, discounts, reward choices/removal, stale responses, quantity guard, persisted exact retry, single order after lost response, database rejection recovery, Cashier channel and QR fallback.');
}
run().catch(e=>{console.error(e);process.exitCode=1;});

