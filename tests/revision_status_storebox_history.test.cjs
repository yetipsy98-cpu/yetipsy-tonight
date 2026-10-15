const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const pos=fs.readFileSync('play/pos/pos.js','utf8');
const consoleJs=fs.readFileSync('play/pos/console.js','utf8');
const box=fs.readFileSync('play/pos/store-box.js','utf8');
const sql=fs.readFileSync('supabase/migrations/20261015130000_revision_status_storebox_history.sql','utf8');

test('Cashier sees durable revision request status on refreshed order cards',()=>{
 assert.match(pos,/yt_pos_owner_revision_requests_mine/);
 assert.match(pos,/revisionRequestMarkup\(row\)/);
 assert.match(pos,/改单申请已送交 Owner，等待审批/);
 assert.match(sql,/where requester_id=auth\.uid\(\)/);
 assert.match(sql,/yt_pos_work_cashier\(\).*yt_work_owner\(\)/s);
});

test('Owner workbench surfaces and refreshes pending review count',()=>{
 assert.match(consoleJs,/data-revision-count/);
 assert.match(consoleJs,/refreshOrderApprovalCount/);
 assert.match(consoleJs,/改单／取消申请等待 Owner 审批/);
});

test('Store Box balance cards show expiry and dated history defaults to business day',()=>{
 assert.match(box,/storebox-expiry/);
 assert.match(box,/到期日/);
 assert.match(box,/yt_store_box_staff_history/);
 assert.match(box,/data-box-history-day value=/);
 assert.match(sql,/private\.yt_business_start\(d\)/);
 assert.match(sql,/private\.yt_pos_work_staff\(\)/);
});
