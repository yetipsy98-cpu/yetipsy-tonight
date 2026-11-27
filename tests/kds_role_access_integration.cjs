const fs=require('node:fs');process.env.KDS_ROLE_SQL=process.argv[2]||'supabase/migrations/'+fs.readdirSync('supabase/migrations').find(f=>f.endsWith('_kds_role_access.sql'));process.argv[2]=undefined;
let source=fs.readFileSync('tests/production_history_integration.cjs','utf8');
const extra=String.raw`
await actor('owner');const actionSql=fs.readFileSync('sql/043_kds_prepayment.sql','utf8');const actionAt=actionSql.indexOf('create or replace function private.yt_pos_action(');await db.exec(actionSql.slice(actionAt,actionSql.indexOf('end '+String.fromCharCode(36,36)+';',actionAt)+7));await db.exec(fs.readFileSync(process.env.KDS_ROLE_SQL,'utf8'));
const operationCount=(await q('select count(*) n from private.yt_kds_operations'))[0].n;
await actor('staff');assert.equal((await snap()).can_manage,false);for(const action of ['claim','serve','release','cancel','mode','history'])await assert.rejects(()=>api(action,operation('order',hi,[1])),/cashier_only/);
assert.equal((await q('select count(*) n from private.yt_kds_operations'))[0].n,operationCount,'denied operations create no retry or audit records');
await assert.rejects(()=>q('select public.yt_pos_item_fulfill($1,$2,false)',[ho,hi]),/cashier_only/);await assert.rejects(()=>q("select private.yt_pos_action($1,'fulfilled',null,null)",[ho]),/cashier_only/);
for(const action of ['accept','serve','cancel'])await assert.rejects(()=>q('select public.yt_store_box_request_action($1,$2,0,$3)',[req2,action,'测试原因']),/cashier_only/);
for(const action of ['complete','complete_group'])await assert.rejects(()=>q('select public.yt_freeflow($1,$2::jsonb)',[action,JSON.stringify({request_id:ff[2].target,session_id:ffgroup,status:'served'})]),/cashier_only/);
const staffHistory=await history();assert(staffHistory.total>0);assert.equal(staffHistory.permissions.can_view_actor,false);assert(staffHistory.rows.every(r=>r.actor_id===null&&r.actor_name===null&&r.reason===null),'server redacts management fields');await assert.rejects(()=>history('cancelled'),/cashier_only/);assert.equal((await history('served','all','owner01')).total,0,'search cannot expose hidden operator names');
await actor('cashier');assert.equal((await history('cancelled')).permissions.can_view_cancelled,true);assert((await history()).rows.some(r=>r.actor_name));assert(Array.isArray(await api('history')));
// Existing effective Cashier permission, rather than a hardcoded role name, controls all production operations.
await actor('owner');version=(await snap()).version;await api('mode',{request_id:crypto.randomUUID(),enabled:true,expected_version:version});await actor('cashier');await api('claim',operation('freeflow',ff[2].target,[1]));await api('serve',operation('freeflow',ff[2].target,[1]));assert.equal((await q('select status from yt_freeflow_requests where id=$1',[ff[2].target]))[0].status,'served');
console.log('PASS KDS role access: Staff reads only, all legacy/multi production writes denied, server-side history redaction and search isolation, Cashier production preserved.');
`;
source=source.replace("await actor('owner');await db.exec('truncate public.yt_freeflow_requests');",extra+"await actor('owner');await db.exec('truncate public.yt_freeflow_requests');");
new Function('require',source)(require);
