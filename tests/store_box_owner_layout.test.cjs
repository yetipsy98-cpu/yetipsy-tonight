const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const pos=fs.readFileSync('play/pos/store-box.js','utf8');
const ambassador=fs.readFileSync('play/ambassador-client.js','utf8')+fs.readFileSync('play/ambassador-ui.css','utf8');
const migration=fs.readFileSync('sql/059_store_box_owner_claim_audit.sql','utf8');

test('Store Box generation and issued QR queues share one collapsed space-saving section',()=>{
 const render=pos.slice(pos.indexOf('function renderStaff()'),pos.indexOf('function renderOrderQueue()'));
 assert(render.indexOf('issueMarkup()')<render.indexOf('存酒余额'));
 assert.match(pos,/<details class="storebox-issuance"><summary>/);
 assert.match(pos,/待生成 \$\{pending\.length\} · 已生成待领取 \$\{state\.claims\.length\}/);
 assert.match(pos,/\$\{claimMarkup\(\)\}/);
 assert.match(pos,/待生成/);
 assert.match(pos,/已生成 · 待顾客领取/);
});

test('claimed Store Box cards show the staff who issued their claim QR',()=>{
 assert.match(pos,/claimed_qr_issued_by_name/);
 assert.match(pos,/二维码由 .* 的 Staff 端发出/);
 assert.match(migration,/c\.status='claimed'/);
 assert.match(migration,/wa\.username claimed_qr_issued_by_name/);
});

test('customer Ambassador entry is a full-width shortcut at the bottom of the shortcut group',()=>{
 assert.match(ambassador,/host\.append\(button\)/);
 assert.doesNotMatch(ambassador,/host\.prepend\(button\)/);
 assert.match(ambassador,/grid-column:1\/-1/);
});

test('customer claimed Store Boxes remain visible in their account history',()=>{
 assert.match(migration,/where b\.customer_id=actor/);
 assert.doesNotMatch(migration,/where b\.customer_id=actor and b\.claimed_at is null/i);
});
