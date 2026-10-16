const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const migration=fs.readFileSync(path.join(__dirname,'../supabase/migrations/20261016125818_owner_reset_storebox_reopen_requests_fk.sql'),'utf8');
const replacement=migration.match(/v_replacement text := '([^']+)'/);
assert(replacement,'reset migration must declare a replacement Store Box truncate statement');
for(const child of ['yt_store_box_events','yt_store_box_requests','yt_store_box_reopen_requests','yt_store_box_claims']){
  assert(replacement[1].includes('public.'+child),`Store Box reset must truncate FK child ${child}`);
}
assert(replacement[1].includes('public.yt_store_boxes restart identity'),'Store Box parent must be truncated with its children');
assert(migration.includes("'private.yt_owner_reset_v9(uuid,text,text,uuid,uuid,bigint[],text[])'::regprocedure"),'migration must patch the active reset function signature');
console.log('PASS: Store Box reset includes every child table that references yt_store_boxes.');
