const assert=require('node:assert/strict'),fs=require('node:fs');
const pos=fs.readFileSync('play/pos/pos.js','utf8');
const queue=fs.readFileSync('sql/061_kds_customer_voice_source.sql','utf8');
const queueFix=fs.readFileSync('sql/063_kds_owner_storebox_voice_source.sql','utf8');
assert(pos.includes("new Utterance('有新的订单')"),'KDS voice says new order');
assert.match(pos,/function announceNewOrder\(\)\{if\(state\.identity\?\.role!=='cashier'\)return;/,'only independent Cashier identity can play speech');
assert.match(pos,/ping\('approval'\);announceNewOrder\(\)/,'pending approvals also announce by voice');
assert(pos.includes('synth.speak(message)'), 'use browser speech synthesis');
assert.match(pos,/const added=rows\.filter\(row=>!state\.seenKds\.has\(row\.id\)\);const audible=added\.filter\(/,'all newly arrived KDS orders are considered before self-order filtering');
assert.match(pos,/row\.created_by===state\.authUserId/,'only orders placed by this signed-in Cashier are excluded');
assert.doesNotMatch(pos,/rows\.filter\(row=>row\.created_channel!=='cashier'/,'Owner and other order sources are not suppressed');
assert.match(pos,/db\.auth\.getSession\?\.\(\)/,'read current auth user for self-order detection');
assert.match(pos,/message\.onerror=fallback[\s\S]*?synth\.resume\?\.\(\)/,'resume speech and play an audio fallback if mobile TTS fails');
assert(queueFix.includes("e.metadata->>'source'"),'KDS queue exposes the request origin');
assert(queueFix.includes('end request_source'),'KDS queue returns request_source');
assert(queue.includes('r.customer_id request_customer_id'),'KDS queue identifies caller, not box owner');
const liveHtml=fs.readFileSync('play/admin/pos/index.html','utf8');

assert(liveHtml.includes('pos.js?v=20261023-owner-pass-cart-v6'),'live POS loads the current KDS voice module');

console.log('PASS Cashier KDS voice covers every source except this Cashier account\'s own orders');