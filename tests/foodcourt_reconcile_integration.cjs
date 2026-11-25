// Real production revision and FreeFlow triggers; reuse their shared schema fixtures.
const fs=require('node:fs');
const bootstrap=fs.readFileSync('tests/order_append_integration.cjs','utf8').split('const uid=n=>')[0];
const amba=fs.readFileSync('tests/amba_order_revision_integration.cjs','utf8').split('const checks=String.raw`')[1].split('const uid=n=>')[0].replaceAll('\\`','`');
const extra=String.raw`
await db.exec(\`
create role service_role;
create function auth.jwt() returns jsonb language sql as $$select '{}'::jsonb$$;
create function private.yt_owner_limited() returns boolean language sql as $$select current_setting('test.role',true)='limited'$$;
create function private.yt_has_role(text) returns boolean language sql as $$select current_setting('test.role',true)=$1$$;
create table private.yt_owner_reset_challenges(id uuid,actor_id uuid,scopes text[]);
alter table yt_member_orders alter column id set default gen_random_uuid();
alter table yt_member_orders add created_by uuid,add paid_at timestamptz,add client_request_id uuid unique,add accepted_at timestamptz,add accepted_by uuid,add checkout_mode text;
alter table yt_shop_products add updated_at timestamptz;
create table public.yt_pos_series(id uuid,name text,benefit_mode text,active boolean,game_plays int);
alter table yt_pos_payment_entries add constraint yt_pos_payment_entries_method_check check(true);
alter table yt_pos_item_units add benefit_status text default 'unconfigured';
create sequence yt_pos_order_serial;
\`);
await db.exec(fs.readFileSync('supabase/migrations/20261023014042_fix_order_revision_payment_method_result_ambiguity.sql','utf8'));
await db.exec(fs.readFileSync('supabase/migrations/20261124090752_independent_freeflow_packages_and_group_orders.sql','utf8'));
await db.exec(fs.readFileSync('supabase/migrations/20261125053442_foodcourt_product_checklist.sql','utf8'));
await db.exec(fs.readFileSync(process.env.FOODCOURT_CART_MIGRATION||'supabase/migrations/20261125061003_foodcourt_owner_cart.sql','utf8'));
await db.exec(fs.readFileSync(process.env.FOODCOURT_ALLOCATION_GUARD||'supabase/migrations/20261125061157_foodcourt_allocation_guard.sql','utf8'));
const uid=n=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0'),q=async(s,p)=>(await db.query(s,p)).rows;
const ids={owner:uid(1),cashier:uid(2),staff:uid(3),customer:uid(4),limited:uid(5)};for(const id of Object.values(ids))await q('insert into auth.users values($1)',[id]);
const actor=role=>q("select set_config('test.role',$1,false),set_config('test.uid',$2,false)",[role,ids[role]]);
const day=(await q('select (current_date-1)::text as day'))[0].day;
const rpc=async(a,d={})=>(await q('select public.yt_foodcourt_reconcile($1,$2::jsonb) r',[a,JSON.stringify({day,...d})]))[0].r;
await actor('owner');
const drink=uid(10),pack=uid(11),menu=uid(12),second=uid(13);
await q("insert into yt_shop_products(id,title,price_rm) values($1,'Lychee',25),($2,'Other drink',20)",[drink,second]);
await q("insert into yt_freeflow_menus(id,name,start_time,end_time) values($1,'FreeFlow Menu','19:30','00:30')",[menu]);await q('insert into yt_freeflow_menu_items values($1,$2)',[menu,drink]);
await q("select public.yt_freeflow('package_save',$1::jsonb)",[JSON.stringify({id:pack,name:'FreeFlow Glass',price_rm:45,pax_per_unit:1,menu_id:menu,active:true})]);
await q("insert into yt_pos_day_closings(business_day,state) values($1,'closed')",[day]);
// Supplement is a new fulfilled bill, no kitchen chit/session/commission, no claimable units.
const add={request_id:uid(20),product_id:drink,quantity:10,unit_price_rm:25,expected_price:25};
const first=await rpc('supplement',add);assert.equal(first.amount_rm,250);assert.match(first.order_no,/^YT\d{6}-\d{6}$/);
assert.equal((await rpc('supplement',add)).retried,true);await assert.rejects(()=>rpc('supplement',{...add,quantity:2}),/request_conflict/);
const ff=await rpc('supplement',{request_id:uid(21),product_id:pack,quantity:3,unit_price_rm:45,expected_price:45});
assert.equal(Number((await q('select count(*) n from yt_freeflow_sessions'))[0].n),0);
assert.equal(Number((await q('select count(*) n from yt_pos_order_chits'))[0].n),0);
assert.equal(Number((await q("select count(*) n from yt_pos_item_units where benefit_status<>'void'"))[0].n),0);
assert.equal((await q('select method from yt_pos_payment_entries where order_id=$1',[ff.order_id]))[0].method,'Freeflow-Foodcourt');
const raw=(await q('select * from yt_member_orders where id=$1',[first.order_id]))[0];assert.equal(raw.status,'fulfilled');assert.equal(raw.pos_business_day.toISOString().slice(0,10),day);
let overview=await rpc('day');assert.equal(overview.rows.length,2);assert.equal(overview.rows.find(r=>r.product_id===drink).quantity,10);assert.equal(overview.rows.find(r=>r.product_id===pack).quantity,3,'FreeFlow is one directly sold product, no cup expansion');
let row=overview.rows.find(r=>r.product_id===drink);await actor('cashier');
for(const action of ['day','mark','context','orders','preview','supplement','revise'])await assert.rejects(()=>rpc(action,{...add,order_id:first.order_id,product_key:row.product_key,fingerprint:row.fingerprint,checked:true}),/owner_only/);
for(const role of ['staff','customer','limited']){await actor(role);await assert.rejects(()=>rpc('day'),/owner_only/);}
await actor('owner');await rpc('mark',{product_key:row.product_key,fingerprint:row.fingerprint,checked:true});assert.equal((await rpc('day')).rows.find(r=>r.product_id===drink).checked,true);

// Two bills for the same item are selectable. Editing one leaves the other intact.
const other=await rpc('supplement',{...add,request_id:uid(23),quantity:2});overview=await rpc('day');row=overview.rows.find(r=>r.product_id===drink);assert.equal(row.quantity,12);assert.equal(row.orders.length,2);assert.equal(row.checked,false);await assert.rejects(()=>rpc('mark',{product_key:row.product_key,fingerprint:'old',checked:true}),/order_changed_reload/);
const revise=async(order_id,quantity,request_id,extra={})=>{const c=await rpc('context',{order_id});const items=quantity?c.items.map(i=>({item_id:i.id,product_id:i.product_id,quantity,unit_price_rm:i.unit_price_rm})):[];const cancel=quantity===0;const p=await rpc('preview',{order_id,items,cancel});const payload={order_id,request_id,expected_updated:c.updated_at,items,cancel,expected_net:p.net,expected_balance:p.balance_rm,...extra};return {payload,result:await rpc('revise',payload)};};
const reduced=await revise(first.order_id,8,uid(30));assert.equal(reduced.result.settled_rm,-50);assert.equal((await rpc('revise',reduced.payload)).retried,true);assert.equal(Number((await q('select private.yt_pos_received($1) n',[first.order_id]))[0].n),200);assert.equal(Number((await q('select quantity from yt_member_order_items where order_id=$1',[other.order_id]))[0].quantity),2);
assert((await q('select business_day from yt_pos_payment_entries where order_id=$1',[first.order_id])).every(e=>e.business_day.toISOString().slice(0,10)===day));
const revised=await revise(first.order_id,9,uid(31));assert.equal(revised.result.settled_rm,25);assert.equal(Number((await q('select private.yt_pos_received($1) n',[first.order_id]))[0].n),225);
const ctx=await rpc('context',{order_id:first.order_id});assert(ctx.revisions[0].reason.includes('Foodcourt 对账'));assert.equal(ctx.revisions.length,2);assert.equal(ctx.revisions[1].before_state.items[0].quantity,10);
await assert.rejects(()=>rpc('revise',{...revised.payload,request_id:uid(32)}),/order_changed_reload/);
// Entire cancellation settles refund atomically, retains snapshots and quantity-zero history.
await revise(other.order_id,0,uid(33));assert.equal((await rpc('context',{order_id:other.order_id})).payment_status,'refunded');overview=await rpc('day');assert.equal(overview.rows.find(r=>r.product_id===drink).quantity,9);
// FreeFlow correction still creates no access and cannot issue new benefits.
await revise(ff.order_id,4,uid(34));assert.equal(Number((await q('select count(*) n from yt_freeflow_sessions'))[0].n),0);assert.equal(Number((await q("select count(*) n from yt_pos_item_units where benefit_status<>'void'"))[0].n),0);
assert((await q('select method from yt_pos_payment_entries where order_id=$1',[ff.order_id])).every(e=>e.method==='Freeflow-Foodcourt'),'FreeFlow supplement adjustments retain their payment classification');
const large=await rpc('supplement',{...add,request_id:uid(60),quantity:100});await revise(large.order_id,95,uid(61));assert.equal((await rpc('context',{order_id:large.order_id})).amount_rm,2375);
// Reclassifying a payment does not create a new receipt or duplicate the sale.
await revise(first.order_id,9,uid(62),{payment_method:'cash'});assert((await q("select method from yt_pos_payment_entries where order_id=$1 and kind='sale'",[first.order_id])).every(e=>e.method==='cash'));
assert.equal(Number((await q('select private.yt_pos_received($1) n',[first.order_id]))[0].n),225);
await revise(first.order_id,9,uid(63),{payment_method:'foodcourt'});
// Removing one item preserves another item on the same order.
const multi=await rpc('supplement',{...add,request_id:uid(35),quantity:1});await q("insert into yt_member_order_items(order_id,product_id,item_name,quantity,unit_price_rm) values($1,$2,'Other drink',2,20)",[multi.order_id,second]);await q('update yt_member_orders set amount_rm=65 where id=$1',[multi.order_id]);await q('update yt_pos_payment_entries set amount_rm=65 where order_id=$1',[multi.order_id]);
const mc=await rpc('context',{order_id:multi.order_id}),kept=mc.items.filter(i=>i.product_id===second).map(i=>({item_id:i.id,product_id:i.product_id,quantity:i.quantity,unit_price_rm:i.unit_price_rm}));let pp=await rpc('preview',{order_id:multi.order_id,items:kept,cancel:false});await rpc('revise',{order_id:multi.order_id,request_id:uid(36),expected_updated:mc.updated_at,items:kept,cancel:false,expected_net:pp.net,expected_balance:pp.balance_rm});let after=await rpc('context',{order_id:multi.order_id});assert.equal(after.items.length,1);assert.equal(after.items[0].product_id,second);assert.equal(after.items[0].quantity,2);assert.equal(after.amount_rm,40);
// An incorrect confirmed refund amount is rejected before any revision or money changes.
const c=await rpc('context',{order_id:first.order_id});await assert.rejects(()=>rpc('revise',{order_id:first.order_id,request_id:uid(37),expected_updated:c.updated_at,items:[],cancel:true,expected_net:0,expected_balance:-1}),/settlement_changed_reload/);assert.equal((await rpc('context',{order_id:first.order_id})).amount_rm,225);
// Multi-product cart is one new bill, including direct FreeFlow and regular products.
const batch={request_id:uid(80),items:[{product_id:drink,quantity:2,unit_price_rm:25,expected_price:25},{product_id:pack,quantity:1,unit_price_rm:45,expected_price:45},{product_id:second,quantity:3,unit_price_rm:20,expected_price:20}]};
const countBefore=Number((await q('select count(*) n from yt_member_orders'))[0].n),mixed=await rpc('supplement',batch);assert.equal(mixed.amount_rm,155);assert.equal(Number((await q('select count(*) n from yt_member_orders'))[0].n),countBefore+1);assert.equal((await rpc('context',{order_id:mixed.order_id})).items.length,3);assert.equal((await rpc('supplement',batch)).retried,true);
assert.deepEqual((await q('select method,amount_rm from yt_pos_payment_entries where order_id=$1 order by amount_rm',[mixed.order_id])).map(e=>[e.method,Number(e.amount_rm)]),[['Freeflow-Foodcourt',45],['foodcourt',110]]);
const mixedItems=(await rpc('context',{order_id:mixed.order_id})).items;assert.equal((await q("select private.yt_ff_item_method($1,'foodcourt') m",[mixedItems.find(i=>i.product_id===pack).id]))[0].m,'Freeflow-Foodcourt');
assert.equal(Number((await q('select count(*) n from yt_freeflow_sessions'))[0].n),0);assert.equal(Number((await q('select count(*) n from yt_pos_order_chits'))[0].n),0);
const beforeBad=Number((await q('select count(*) n from yt_member_orders'))[0].n);
await assert.rejects(()=>rpc('supplement',{...batch,request_id:uid(81),items:batch.items.map((i,n)=>n===2?{...i,expected_price:0}:i)}),/product_price_changed/);
assert.equal(Number((await q('select count(*) n from yt_member_orders'))[0].n),beforeBad,'one bad cart line rolls back the entire new bill');
await assert.rejects(()=>rpc('supplement',{...batch,request_id:uid(82),items:[batch.items[0],batch.items[0]]}),/duplicate_product/);
// A zero-net correction reclassifies actual receipts without inventing money/refunds.
const zero=await rpc('supplement',{request_id:uid(83),items:[{product_id:drink,quantity:3,unit_price_rm:15,expected_price:25},{product_id:pack,quantity:1,unit_price_rm:45,expected_price:45}]});
const zc=await rpc('context',{order_id:zero.order_id}),zi=zc.items.filter(i=>i.product_id===drink).map(i=>({item_id:i.id,product_id:i.product_id,quantity:3,unit_price_rm:30}));
pp=await rpc('preview',{order_id:zero.order_id,items:zi,cancel:false});assert.equal(pp.balance_rm,0);
await rpc('revise',{order_id:zero.order_id,request_id:uid(84),expected_updated:zc.updated_at,items:zi,cancel:false,expected_net:90,expected_balance:0});
const sums=(await q("select sum(amount_rm) total,sum(greatest(amount_rm,0)) receipts,sum(least(amount_rm,0)) refunds,coalesce(sum(amount_rm) filter(where method like 'Freeflow-%'),0) ff from yt_pos_payment_entries where order_id=$1",[zero.order_id]))[0];assert.equal(Number(sums.total),90);assert.equal(Number(sums.receipts),90);assert.equal(Number(sums.refunds),0);assert.equal(Number(sums.ff),0);
await revise(zero.order_id,0,uid(85));assert.equal(Number((await q('select private.yt_pos_received($1) n',[zero.order_id]))[0].n),0);
assert.equal((await q("select coalesce(current_setting('yt.foodcourt.reclassify',true),'') state"))[0].state,'','allocation override is restored');
await q("update yt_pos_payment_entries set method='cash' where order_id=$1",[mixed.order_id]);assert.equal(Number((await q("select sum(amount_rm) n from yt_pos_payment_entries where order_id=$1 and method='Freeflow-Cash'",[mixed.order_id]))[0].n),45,'normal payment corrections retain FreeFlow labels');
assert.equal((await q("select has_function_privilege('anon','public.yt_foodcourt_reconcile(text,jsonb)','execute') allowed"))[0].allowed,false);assert.equal((await q("select has_table_privilege('authenticated','private.yt_foodcourt_history_orders','insert') allowed"))[0].allowed,false);
assert.match((await q("select pg_get_functiondef('private.yt_owner_reset_v9(uuid,text,text,uuid,uuid,bigint[],text[])'::regprocedure) d"))[0].d,/truncate table private.yt_foodcourt_checks,private.yt_foodcourt_operations,private.yt_foodcourt_history_orders/);
await db.close();console.log('PASS Foodcourt: product quantities, FreeFlow without access, new bill/no KDS/void benefits, exact retries, Owner-only access, atomic multi-product carts, category accounting/zero-net reclassification, persisted marks/staleness, selectable duplicate bills, individual product deletion, atomic refund/top-up/cancellation, original day and immutable audit.');
})().catch(e=>{console.error(e.message,e.where||'',e.position?e.query?.slice(Number(e.position)-100,Number(e.position)+160):'');process.exit(1);});
`;
new Function('require',bootstrap+amba+extra.replaceAll('\\`','`'))(require);
