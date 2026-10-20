const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.join(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const html=read('play/admin/pos/index.html');

test('workbench exposes one Store Box tab and one Owner drawer',()=>{
 assert.match(html,/id="tab-storebox"/);
 assert.match(html,/id="storeBoxStaffRoot"/);
 assert.match(html,/data-pane="storebox"/);
 assert.match(html,/id="storeBoxOwnerRoot"/);
});
test('all work roles resolve to canonical POS and can open Store Box',()=>{
 const js=read('play/pos/pos.js');
 assert.match(js,/\['storebox','存酒箱'\]/);
 assert.match(js,/tab==='storebox'\)storeBox\?\.loadStaff/);
 assert.match(js,/createStoreBox\(\{db,ownerRoot:/);
 assert.match(js,/loadOrderQueue\(silent\)/);
 assert.match(js,/has-alert/);
 for(const page of ['pos','owner','staff','cashier'])assert(read(`play/${page}/index.html`).includes('admin/pos/'),page+' alias route');
});
test('table number help is visible in work orders and customer Store Box calls',()=>{
 const customer=read('play/customer-store-box.js');
 assert.match(customer,/不确定桌号？看指引图/);
 assert.match(customer,/table-number-guide\.jpg/);
 assert.match(html,/不确定桌号？看指引图/);
 assert.match(html,/table-number-guide\.jpg/);
});
test('Store Box client uses the protected RPC workflow',()=>{
 const js=read('play/pos/store-box.js');
 for(const name of ['yt_store_box_rule_list','yt_store_box_rule_save_v2','yt_store_box_issue_orders','yt_store_box_issue','yt_store_box_claims_active','yt_store_box_claim_cancel','yt_store_box_queue','yt_store_box_staff_boxes','yt_store_box_request_action','yt_store_box_progress'])assert.ok(js.includes(name),name);
 assert.match(js,/data-box-kind/);assert.match(js,/data-box-components/);assert.match(js,/data-box-selection/);assert.match(js,/p_components:components/);assert.match(js,/p_selection_mode:/);assert.match(js,/selectionText\(row\.selections\)/);assert.match(js,/存酒箱叫酒/);assert.match(js,/kds-ticket/);assert.match(js,/storebox-history/);assert.doesNotMatch(js,/喝完/);assert.match(js,/确认已经出杯/);assert.match(js,/已生成 · 待顾客领取/);assert.match(js,/addEventListener\('submit'/);assert.match(js,/event\.preventDefault\(\)/);assert.match(js,/保存中…/);
});
test('Package and challenge checkout issues the customer claim code immediately',()=>{
 const js=read('play/pos/pos.js');
 assert.match(js,/row\.status==='confirmed'&&row\.store_box_only/);assert.match(js,/收款并发领取码/);assert.match(js,/result\.store_box_claims\?\.length/);assert.match(js,/showCheckoutStoreBoxClaims/);assert.match(js,/url\.searchParams\.set\('box',claim\.claim_token\)/);
 assert.match(html,/id="orderCartClaims"/);assert.match(html,/20261012-v22|20261013-unified-pos-v[12]|20261015-(?:order-approvals-v2|admin-pos-unified-v3|benefit-summary-(?:paynow|modal)-v1|checkout-direct-default-v2|package-kds-prep-v[12]|reward-editor-modes-v1)/);assert.match(html,/id="storeBoxOrderQueue"/);
});
test('Owner can copy an existing menu item into an editable new item',()=>{
 const js=read('play/pos/pos.js');assert.match(js,/data-copy-product/);assert.match(js,/function copyProduct\(id\)/);assert.match(js,/productId'\)\.value=''/);assert.match(js,/副本/);
});


test('Cashier can arrange KDS service for claimed Store Box balances and Owner can approve reopen requests',()=>{
 const js=read('play/pos/store-box.js');
 assert.match(js,/cashier_serve_allowed/);
 assert.match(js,/yt_store_box_cashier_request/);
 assert.match(js,/yt_store_box_staff_search/);
 assert.match(js,/data-box-search/);
 assert.match(js,/yt_store_box_reopen_list/);
 assert.match(js,/yt_store_box_reopen_review/);
 assert.match(js,/storebox-cashier-kds-fold/);
 assert.match(js,/data-box-reopen-action/);
 assert.match(js,/存酒编号/);
});

test('customer sees each box number and timestamped serving history but cannot request reopening',()=>{
 const js=read('play/customer-store-box.js');
 assert.match(js,/row\.box_number/);
 assert.match(js,/served_history/);
 assert.match(js,/served_by_name/);
 assert.doesNotMatch(js,/yt_store_box_reopen_request|data-store-box-reopen|requestReopen/);
 assert.match(js,/year:'numeric'/);
});

test('business day choice is scoped to one submitted order and resets to today',()=>{
 const js=read('play/pos/pos.js');
 assert.match(js,/p_business_day:\$\('orderBusinessDay'\)\?\.value\|\|state\.businessDay/);
 assert.match(js,/orderBusinessDay'\)\.value=state\.businessDay/);
 const html=read('play/admin/pos/index.html');
 assert.match(html,/修改仅适用于本单，下单后恢复今天/);
});

test('Store Box migration keeps reopen requests server-only and reuses configured expiry days',()=>{
 const sql=read('sql/20261016101745_store_box_numbers_cashier_reopen_history.sql');
 assert.match(sql,/yt_store_boxes_box_number_uidx/);
 assert.match(sql,/yt_store_box_reopen_one_pending_uidx/);
 assert.match(sql,/enable row level security/);
 assert.match(sql,/revoke all on public\.yt_store_box_reopen_requests from public,anon,authenticated/);
 assert.match(sql,/private\.yt_business_start\(private\.yt_business_day\(clock_timestamp\(\)\)\+greatest\(1,b\.expiry_days\)\)/);
 assert.match(sql,/b\.customer_id is not null and b\.status='active'/);
});

test('Store Box reopen request foreign keys are indexed',()=>{
 const sql=read('sql/20261016102749_store_box_reopen_request_fk_indexes.sql');
 assert.match(sql,/yt_store_box_reopen_customer_idx/);
 assert.match(sql,/yt_store_box_reopen_reviewed_by_idx/);
});

test('Owner and Cashier can arrange service from all eligible Store Box balances in a compact layout',()=>{
 const js=read('play/pos/store-box.js'),css=read('play/pos/console.css');
 assert.match(js,/!row\.cashier_serve_allowed\|\|!canCashierServe\(\)/);
 assert.match(js,/if\(!canCashierServe\(\)\)throw Error\('cashier_only'\)/);
 assert.match(css,/storebox-balance-panel \.storebox-fold-body>\.storebox-stack\{grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
 assert.match(css,/@media\(max-width:700px\)\{\.storebox-balance-panel \.storebox-fold-body>\.storebox-stack\{grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
});
test('custom drink bindings are one customer per order and reusable across distinct orders',()=>{
 const migration=read('supabase/migrations/20261016104819_storebox_compact_and_custom_order_member_binding.sql');
 const pos=read('play/pos/pos.js'),upgrade=read('play/pos/play-upgrade.js');
 assert.match(migration,/yt_pos_custom_order_members \([\s\S]*order_id uuid primary key/);
 assert.match(migration,/custom_order_already_bound/);
 assert.match(migration,/on conflict\s*\(custom_drink_id,customer_id\) do nothing/);
 assert.match(migration,/custom_bound',exists\(select 1 from private\.yt_pos_custom_order_members cm where cm\.order_id=i\.order_id\)/);
 assert.match(migration,/private\.yt_pos_custom_order_members,public\.yt_pos_custom_drink_members/);
 assert.match(pos,/customItems\.some\(item=>!item\.custom_bound\)/);
 assert.match(upgrade,/custom_order_already_bound:'本单已绑定其他会员/);
});

test('Staff can bind regular paid POS orders and Cashier Store Box calls auto-accept into KDS',()=>{
 const migration=read('supabase/migrations/20261016110920_pos_member_binding_staff_storebox_auto_accept.sql');
 const pos=read('play/pos/pos.js'),box=read('play/pos/store-box.js'),css=read('play/pos/console.css');
 assert.match(migration,/yt_pos_work_staff\(\) or private\.yt_work_owner\(\)/);
 assert.match(migration,/status,accepted_by,accepted_at/);
 assert.match(migration,/'accepted',actor,clock_timestamp\(\)/);
 assert.match(pos,/isCashier\(\)\|\|isOwner\(\)\|\|isStaff\(\)/);
 assert.match(pos,/const paidAtMs=Date\.parse\(row\.paid_at\|\|''\)[\s\S]*Date\.now\(\)-paidAtMs<86400000/);
 assert.doesNotMatch(box,/storebox-qr-table/);assert.match(box,/查看领取详情/);assert.match(box,/storebox-history-box/);
 assert.match(css,/storebox-issue-item\.kds-ticket,\.storebox-claim\.kds-ticket\{display:grid/);
});

test('Store Box history is one expandable entry per number and POS clears table after submit',()=>{
 const box=read('play/pos/store-box.js'),history=box.slice(box.indexOf('function renderHistory()'),box.indexOf('async function loadHistory'));
 assert.match(history,/groups=new Map\(\)/);
 assert.match(history,/box\.box_number/);
 assert.match(history,/storebox-history-box/);assert.match(history,/查看详情/);assert.match(history,/出酒 \/ 操作记录/);
 assert.doesNotMatch(history,/table_label/);
 const card=box.slice(box.indexOf('function boxCard'),box.indexOf('function boxesMarkup'));
 assert.doesNotMatch(card,/table_label/);
 assert.match(card,/storebox-owner-fold/);
 assert.match(card,/claimed_at/);
 const pos=read('play/pos/pos.js');
 assert.match(pos,/state\.pendingSubmit=null;state\.cart\.clear\(\)[\s\S]*\$\('tableInput'\)\.value=''/);
});
