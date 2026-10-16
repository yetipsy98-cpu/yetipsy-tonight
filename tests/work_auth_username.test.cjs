const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

(async()=>{
  const {workUsername}=await import('../supabase/functions/yt-work-auth/username.mjs');
  assert.equal(workUsername(' 阿明 ' ,true),'阿明');
  assert.equal(workUsername('Cashier 1',true),'cashier 1');
  assert.equal(workUsername('#收银_A',true),'#收银_ a'.replace('_ ','_'));
  assert.equal(workUsername('owner'),'owner');
  assert.throws(()=>workUsername('',true),/invalid_work_username/);
  assert.throws(()=>workUsername('店员'.repeat(21),true),/invalid_work_username/);
  assert.throws(()=>workUsername('staff\n2',true),/invalid_work_username/);
  assert.throws(()=>workUsername('阿明',false),/invalid_username/);

  const migration=fs.readFileSync(path.join(__dirname,'../supabase/migrations/20261016154331_staff_cashier_custom_usernames_v1.sql'),'utf8');
  assert.match(migration,/DROP CONSTRAINT IF EXISTS work_username_format/i);
  assert.match(migration,/char_length\(username\) BETWEEN 1 AND 40/i);
  assert.match(migration,/username = lower\(btrim\(username\)\)/i);
  console.log('PASS: custom Staff/Cashier usernames accept Chinese, spaces and symbols; length, control characters and legacy Owner Limited format remain checked.');
})().catch(e=>{console.error(e);process.exitCode=1;});
