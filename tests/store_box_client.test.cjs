const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.join(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');

test('workbench exposes one Store Box tab and one Owner drawer',()=>{
 const html=read('play/pos/index.html');
 assert.match(html,/id="tab-storebox"/);
 assert.match(html,/id="storeBoxStaffRoot"/);
 assert.match(html,/data-owner-tool="storebox"/);
 assert.match(html,/data-pane="storebox"/);
 assert.match(html,/id="storeBoxOwnerRoot"/);
});

test('all work roles can open Store Box without a separate page',()=>{
 const js=read('play/pos/pos.js');
 assert.match(js,/\['storebox','存酒箱'\]/);
 assert.match(js,/tab==='storebox'\)storeBox\?\.loadStaff/);
 assert.match(js,/createStoreBox\(\{db,ownerRoot:/);
});

test('Store Box client uses the protected RPC workflow',()=>{
 const js=read('play/pos/store-box.js');
 for(const name of ['yt_store_box_rule_list','yt_store_box_rule_save','yt_store_box_issue_orders','yt_store_box_issue_quote','yt_store_box_issue','yt_store_box_claims_active','yt_store_box_claim_cancel','yt_store_box_queue','yt_store_box_staff_boxes','yt_store_box_request_action','yt_store_box_progress'])assert.ok(js.includes(name),name);
 assert.match(js,/p_game_pass_enabled:false/);
 assert.match(js,/同时确认已喝完几杯/);
 assert.match(js,/全店待领取码/);
});
