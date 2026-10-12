const assert=require('node:assert/strict'),fs=require('node:fs');
const read=p=>fs.readFileSync(p,'utf8');
const edge=read('supabase/functions/yt-owner-reset/index.ts'),pos=read('play/pos/pos.js'),home=read('play/index.html'),consoleCode=read('play/pos/console.js');
assert.match(edge,/yt_owner_reset_v9/);assert.match(edge,/checkPassword\(account,body\.password,'first'\)/);assert.match(edge,/checkPassword\(account,body\.password,'second'\)/);
assert.match(pos,/yt-owner-reset/);assert.match(pos,/applyReceiptLayout/);assert.match(home,/home-layout-init/);
assert.match(consoleCode,/home-editor\.js/);assert.match(read('play/pos/factory-reset.js'),/el\.dataset\.resetScope!=='storebox'/);
assert.match(read('sql/048_safe_scoped_reset_storebox_v9.sql'),/source_order_snapshot/);
assert.match(read('sql/049_home_receipt_layout_editors_v2.sql'),/yt_receipt_layout_save/);
console.log('PASS: V2.2 deployment contracts, protected reset, homepage and receipt integrations.');
