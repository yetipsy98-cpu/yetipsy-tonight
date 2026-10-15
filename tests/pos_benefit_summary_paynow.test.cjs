const fs=require('node:fs');
const assert=require('node:assert/strict');

const js=fs.readFileSync('play/pos/pos.js','utf8');
const migration=fs.readFileSync('supabase/migrations/20261015090114_pos_benefit_operator_audit.sql','utf8');
for(const page of ['play/admin/pos/index.html','play/admin/owner/index.html','play/admin/cashier/index.html','play/admin/staff/index.html','play/owner/index.html','play/cashier/index.html','play/staff/index.html','play/pos/index.html']){
 const html=fs.readFileSync(page,'utf8');
 assert.match(html,/pos\.js\?v=20261015-(?:benefit-summary-(?:paynow|modal)-v1|checkout-direct-default-v2|package-kds-prep-v[12]|reward-editor-modes-v1)/,page+' refreshes benefit summary code');
 assert.match(html,/id="checkoutPayNow"[^>]*checked/,page+' defaults to pay now');
 assert.doesNotMatch(html,/id="checkoutPayLater"[^>]*checked/,page+' does not default to pay later');
 assert.match(html,/id="benefitTitle"/,page+' can reflect the active mode');
}
assert.match(js,/mode=state\.luckyMode\?\.mode\|\|'game'/);
assert.match(js,/mode==='lucky'\?`<button[^`]*分配 Lucky Box/);
assert.match(js,/mode!=='off'\?`<button[^`]*发游戏资格/);
assert.match(js,/data-order-benefit-summary=/);
assert.match(js,/yt_pos_order_benefit_summaries/);
assert.match(js,/data\.member_name/);
assert.match(js,/data\.points_earned/);
assert.match(js,/data\.points_balance/);
assert.match(js,/benefit-summary-dialog/);
assert.match(js,/operator_name/);
assert.match(js,/data\.operator_role/);
assert.match(js,/cartMemberScan/);
assert.match(migration,/yt_pos_log_member_binding_operator/);
assert.match(migration,/operator_account\.username/);
assert.match(js,/checkoutMode==='pay_now'/);
assert.match(js,/const mode=state\.pendingSubmit\?\.p_checkout_mode\|\|'pay_now'/,'restoring a draft defaults to direct pay');
assert.doesNotMatch(js,/d\.checkoutMode/,'saved pay-later preference cannot override the direct-pay default');
assert.match(migration,/private\.yt_work_owner\(\)/);
assert.match(migration,/grant execute on function public\.yt_pos_order_benefit_summaries\(uuid\[\]\) to authenticated/);
assert.match(migration,/from public\.yt_point_entries/);
assert.match(migration,/join public\.game_passes gp/);
console.log('PASS activity-specific POS actions, one processed-result summary action, member points details, Cashier/Owner RPC gate and pay-now default');
