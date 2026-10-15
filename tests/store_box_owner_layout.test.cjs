const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const pos=fs.readFileSync('play/pos/store-box.js','utf8');
const ambassador=fs.readFileSync('play/ambassador-client.js','utf8')+fs.readFileSync('play/ambassador-ui.css','utf8');
const migration=fs.readFileSync('sql/059_store_box_owner_claim_audit.sql','utf8');

test('Store Box generation and issued QR queues share one collapsed space-saving section',()=>{
 const render=pos.slice(pos.indexOf('function renderStaff()'),pos.indexOf('function renderOrderQueue()'));
 assert(render.indexOf('issueMarkup()')<render.indexOf('存酒余额'));
 assert.match(pos,/<details class="storebox-issuance" data-storebox-fold="issuance"><summary>/);
 assert.match(pos,/待生成 \$\{pending\.length\} · 待领取 \$\{state\.claims\.length\}/);
 assert.match(pos,/\$\{claimMarkup\(\)\}/);
 assert.match(pos,/待生成/);
 assert.match(pos,/已生成 · 待顾客领取/);
 assert.match(render,/<details class="storebox-balance-panel" data-storebox-fold="balance">/);
 assert.match(render,/<details class="storebox-history-panel" data-storebox-fold="history">/);
 assert.match(pos,/changed=snapshot!==state\.staffSnapshot/,'polling detects unchanged RPC responses');
 assert.match(pos,/if\(changed\|\|!staffRoot\.querySelector\('\[data-box-staff-body\]'\)\)renderStaff\(\)/,'unchanged polling never rebuilds the workbench');
 assert.doesNotMatch(pos,/if\(state\.qr\)showQR\(state\.qr\)/,'QR drawer is not reopened by background renders');
});

test('Store Box issue tickets and QR drawer foreground the table number like KDS',()=>{
 assert.match(pos,/class="kds-table-number">\$\{esc\(row\.table_label\|\|'未填桌号'\)\}/);
 assert.match(pos,/data-box-qr-table/);
 assert.match(pos,/table_label:row\.table_label,order_no:row\.order_no/);
 assert.match(pos,/data-storebox-fold="balance"/);
});

test('claimed Store Box cards show the staff who issued their claim QR',()=>{
 assert.match(pos,/claimed_qr_issued_by_name/);
 assert.match(pos,/二维码由 .* 的 Staff 端发出/);
 assert.match(migration,/c\.status='claimed'/);
 assert.match(migration,/wa\.username claimed_qr_issued_by_name/);
});

test('customer Ambassador entry is a full-width button directly under the home title',()=>{
 assert.match(ambassador,/homeTitle\.after\(button\)/);
 assert.match(ambassador,/grid-column:1\/-1/);
});

test('customer claimed Store Boxes remain visible in their account history',()=>{
 assert.match(migration,/where b\.customer_id=actor/);
 assert.doesNotMatch(migration,/where b\.customer_id=actor and b\.claimed_at is null/i);
});
