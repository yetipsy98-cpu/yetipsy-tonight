const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.join(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');

test('Cashier can directly route unclaimed and issued Store Box orders to KDS',()=>{
 const js=read('play/pos/store-box.js');
 const sql=read('supabase/migrations/20261017160500_store_box_cashier_direct_serve.sql');
 assert.match(js,/cashierDirectServeForm\(row,'issue'\)/);
 assert.match(js,/cashierDirectServeForm\(\{\.\.\.source,cashier_components:row\.components\}/);
 assert.match(js,/data-box-cashier-direct=/);
 assert.match(js,/yt_store_box_cashier_direct_issue/);
 assert.match(js,/row\.mode==='challenge'\?\(index===0\?1:0\)/);
 assert.match(sql,/private\.yt_pos_work_cashier\(\) or private\.yt_work_owner\(\)/);
 assert.match(sql,/status='cancelled'.*claim_token=null/s);
 assert.match(sql,/cashier_direct_serve/);
 assert.match(sql,/b\.mode='challenge' and total_qty<>1/);
 assert.match(sql,/interval '8 hours','accepted',actor,clock_timestamp\(\)/);
 assert.match(sql,/grant execute on function public\.yt_store_box_cashier_direct_issue\(uuid,jsonb,uuid\) to authenticated/);
 assert.match(sql,/revoke all on function public\.yt_store_box_cashier_direct_issue\(uuid,jsonb,uuid\) from public,anon/);
});
