const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const box=fs.readFileSync('play/pos/store-box.js','utf8');
const customer=fs.readFileSync('play/customer-store-box.js','utf8');
const migration=fs.readFileSync('supabase/migrations/20261017021500_owner_store_box_rule_delete_expiry_correction.sql','utf8');

test('Owner removes only Store Box rules; issued balances and operational history remain intact',()=>{
 assert.match(box,/data-box-delete-rule/);
 assert.match(box,/yt_store_box_rule_delete/);
 assert.doesNotMatch(box,/data-box-progress="delete"/);
 assert.doesNotMatch(box,/state\.boxes\.filter\(row=>row\.status!==['"]cancelled/);
 assert.match(migration,/if not private\.yt_work_owner\(\) then raise exception 'owner_only';end if;/);
 assert.match(migration,/delete from public\.yt_store_box_product_rules where product_id=p_product/);
 assert.match(migration,/if p_action not in \('pause','resume'\) then raise exception 'invalid_store_box_progress';end if;/);
 assert.doesNotMatch(migration,/update public\.yt_store_boxes set status='cancelled'/);
});

test('one-day expiry follows configured business-day cutoff and client renders empty results',()=>{
 assert.match(migration,/private\.yt_business_start\(private\.yt_business_day\(clock_timestamp\(\)\)\+expiry_days\)/);
 assert.match(customer,/\|\|!state\.rendered/);
});
