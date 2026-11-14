// Reuse the established FreeFlow + unpaid-order schema harness; load real revision RPCs below.
const fs=require('node:fs');const bootstrap=fs.readFileSync('tests/order_append_integration.cjs','utf8').split('const uid=n=>')[0];
const checks=String.raw`
await db.exec(\`
alter table public.yt_member_orders add revision int default 0,add payment_method text default 'AB_Cash';
alter table public.yt_member_order_items add series_id_at_order uuid;
alter table public.yt_shop_products add series_id uuid;
alter table public.yt_pos_item_units add reward_discount_rm numeric default 0,add retired boolean default false;
alter table public.yt_ambassador_checkins add male_price numeric default 45,add female_price numeric default 45;
create table public.yt_pos_order_revisions(id uuid primary key default gen_random_uuid(),order_id uuid,revision int,request_id uuid unique,request_payload jsonb,reason text,actor_id uuid,before_state jsonb,after_state jsonb,revoke_benefits boolean,created_at timestamptz default clock_timestamp());
create table public.yt_pos_owner_revision_requests(id uuid primary key,order_id uuid,requester_id uuid,request_payload jsonb,status text default 'pending',reviewer_id uuid,reviewed_at timestamptz,review_note text,result jsonb,updated_at timestamptz);
create table public.yt_pos_reward_holds(order_id uuid,state text,updated_at timestamptz);
create table public.yt_pos_preorder_holds(attached_order_id uuid,state text,updated_at timestamptz);
create table public.yt_pos_order_backdate_requests(order_id uuid,status text,requested_business_day date,reviewer_id uuid,reviewed_at timestamptz,review_note text);
create function private.yt_pos_order_benefits(uuid) returns jsonb language sql as $$select '{}'::jsonb$$;
create function private.yt_pos_revoke_order_benefits(uuid) returns jsonb language sql as $$select '{}'::jsonb$$;
create function private.yt_pos_bill_v8(uuid) returns jsonb language sql as $$select to_jsonb(o)||jsonb_build_object('received_rm',private.yt_pos_received(o.id),'balance_rm',o.amount_rm-private.yt_pos_received(o.id)) from public.yt_member_orders o where o.id=$1$$;
\`);
await db.exec(baseline('supabase/migrations/20261014094600_cashier_revision_approval_owner_limited.sql','private.yt_pos_owner_revision_preview'));
for(const name of ['private.yt_pos_owner_revision_apply_v2','private.yt_pos_owner_revision_request_submit_v2','private.yt_pos_owner_revision_request_review'])await db.exec(baseline('supabase/migrations/20261023100000_order_revision_payment_method.sql',name));
await db.exec(fs.readFileSync('supabase/migrations/20261114054755_amba_order_revision.sql','utf8'));
await db.exec(fs.readFileSync('supabase/migrations/20261114055440_amba_revision_cashier_collection.sql','utf8'));
const uid=n=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0'),q=async(s,p)=>(await db.query(s,p)).rows;
const owner=uid(1),cashier=uid(2),customer=uid(3),product=uid(4);for(const id of [owner,cashier,customer])await q('insert into auth.users values($1)',[id]);
const actor=role=>q("select set_config('test.role',$1,false),set_config('test.uid',$2,false)",[role,role==='owner'?owner:role==='cashier'?cashier:customer]);
await actor('owner');await q("insert into yt_shop_products(id,title,price_rm) values($1,'Normal Drink',25)",[product]);
const order=uid(10),mi=uid(11),fi=uid(12),menu=uid(13),session=uid(14),member=uid(15);
await q("insert into yt_member_orders(id,amount_rm,payment_status,pos_business_day) values($1,90,'paid',current_date-1)",[order]);
await q("insert into yt_member_order_items(id,order_id,item_name,quantity,unit_price_rm) values($1,$3,'Freeflow Male',1,45),($2,$3,'Freeflow Female',1,45)",[mi,fi,order]);
await q("insert into yt_ambassador_pos_sales(order_id,business_day,male_count,female_count) values($1,current_date-1,1,1)",[order]);
await q("insert into yt_pos_payment_entries(order_id,request_id,amount_rm,kind,method,business_day) values($1,$2,90,'sale','AB_Cash',current_date-1)",[order,uid(16)]);
await q("insert into yt_ambassador_checkins(request_id,ambassador_id,male_count,female_count,sales,commission_amount,business_day) values($1,$2,1,1,90,9,current_date-1)",[order,owner]);
await q("insert into yt_freeflow_menus(id,name) values($1,'Menu')",[menu]);
await q("insert into yt_freeflow_sessions(id,order_id,menu_id,capacity,table_label,business_day,starts_at,ends_at,created_by) values($1,$2,$3,2,'A1',current_date-1,clock_timestamp()-interval '1 hour',clock_timestamp()+interval '3 hours',$4)",[session,order,menu,owner]);
await q('insert into yt_freeflow_members(id,session_id,customer_id) values($1,$2,$3)',[member,session,customer]);
const male=(n,price=45)=>({item_id:mi,product_id:null,amba_kind:'male',quantity:n,unit_price_rm:price}),female=(n,price=45)=>({item_id:fi,product_id:null,amba_kind:'female',quantity:n,unit_price_rm:price});
const preview=async(o,items)=>(await q('select private.yt_pos_owner_revision_preview($1,$2::jsonb,false) r',[o,JSON.stringify(items)]))[0].r;
const revision=async(items,request=uid(20),cancel=false,o=order,day=null)=>{const expected=(await q('select updated_at from yt_member_orders where id=$1',[o]))[0].updated_at;const args=[o,JSON.stringify(items),'调整 Amba 人数','B2','test',expected,request,false,cancel,null,day];return {args,result:(await q('select private.yt_pos_owner_revision_apply_v3($1,$2::jsonb,$3,$4,$5,$6,$7,$8,$9,$10,$11) r',args))[0].r};};
const apply=args=>q('select private.yt_pos_owner_revision_apply_v3($1,$2::jsonb,$3,$4,$5,$6,$7,$8,$9,$10,$11) r',args);
let context=(await q('select private.yt_pos_owner_order_context($1) r',[order]))[0].r;assert.equal(context.amba.male_count,1);assert.equal(context.items.find(i=>i.id===mi).amba_kind,'male');
await assert.rejects(()=>preview(order,[male(1),male(1)]),/invalid_amba_line/);await assert.rejects(()=>preview(order,[{product_id:product,quantity:1}]),/amba_person_required/);
let saved=await revision([male(2),female(1)]);assert.equal(saved.result.amount_rm,135);assert.equal(saved.result.balance_rm,45);assert.equal(saved.result.payment_status,'paid');assert.equal((await apply(saved.args))[0].r.retried,true);await assert.rejects(()=>apply(saved.args.map((a,i)=>i===2?'different':a)),/request_conflict/);
assert.equal(Number((await q('select private.yt_pos_received($1) n',[order]))[0].n),90);assert.equal((await q('select capacity from yt_freeflow_sessions where id=$1',[session]))[0].capacity,3);assert.equal((await q('select id from yt_member_order_items where id=$1',[mi]))[0].id,mi);
assert.equal(Number((await q('select commission_amount from yt_ambassador_checkins where request_id=$1',[order]))[0].commission_amount),9,'increased entitlement does not imply cash received');
await q("select private.yt_pos_adjustment_pay($1,45,'cash','收到差价',$2)",[order,uid(21)]);assert.equal(Number((await q('select commission_amount from yt_ambassador_checkins where request_id=$1',[order]))[0].commission_amount),13.5);
let lower=await revision([male(1,40),female(1,40)],uid(22));assert.equal(lower.result.balance_rm,-55);assert.equal(Number((await q('select private.yt_pos_received($1) n',[order]))[0].n),135,'refund needs actual confirmation');assert.equal((await q('select capacity from yt_freeflow_sessions where id=$1',[session]))[0].capacity,2);assert.equal(Number((await q('select amount from yt_ambassador_ledger'))[0].amount),8);
await q("select private.yt_pos_adjustment_pay($1,-20,'cash','已退部分',$2)",[order,uid(23)]);await q("select private.yt_pos_adjustment_pay($1,-35,'cash','已退余额',$2)",[order,uid(24)]);assert.equal(Number((await q('select private.yt_pos_received($1) n',[order]))[0].n),80);
// Both pending cups and all occupied bindings protect a reduction. Failed edits are atomic.
await q("insert into yt_freeflow_requests(member_id,customer_id,product_id,item_name,table_label,request_id) values($1,$2,$3,'Drink','B2',$4),($1,$2,$3,'Drink','B2',$5)",[member,customer,product,uid(30),uid(31)]);
await assert.rejects(()=>revision([male(1,40)],uid(32)),/amba_capacity_in_use/);assert.equal(Number((await q('select amount_rm from yt_member_orders where id=$1',[order]))[0].amount_rm),80);
await q("update yt_freeflow_requests set status='cancelled'");await q('insert into yt_freeflow_members(session_id,customer_id) values($1,$2)',[session,cashier]);await assert.rejects(()=>preview(order,[male(1,40)]),/amba_capacity_in_use/);
// Cashier cannot directly apply or override price; approval uses the same synchronisation hook.
await actor('cashier');await assert.rejects(()=>revision([male(2),female(1)],uid(33)),/owner_only/);
let expected=(await q('select updated_at from yt_member_orders where id=$1',[order]))[0].updated_at;
const request=uid(34);let submitted=(await q("select private.yt_pos_owner_revision_request_submit_v2($1,$2::jsonb,'人数改为三人','B2',null,$3,false,$4,null) r",[order,JSON.stringify([male(2,1),female(1,1)]),expected,request]))[0].r;assert.equal(submitted.status,'pending');assert.equal(Number((await q('select amount_rm from yt_member_orders where id=$1',[order]))[0].amount_rm),80);
await actor('owner');await q("select private.yt_pos_owner_revision_request_review($1,true,'核实人数',false)",[request]);assert.equal(Number((await q('select amount_rm from yt_member_orders where id=$1',[order]))[0].amount_rm),120,'cashier supplied prices stripped; current snapshot remains RM40');assert.equal((await q('select capacity from yt_freeflow_sessions where id=$1',[session]))[0].capacity,3);
// Cashier can collect a revision's approved positive difference without a prior pax-add audit.
await actor('cashier');await q("select public.yt_freeflow('collect_delta',$1::jsonb)",[JSON.stringify({order_id:order,amount:20,method:'cash',note:'收到改单差价',confirmed:true,request_id:uid(35)})]);await assert.rejects(()=>q("select private.yt_pos_adjustment_pay($1,-1,'cash','cashier refund',$2)",[order,uid(36)]),/owner_only/);await actor('owner');
// Normal category additions coexist with pass lines, and are excluded from commission.
await revision([male(2,40),female(1,40),{product_id:product,quantity:1}],uid(40));await q("select private.yt_pos_adjustment_pay($1,45,'cash','全部收到',$2)",[order,uid(41)]);assert.equal(Number((await q('select commission_amount from yt_ambassador_checkins where request_id=$1',[order]))[0].commission_amount),12);
const entries=await q('select business_day,method from yt_pos_payment_entries where order_id=$1',[order]);assert(entries.every(e=>e.method==='AB_Cash'));assert(entries.every(e=>String(e.business_day)===String(entries[0].business_day)));
// An unpaid Amba revision changes its source entitlement without inventing a payment/check-in.
const tab=uid(60);await q('insert into yt_member_orders(id,amount_rm) values($1,45)',[tab]);await q('insert into yt_ambassador_pos_sales(order_id,business_day,male_count,female_count) values($1,current_date,1,0)',[tab]);await q("insert into yt_member_order_items(order_id,item_name,quantity,unit_price_rm) values($1,'Freeflow Male',1,45)",[tab]);await revision([{amba_kind:'male',quantity:2,unit_price_rm:35}],uid(61),false,tab);assert.equal(Number((await q('select amount_rm from yt_member_orders where id=$1',[tab]))[0].amount_rm),70);assert.equal((await q('select male_count from yt_ambassador_pos_sales where order_id=$1',[tab]))[0].male_count,2);assert.equal(Number((await q('select count(*) n from yt_pos_payment_entries where order_id=$1',[tab]))[0].n),0);assert.equal(Number((await q('select count(*) n from yt_ambassador_checkins where request_id=$1',[tab]))[0].n),0);
// Changing gender retires the old canonical item rather than rewriting its history.
const old=(await q('select quantity from yt_member_order_items where id=$1',[mi]))[0].quantity;assert.equal(old,2);
await revision([{item_id:mi,product_id:null,amba_kind:'female',quantity:3,unit_price_rm:40}],uid(43));assert.equal((await q('select quantity from yt_member_order_items where id=$1',[mi]))[0].quantity,0);assert.equal((await q('select male_count from yt_ambassador_pos_sales where order_id=$1',[order]))[0].male_count,0);
// Whole cancellation closes access, zeroes accrual, preserves money until actual refund.
await revision([],uid(44),true);assert.equal((await q('select status from yt_freeflow_sessions where id=$1',[session]))[0].status,'closed');assert.equal(Number((await q('select count(*) n from yt_ambassador_ledger'))[0].n),0);assert.equal(Number((await q('select private.yt_pos_received($1) n',[order]))[0].n),145);
await q("select private.yt_pos_adjustment_pay($1,-145,'cash','整单已退款',$2)",[order,uid(45)]);assert.equal((await q('select payment_status from yt_member_orders where id=$1',[order]))[0].payment_status,'refunded');
// Ordinary orders keep catalog restrictions and do not gain virtual Amba products.
const normal=uid(50);await q('insert into yt_member_orders(id,amount_rm) values($1,25)',[normal]);await assert.rejects(()=>preview(normal,[{amba_kind:'male',quantity:1}]),/invalid_amba_line/);await revision([{product_id:product,quantity:2}],uid(51),false,normal);assert.equal(Number((await q('select amount_rm from yt_member_orders where id=$1',[normal]))[0].amount_rm),50);
assert.equal((await q("select has_function_privilege('anon','private.yt_pos_amba_revision_sync(uuid,boolean)','execute') allowed"))[0].allowed,false);
await db.close();console.log('PASS Amba revisions: virtual lines, original history, paid increase/decrease, actual partial refunds, commission, bound/pending capacity guards, cashier approval and price protection, exact retries, mixed catalog, cancellation and normal-order regression.');
})().catch(e=>{console.error(e);process.exit(1);});
`;
new Function('require',bootstrap+checks.replaceAll('\\`','`'))(require);
