const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const c={Intl,Date,Number};vm.createContext(c);vm.runInContext(fs.readFileSync('play/pos/financial-pdf.js','utf8').replace(/export /g,'')+';globalThis.build=buildFinancialReportHTML;',c);
const sample={complete:true,start:'2026-10-01',end:'2026-10-31',generated_at:'2026-11-01T06:00:00Z',summary:{orders:75,sales_rm:1500,adjustments_rm:40,refunds_rm:30,net_rm:1510},item_summary:{products:25,quantity:75,gross_rm:1600,discount_rm:90,net_rm:1510},orders:Array.from({length:75},(_,n)=>({order_no:'ORDER-'+(n+1),business_day:'2026-10-18',bill_rm:20,net_rm:20,balance_rm:0,amendment_note:n===74?'于 2026-11-01 修改退款':''})),products:Array.from({length:25},(_,n)=>({item_name:'PRODUCT-'+(n+1),category:'鸡尾酒',series_name:'经典',quantity:3,gross_rm:60,discount_rm:0,net_rm:60,payment_method:'cash'})),adjustments:[{order_no:'REFUND-1',business_day:'2026-10-18',kind:'refund',method:'cash',amount_rm:-30,modified_at:'2026-11-01T06:00:00Z',note:'<script>alert(1)</script>'}],days:[{day:'2026-10-18',orders:75,sales_rm:1500,adjustments_rm:40,refunds_rm:30,net_rm:1510}]};
const html=c.build(sample);
assert(html.includes('2026年10月经营月报'));assert(html.includes('ORDER-75'));assert(html.includes('PRODUCT-25'));assert(html.includes('2026-10-31'));assert(html.includes('2026-10-01'));assert(html.includes('2026-10-18'));assert(html.includes('2026/11/01')||html.includes('2026/11/1'));
assert(!html.includes('<script>'));assert(html.includes('&lt;script&gt;'));assert(html.includes('A4 portrait'));assert(html.includes('table-header-group'));assert(html.includes('净实收 = 原收款 + 补收 − 退款'));assert(html.includes('1,510.00'));
assert.throws(()=>c.build({...sample,complete:false}));assert.throws(()=>c.build({...sample,start:'bad'}));
const empty=c.build({complete:true,start:'2026-02-01',end:'2026-02-28',summary:{},item_summary:{}});assert(empty.includes('本期间暂无记录'));assert(empty.includes('2026-02-28'));assert(!empty.includes('NaN'));
const groupedSample={...sample,products:[{item_name:'PAYMENT-DUIT-AAA',category:'C',payment_method:'duitnow'},{item_name:'PAYMENT-CASH-ZZZ',category:'C',payment_method:'cash'},{item_name:'PAYMENT-FOOD',category:'C',payment_method:'foodcourt'},{item_name:'PAYMENT-CASH-AAA',category:'C',payment_method:'cash'}]};
const originalOrder=groupedSample.products.map(x=>x.item_name).join(',');
const productSection=c.build(groupedSample).split('04　商品明细')[1].split('05　补收与退款')[0];
assert(productSection.indexOf('PAYMENT-CASH-AAA')<productSection.indexOf('PAYMENT-CASH-ZZZ'));
assert(productSection.indexOf('PAYMENT-CASH-ZZZ')<productSection.indexOf('PAYMENT-DUIT-AAA'));
assert(productSection.indexOf('PAYMENT-DUIT-AAA')<productSection.indexOf('PAYMENT-FOOD'));
assert.equal(groupedSample.products.map(x=>x.item_name).join(','),originalOrder);
console.log('PASS A4 financial report, untruncated details, accounting dates, amendment notes, totals, escaping, empty period and invalid data guards');

const freeflowHTML=c.build({...sample,freeflow:{cups:33,top5:Array.from({length:7},(_,i)=>({name:'RANK-'+i+(i===0?' <script>':''),cups:9-i})),drinks:[{name:'DRINK-<A>',cups:17},{name:'DRINK-B',cups:16}]}});assert(freeflowHTML.includes('FreeFlow · 出杯数前 5 位'));assert(freeflowHTML.includes('RANK-4'));assert(!freeflowHTML.includes('RANK-5'));assert(freeflowHTML.includes('DRINK-&lt;A&gt;'));assert(freeflowHTML.includes('&lt;script&gt;'));assert(freeflowHTML.includes('不重复计入营业额'));
