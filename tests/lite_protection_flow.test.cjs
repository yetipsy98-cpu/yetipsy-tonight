const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const read=p=>fs.readFileSync(path.join(__dirname,'..',p),'utf8');
test('Registration associates device before issuing welcome rewards',()=>{
 const edge=read('supabase/functions/yt-pin-auth/index.ts');
 assert.ok(edge.indexOf("admin.rpc('yt_lite_register_device'")>0);
 assert.ok(edge.indexOf("admin.rpc('yt_lite_register_device'")<edge.indexOf("admin.rpc('yt_member_onboard'"));
 assert.ok(edge.includes("await admin.auth.admin.deleteUser(uid)"));
});
test('Server keys device tokens; browser does not store raw digest',()=>{
 const edge=read('supabase/functions/yt-pin-auth/index.ts');
 const browser=read('play/lite-protection.js');
 assert.ok(edge.includes("name:'HMAC'"));
 assert.ok(edge.includes("yt-lite-device-v1:"));
 assert.ok(browser.includes("action:'device_link'"));
 assert.ok(!browser.includes("yt_lite_link_my_device"));
});
test('Only new-user promos held at fifth linked account',()=>{
 const sql=read('sql/077_lite_promo_hold.sql');
 assert.ok(sql.includes("p_kind in ('welcome','friend')"));
 assert.ok(sql.includes("count(distinct other.user_id)>=5"));
 assert.ok(sql.includes('yt_lite_held_promos'));
});
test('Owner release processes pending promos and requires owner authorization',()=>{
 const sql=read('sql/079_lite_release_held_promos.sql');
 assert.ok(sql.includes('private.yt_work_owner()'));
 assert.ok(sql.includes('private.yt_award_promo('));
 assert.ok(sql.includes('FOR UPDATE'));
});
