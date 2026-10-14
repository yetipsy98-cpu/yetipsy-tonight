const assert=require('node:assert/strict'),fs=require('node:fs');
const pos=fs.readFileSync('play/pos/pos.js','utf8');
const queue=fs.readFileSync('sql/061_kds_customer_voice_source.sql','utf8');
const queueFix=fs.readFileSync('sql/063_kds_owner_storebox_voice_source.sql','utf8');
assert(pos.includes("new Utterance('有新的订单')"),'KDS voice says new order');
assert.match(pos,/function announceNewOrder\(\)\{if\(state\.identity\?\.role!=='cashier'\)return;/,'only independent Cashier identity can play speech');
assert.match(pos,/ping\('approval'\);announceNewOrder\(\)/,'pending approvals also announce by voice');
assert(pos.includes('synth.speak(message)'), 'use browser speech synthesis');
assert(pos.includes("row.created_channel!=='cashier'"),'Cashier-created orders stay silent');
assert(pos.includes("added.filter(row=>row.request_source!=='cashier_checkout')"), 'Owner direct requests speak; cashier checkout prep remains silent');
assert(queueFix.includes("e.metadata->>'source'"),'KDS queue exposes the request origin');
assert(queueFix.includes('end request_source'),'KDS queue returns request_source');
assert(queue.includes('r.customer_id request_customer_id'),'KDS queue identifies caller, not box owner');
for(const page of ['pos','owner','staff','cashier']){
 const html=fs.readFileSync('play/'+page+'/index.html','utf8');
 assert(html.includes('pos.js?v=20261014-storebox-owner-layout-v4'),'fresh JS cache '+page);
}
console.log('PASS Cashier KDS voice covers pending, customer and Owner direct store-box requests while excluding cashier-created work');
