const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const pos=fs.readFileSync('play/pos/store-box.js','utf8');
const customerCss=fs.readFileSync('play/styles.css','utf8');
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

test('Store Box issue and QR views avoid using the day-scoped table number as a box identifier',()=>{
 assert.match(pos,/class="storebox-box-number"/);
 assert.doesNotMatch(pos,/data-box-qr-table/);
 assert.match(pos,/查看领取详情/);
 assert.match(pos,/table_label:row\.table_label,order_no:row\.order_no/);
 assert.match(pos,/data-storebox-fold="balance"/);
});

test('claimed Store Box cards show the staff who issued their claim QR',()=>{
 assert.match(pos,/claimed_qr_issued_by_name/);
 assert.match(pos,/领取二维码来源/);
 assert.match(pos,/claimed_qr_issued_by_name\)\} · Staff 端/);
 assert.match(migration,/c\.status='claimed'/);
 assert.match(migration,/wa\.username claimed_qr_issued_by_name/);
});

test('customer Ambassador entry remains a full-width shortcut after the existing home shortcuts',()=>{
 assert.match(ambassador,/host\.append\(button\)/);
 assert.doesNotMatch(ambassador,/homeTitle\.after\(button\)/);
 assert.match(ambassador,/grid-column:1\/-1/);
});

test('customer navigation is fixed to the bottom edge',()=>{
 assert.match(customerCss,/\.bottom-nav\{position:fixed;top:auto;bottom:0/);
 assert.doesNotMatch(customerCss,/\.bottom-nav\{position:sticky;top:0/);
});

test('customer claimed Store Boxes remain visible in their account history',()=>{
 assert.match(migration,/where b\.customer_id=actor/);
 assert.doesNotMatch(migration,/where b\.customer_id=actor and b\.claimed_at is null/i);
});
