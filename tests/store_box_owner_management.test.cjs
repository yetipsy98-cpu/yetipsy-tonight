const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.join(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');

test('staff and Cashier request expiry recovery only after searching the Store Box number',()=>{
 const box=read('play/pos/store-box.js');
 const migration=read('supabase/migrations/20261019000000_store_box_owner_management_staff_reopen.sql');
 assert.match(box,/data-box-search/);
 assert.match(box,/data-box-reopen-request/);
 assert.match(box,/yt_store_box_reopen_request/);
 assert.match(migration,/wa\.role in \('staff','cashier'\)/);
 assert.match(migration,/wa\.active and not wa\.must_change_password/);
 assert.match(migration,/b\.storage_expires_at>clock_timestamp\(\)/);
 assert.match(migration,/requested_by/);
 assert.match(migration,/customer_id drop not null/);
 assert.match(migration,/reopen_request_status/);
});

test('Owner can adjust active components and reopen expired boxes with business-day expiry',()=>{
 const box=read('play/pos/store-box.js');
 const migration=read('supabase/migrations/20261019000000_store_box_owner_management_staff_reopen.sql');
 assert.match(box,/data-box-owner-manage/);
 assert.match(box,/data-box-owner-delta/);
 assert.match(box,/data-box-owner-expiry/);
 assert.match(box,/yt_store_box_owner_manage/);
 assert.match(migration,/if not private\.yt_work_owner\(\) then raise exception 'owner_only'/);
 assert.match(migration,/store_box_balance_edit_active_only/);
 assert.match(migration,/store_box_adjustment_below_served/);
 assert.match(migration,/private\.yt_business_start\(p_expires_on\+1\)/);
 assert.match(migration,/v_new_status:='active'/);
 assert.match(migration,/insert into public\.audit_logs/);
 assert.match(migration,/revoke all on function public\.yt_store_box_owner_manage\(uuid,jsonb,date\) from public,anon/);
});

test('Store Box owner changes do not remove reset behavior or change canonical POS entry',()=>{
 const page=read('play/admin/pos/index.html');
 const reset=read('supabase/migrations/20261016125818_owner_reset_storebox_reopen_requests_fk.sql');
 const migration=read('supabase/migrations/20261019000000_store_box_owner_management_staff_reopen.sql');
 assert.match(page,/pos\.js\?v=20261019-storebox-owner-management-v1/);
 assert.match(reset,/yt_store_box_reopen_requests/);
 assert.match(reset,/yt_store_boxes restart identity/);
 assert.match(migration,/yt_store_box_reopen_requests/);
});
