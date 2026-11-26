const {PGlite}=require('@electric-sql/pglite'),fs=require('node:fs'),assert=require('node:assert/strict');
(async()=>{
 const db=new PGlite();await db.exec(`
 create schema auth;create schema private;create role anon;create role authenticated;grant usage on schema auth,private to authenticated;
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.uid',true),'')::uuid$$;
 create function private.yt_pos_work_staff() returns boolean language sql stable as $$select current_setting('test.role',true) in ('owner','cashier','staff','waiter')$$;
 create table public.profiles(id uuid,display_name text);
 create table public.yt_member_orders(id uuid,status text,payment_status text,cancel_after_refund boolean);
 create table public.yt_freeflow_sessions(id uuid,order_id uuid,capacity integer,status text,bind_token uuid,token_expires_at timestamptz,ends_at timestamptz);
 create table public.yt_freeflow_members(id uuid,session_id uuid,guest_id uuid,customer_id uuid,status text,bound_at timestamptz);
 `);
 const file=process.argv[2]||fs.readdirSync('supabase/migrations').find(f=>f.endsWith('_freeflow_qr_binding_feedback.sql'));
 await db.exec(fs.readFileSync(process.argv[2]||'supabase/migrations/'+file,'utf8'));
 const uid=n=>'00000000-0000-4000-8000-'+String(n).padStart(12,'0'),q=async(s,p)=>(await db.query(s,p)).rows;
 const actor=async(role,id=uid(1))=>q("select set_config('test.role',$1,false),set_config('test.uid',$2,false)",[role,id]);
 const rpc=async()=>(await q('select public.yt_freeflow_binding_status($1,$2) result',[uid(2),uid(4)]))[0].result;
 await q("insert into yt_member_orders values($1,'fulfilled','unpaid',false)",[uid(3)]);
 await q("insert into yt_freeflow_sessions values($1,$2,3,'active',$3,now()+interval '5 minutes',now()+interval '1 hour')",[uid(2),uid(3),uid(4)]);
 await q("insert into yt_freeflow_members values($1,$2,$3,null,'active',now()),($4,$5,$6,null,'active',now())",[uid(5),uid(2),uid(6),uid(7),uid(8),uid(9)]);
 for(const role of ['owner','cashier','staff','waiter']){await actor(role);const r=await rpc();assert.equal(r.members.length,1);assert.equal(r.members[0].guest,true);assert.equal(r.token_valid,true);assert(!JSON.stringify(r).includes('customer_id'));assert(!JSON.stringify(r).includes(uid(6)));}
 await q("update yt_freeflow_members set guest_id=null,customer_id=$1 where id=$2",[uid(10),uid(5)]);await q("insert into profiles values($1,'Alice')",[uid(10)]);assert.equal((await rpc()).members[0].name,'Alice');assert.equal((await rpc()).members[0].guest,false);
 await q("update yt_freeflow_sessions set bind_token=$1",[uid(11)]);assert.equal((await rpc()).token_valid,false);
 await q("update yt_freeflow_sessions set bind_token=$1",[uid(4)]);await q("update yt_member_orders set status='cancelled'");assert.equal((await rpc()).token_valid,false);
 await actor('customer');await assert.rejects(rpc,/staff_only/);await actor('staff','');await assert.rejects(rpc,/staff_only/);
 await actor('staff');await db.exec('set role authenticated');assert.equal((await rpc()).members.length,1);await db.exec('reset role;set role anon');await assert.rejects(rpc,/permission denied/);await db.exec('reset role');
 await db.close();console.log('PASS binding status: staff roles only, anon/customer denied, selected-group-only metadata, guest-to-member conversion, QR rotation and cancelled-order invalidation.');
})().catch(e=>{console.error(e);process.exit(1);});
