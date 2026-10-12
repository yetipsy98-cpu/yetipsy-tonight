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
 assert.match(js,/loadOrderQueue\(silent\)/);
 assert.match(js,/has-alert/);
});

test('table number help is visible in work orders and customer Store Box calls',()=>{
 const customer=read('play/customer-store-box.js');
 assert.match(customer,/不确定桌号？看指引图/);
 assert.match(customer,/table-number-guide\.jpg/);
 for(const page of ['pos','owner','staff','cashier']){
  const html=read(`play/${page}/index.html`);
  assert.match(html,/不确定桌号？看指引图/);
  assert.match(html,/table-number-guide\.jpg/);
 }
});

test('Store Box client uses the protected RPC workflow',()=>{
 const js=read('play/pos/store-box.js');
 for(const name of ['yt_store_box_rule_list','yt_store_box_rule_save_v2','yt_store_box_issue_orders','yt_store_box_issue_quote','yt_store_box_issue','yt_store_box_claims_active','yt_store_box_claim_cancel','yt_store_box_queue','yt_store_box_staff_boxes','yt_store_box_request_action','yt_store_box_progress'])assert.ok(js.includes(name),name);
 assert.match(js,/data-box-kind/);
 assert.match(js,/data-box-components/);
 assert.match(js,/data-box-selection/);
 assert.match(js,/p_components:components/);
 assert.match(js,/p_selection_mode:/);
 assert.match(js,/selectionText\(row\.selections\)/);
 assert.match(js,/存酒箱叫酒/);
 assert.match(js,/kds-ticket/);
 assert.match(js,/storebox-history/);
 assert.doesNotMatch(js,/喝完/);
 assert.match(js,/确认已经出杯/);
 assert.match(js,/全店待领取码/);
 assert.match(js,/addEventListener\('submit'/);
 assert.match(js,/event\.preventDefault\(\)/);
 assert.match(js,/保存中…/);
});

test('Package and challenge checkout issues the customer claim code immediately',()=>{
 const js=read('play/pos/pos.js');
 assert.match(js,/row\.status==='confirmed'&&row\.store_box_only/);
 assert.match(js,/收款并发领取码/);
 assert.match(js,/result\.store_box_claims\?\.length/);
 assert.match(js,/showCheckoutStoreBoxClaims/);
 assert.match(js,/url\.searchParams\.set\('box',claim\.claim_token\)/);
 for(const page of ['pos','owner','staff','cashier']){
  const html=read(`play/${page}/index.html`);
  assert.match(html,/id="orderCartClaims"/);
  assert.match(html,/20261012-bilingual-receipt-v19/);
  assert.match(html,/id="storeBoxOrderQueue"/);
 }
});

test('Owner can copy an existing menu item into an editable new item',()=>{
 const js=read('play/pos/pos.js');
 assert.match(js,/data-copy-product/);
 assert.match(js,/function copyProduct\(id\)/);
 assert.match(js,/productId'\)\.value=''/);
 assert.match(js,/副本/);
});
