const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const pos=fs.readFileSync('play/pos/pos.js','utf8');
const box=fs.readFileSync('play/pos/store-box.js','utf8');
const html=fs.readFileSync('play/admin/pos/index.html','utf8');
const css=fs.readFileSync('play/pos/console.css','utf8');
const sql=fs.readFileSync('sql/096_kds_history_storebox_role_privacy.sql','utf8');

test('KDS foregrounds table and cup quantity while keeping notes visible',()=>{
 assert.match(pos,/class="kds-table-number"/);
 assert.match(pos,/class="kds-cup-highlight"/);
 assert.match(box,/class="kds-cup-highlight"/);
 assert.match(css,/\.kds-cup-highlight strong\{[^}]*font-size:38px/);
 assert.match(pos,/备注：\$\{esc\(row\.notes\)\}/);
});

test('staff can open dated KDS history for regular and Store Box tickets',()=>{
 for(const role of ['pos','owner','staff','cashier','admin/pos','admin/owner','admin/staff','admin/cashier']){
  const page=fs.readFileSync(`play/${role}/index.html`,'utf8');
  assert.match(page,/id="kdsHistoryDetails"/,role);
  assert.match(page,/id="kdsHistoryDate"/,role);
 }
 assert.match(pos,/yt_kds_history/);
 assert.match(pos,/store_box_requests/);
 assert.match(sql,/coalesce\(jsonb_agg\(to_jsonb\(x\) order by x\.event_at desc\)/);
 assert.match(sql,/o\.notes/);
});

test('claimant and claim issuer are redacted from Staff and pause requires Cashier or Owner',()=>{
 assert.match(sql,/private\.yt_store_box_can_view_claim_identity/);
 assert.match(sql,/wa\.role='cashier'/);
 assert.match(sql,/case when can_view then coalesce\(pr\.display_name,p\.phone\) else null end customer_name/);
 assert.match(sql,/case when can_view then wa\.username else null end claimed_qr_issued_by_name/);
 assert.match(sql,/raise exception 'cashier_or_owner_only'/);
 assert.match(box,/const canManageBoxes=\(\)=>!!\(isOwner\?\.\(\)\|\|isCashierAccount\?\.\(\)\)/);
 assert.match(pos,/isCashierAccount:\(\)=>state\.identity\?\.role==='cashier'/);
});

test('KDS queue uses table label and never substitutes the customer name',()=>{
 const queue=sql.slice(sql.indexOf('create or replace function private.yt_store_box_queue'),sql.indexOf('create or replace function private.yt_store_box_progress'));
 assert.match(box,/row\.table_label\|\|'未填桌号'/);
 assert.doesNotMatch(box,/row\.table_label\|\|row\.customer_name/);
 assert.match(queue,/private\.yt_store_box_queue\(\)/);
 assert.doesNotMatch(queue,/customer_phone|request_customer_id|customer_name/);
});
