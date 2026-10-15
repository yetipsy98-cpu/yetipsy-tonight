const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.join(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');

test('Store Box pending generation is automatic and spans all eligible orders',()=>{
 const js=read('play/pos/store-box.js');
 assert.match(js,/order\.items\|\|\[\]/);
 assert.match(js,/state\.pendingIssue/);
 assert.match(js,/完成付款的存酒箱订单会显示在这里/);
 assert.doesNotMatch(js,/data-box-order|yt_store_box_issue_quote|selectedOrder/);
 assert.match(js,/data-box-issue=/);
});

test('Owner controls review; disabling it confirms Staff orders and enqueues KDS transactionally',()=>{
 const html=read('play/pos/index.html'),consoleJs=read('play/pos/console.js'),sql=read('sql/097_storebox_auto_issue_order_review.sql');
 assert.match(html,/staffOrderReviewEnabled/);
 assert.match(html,/后续出品、挂单与收款流程照常进行/);
 assert.match(consoleJs,/yt_pos_order_review_setting_get/);
 assert.match(consoleJs,/yt_pos_order_review_setting_save/);
 assert.match(sql,/require_review boolean not null default true/);
 assert.match(sql,/if not private\.yt_work_owner\(\) then raise exception 'owner_only'/);
 assert.match(sql,/p_channel='staff' and existing_status='pending'/);
 assert.match(sql,/insert into public\.yt_pos_order_chits\(order_id\)/);
 assert.match(sql,/insert into public\.yt_pos_order_events\(order_id,actor_id,event_type,source,note\)/);
 assert.match(sql,/yt_store_box_order_only\(v_order\)/);
 assert.match(sql,/create or replace function public\.yt_pos_order_review_setting_save/);
});
