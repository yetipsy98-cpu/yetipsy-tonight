const assert=require('node:assert/strict');
const fs=require('node:fs');
const pos=fs.readFileSync('play/pos/pos.js','utf8');
const migration=fs.readFileSync('supabase/migrations/20261014120443_package_prep_intent.sql','utf8');
assert.match(pos,/if\(orderId&&\(isCashier\(\)\|\|isOwner\(\)\)\)await promptCashierPackagePrep\(orderId\);if\(checkoutMode==='pay_now'\)/,'Cashier / Owner choose prep before pay-now checkout; pay-later remains on ordering page');
assert.match(pos,/async function promptCashierPackagePrep\(orderId\)/,'order success asks whether to pre-pour eligible Package / Challenge cups');
assert.match(pos,/if\(action==='accept'&&\(isCashier\(\)\|\|isOwner\(\)\)\)await promptCashierPackagePrep\(orderId\)/,'Cashier acceptance prompts for Staff-created eligible orders');
assert.match(pos,/yt_store_box_prep_intent_save/,'prompt persists choices for pay-later orders');
assert.match(pos,/yt_store_box_prep_intent_get/,'later checkout restores saved choices');
assert.match(pos,/if\(item\.mode==='challenge'&&count!==1\)/,'Challenge always has exactly one pre-poured cup');
assert.match(pos,/未预出部分进入存酒箱/,'remaining Package volume stays in the Store Box');
assert.match(migration,/private\.yt_pos_work_cashier\(\)/,'only Owner, Cashier and cashier-authorized Staff can save/get these selections');
assert.match(migration,/challenge_one_cup_only/,'database enforces Challenge one-cup rule');
assert.match(migration,/store_box_component_unavailable/,'database checks chosen components against available units');
for(const page of ['play/admin/pos/index.html','play/admin/owner/index.html','play/admin/cashier/index.html','play/admin/staff/index.html']){

 assert.match(fs.readFileSync(page,'utf8'),/20261015-(?:owner-dot-v2|(?:order-approvals-v2|admin-pos-unified-v3|benefit-summary-(?:paynow|modal)-v1|checkout-direct-default-v2|package-kds-prep-v1)|play-v1)/,`${page} reloads the updated workbench module`);

}
console.log('PASS Package / Challenge prep prompt, persistent pay-later selection, checkout restoration and access validation');
