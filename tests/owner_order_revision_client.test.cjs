const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),crypto=require('node:crypto').webcrypto;
const src=fs.readFileSync('play/pos/pos.js','utf8');
class El{constructor(){this.value='';this.checked=false;this.disabled=false;this.innerHTML='';this.textContent='';this.classList={add(){},remove(){},toggle(){}};}querySelector(){return this.button??=new El();}querySelectorAll(){return this.inputs??=[];}focus(){}}
const els=new Map(),$=id=>{if(!els.has(id))els.set(id,new El());return els.get(id);};
let calls=[],fail=false,owner=true;const state={editOrder:{id:'order1',payment_status:'paid',updated_at:'original-date'},editCart:new Map([['first',{item_id:'old-item',product_id:'product1',quantity:2,unit_price_rm:20}]]),editBusy:false,adjustmentBalance:20};
const ctx={state,$,crypto,document:{body:{classList:{remove(){}}}},console,confirm:()=>true,isOwner:()=>owner,money:n=>'RM'+Number(n||0).toFixed(2),unpack:r=>{if(r.error){const e=Error(r.error.message);e.code=r.error.code;throw e;}return r.data;},showNotice(){},errorText:e=>e.message,revisionSummary:()=>'',benefitSummary:()=>'',revisionHistory:()=>'',busy:async(b,fn)=>{try{await fn();}catch(e){}},refreshOrders:async()=>{},db:{rpc:async(name,args)=>{calls.push({name,args:JSON.parse(JSON.stringify(args))});if(name==='yt_pos_owner_revision_preview')return{data:{net:60,balance_rm:20}};if(fail)throw Error('Failed to fetch');return{data:{payment_status:'paid',balance_rm:15}};}}};vm.createContext(ctx);
vm.runInContext(src.slice(src.indexOf('let editPreviousFocus='),src.indexOf('// POS V4 -'))+'\nglobalThis.reopen=0;openEditDialog=async()=>{reopen++;state.editPending=null;state.adjustmentPending=null;};',ctx);
const event={preventDefault(){},submitter:$('editSettlementSubmit')};
(async()=>{
 for(const role of ['pos','owner','staff','cashier']){const html=fs.readFileSync(`play/${role}/index.html`,'utf8');const option=html.match(/<input id="editRevokeBenefits"[^>]*>/)[0];assert(!option.includes('checked'));assert(html.includes('id="editSettlementConfirmed" type="checkbox" required'));}
 $('editReason').value='quantity change';$('editTable').value='T1';fail=true;
 await ctx.submitEditOrder(event);const saved=state.editPending;assert(saved);assert.equal(saved.p_revoke,false);assert.equal(saved.p_expected_updated,'original-date');assert.equal(saved.p_items[0].item_id,'old-item');
 ctx.editDialogChange({dataset:{editQty:'first'},value:'1'});assert.equal(state.editCart.get('first').quantity,2);
 $('editReason').value='programmatic mutation';fail=false;await ctx.submitEditOrder(event);
 const edits=calls.filter(x=>x.name==='yt_pos_owner_revision_apply');assert.equal(edits.length,2);assert.deepEqual(edits[0].args,edits[1].args);assert.equal(ctx.reopen,1);
 // Require actual receipt confirmation before creating the money request.
 $('editSettlementAmount').value='5';$('editSettlementMethod').value='cash';$('editSettlementNote').value='received';$('editSettlementConfirmed').checked=false;
 await ctx.submitAdjustment(event);assert.equal(calls.filter(x=>x.name==='yt_pos_adjustment_pay').length,0);
 $('editSettlementConfirmed').checked=true;fail=true;await ctx.submitAdjustment(event);assert(state.adjustmentPending);assert.equal(state.adjustmentPending.p_amount,5);
 ctx.editControls();assert($('editForm').querySelector().disabled);assert(!$('editSettlementSubmit').disabled);assert.equal($('editSettlementSubmit').textContent,'重试确认原款项');
 $('editSettlementAmount').value='99';fail=false;await ctx.submitAdjustment(event);const payments=calls.filter(x=>x.name==='yt_pos_adjustment_pay');assert.equal(payments.length,2);assert.deepEqual(payments[0].args,payments[1].args);assert.equal(ctx.reopen,2);
 // A lower revised bill sends a negative ledger adjustment; an over-refund never reaches the RPC.
 state.adjustmentBalance=-10;state.adjustmentPending=null;$('editSettlementAmount').value='11';await ctx.submitAdjustment(event);assert.equal(calls.filter(x=>x.name==='yt_pos_adjustment_pay').length,2);
 $('editSettlementAmount').value='4';await ctx.submitAdjustment(event);assert.equal(calls.at(-1).args.p_amount,-4);
assert(src.includes('[data-edit-qty],[data-edit-product],[data-edit-price]'));
 const helpers={};vm.createContext(helpers);vm.runInContext(fs.readFileSync('play/pos/owner-order-edit.js','utf8').replace(/export /g,''),helpers);
 assert(helpers.revisionSummary({before_amount_rm:40,net:60,received_rm:40,balance_rm:20},true).includes('需补收'));
 assert(helpers.revisionSummary({before_amount_rm:40,net:20,received_rm:40,balance_rm:-20},true).includes('需退款'));
 assert(!helpers.benefitSummary({rewards:[{name:'<img>',status:'redeemed'}]}).includes('<img>'));
 const receiptCtx={esc:s=>String(s??''),money:ctx.money,friendlyDate:()=>'-'};vm.createContext(receiptCtx);vm.runInContext(src.slice(src.indexOf('function receiptInner('),src.indexOf('async function viewReceipt(')),receiptCtx);
 const bill=receiptCtx.receiptInner({payment_status:'paid',amount_rm:60,received_rm:40,balance_rm:20,items:[],discounts:[],payment_entries:[{kind:'sale',amount_rm:50,method:'cash'},{kind:'refund',amount_rm:-10,method:'cash'}]});assert(bill.includes('尚需补收'));assert(bill.includes('RM40.00'));assert(bill.includes('退款'));
 const refund=receiptCtx.receiptInner({payment_status:'refunded',amount_rm:0,received_rm:0,balance_rm:0,items:[],discounts:[]});assert(refund.includes('已退款取消'));assert(!refund.includes('尚未收款'));
 console.log('PASS: Owner default preserves benefits, historical item IDs, frozen exact retries after lost responses, actual-payment confirmation, partial collection/refund bounds, disabled concurrent edits and clear revised customer bill.');
})().catch(e=>{console.error(e);process.exitCode=1;});
