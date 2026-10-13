const assert=require('node:assert/strict'),fs=require('node:fs');
const pos=fs.readFileSync('play/pos/pos.js','utf8');
const queue=fs.readFileSync('sql/061_kds_customer_voice_source.sql','utf8');
assert(pos.includes("new Utterance('有新的订单')"),'KDS voice says new order');
assert.match(pos,/function announceNewOrder\(\)\{if\(!isCashier\(\)\)return;/,'only Cashier identity can play speech');
assert(pos.includes('synth.speak(message)'), 'use browser speech synthesis');
assert(pos.includes("row.created_channel!=='cashier'"),'Cashier-created orders stay silent');
assert(pos.includes('added.filter(row=>row.request_customer_id)'), 'only customer-originated store-box calls speak');
assert(queue.includes('r.customer_id request_customer_id'),'KDS queue identifies caller, not box owner');
for(const page of ['pos','owner','staff','cashier']){
 const html=fs.readFileSync('play/'+page+'/index.html','utf8');
 assert(html.includes('pos.js?v=20261013-cashier-only-voice-v1'),'fresh JS cache '+page);
}
console.log('PASS KDS new-order voice is restricted to Cashier, excluding Cashier-created work');
