const assert=require('node:assert/strict'),fs=require('node:fs');
const read=p=>fs.readFileSync(p,'utf8');
const code=read('sql/051_moon_guest_manual_codes.sql'),integration=read('sql/052_moon_guest_checkout_and_receipt.sql');
for(const n of ['yt_moon_owner_add','yt_moon_owner_list','yt_moon_lookup','yt_moon_reserve','yt_moon_release'])assert(code.includes(n),n);
for(const n of ['moon_duplicate_code','moon_already_redeemed','moon_reserved_elsewhere','minimum_one_paid_drink'])assert(code.includes(n),n);
assert.match(code,/unit_price_rm,is_drink_at_order\)[\s\S]*?VALUES\(p_order,drink/);
assert.match(code,/AFTER UPDATE OF payment_status,status/);
assert.match(integration,/NEW\.amount_rm:=OLD\.amount_rm-v_discount-v_moon/);
assert.match(integration,/moon_codes/);
assert.match(integration,/status='available',reserved_order_id=NULL/);
for(const page of ['pos','owner','cashier','staff']){
 const html=read('play/'+page+'/index.html');
 assert(!html.includes('moonGuestPanel')&&!html.includes('moonGuestDrink'),page+' must use shared redemption UI');
 assert(html.includes('draftRedeemToken'),page+' shared Moon code input missing');
 const ids=[...html.matchAll(/id="([^"]+)"/g)].map(x=>x[1]);
 assert.equal(ids.length,new Set(ids).size,page+' duplicate ids');
}
assert.match(read('play/pos/console.js'),/moon-code-editor\.js/);
assert.doesNotMatch(read('play/pos/pos.js'),/yt_moon_owner_bind_reward|yt_moon_owner_reward_bindings|mapMoonKind/);
assert.doesNotMatch(read('play/pos/moon-code-editor.js'),/moonKind|moon_owner_reward_bindings/);
assert.match(read('play/pos/moon-code-editor.js'),/p_reward:rewardId/);
assert.match(read('play/pos/moon-code-editor.js'),/yt_pos_owner_reward_rules/);
assert.match(read('play/pos/pos.js'),/yt_pos_preorder_scan_auto/);
assert.match(read('play/pos/pos.js'),/requires_product/);
assert.match(read('play/pos/pos.js'),/yt_moon_release/);
const unified=read('sql/064_moon_shared_reward_binding_auto_scan.sql'),moonRainbow=read('sql/065_moon_rainbow_existing_pos_binding.sql');
assert.match(unified,/private\.yt_moon_reward_name/);
assert.match(read('sql/069_moon_codes_use_existing_rewards.sql'),/ADD COLUMN IF NOT EXISTS reward_id/);
assert.match(read('sql/069_moon_codes_use_existing_rewards.sql'),/p_reward uuid/);
assert.match(read('sql/069_moon_codes_use_existing_rewards.sql'),/WHERE r.id=v.reward_id/);
assert.match(read('sql/070_moon_remove_legacy_bindings.sql'),/DROP TABLE IF EXISTS public\\.yt_moon_reward_bindings/);
assert.doesNotMatch(read('sql/070_moon_remove_legacy_bindings.sql'),/FROM public\\.yt_moon_reward_bindings/);

assert.match(unified,/public\.yt_pos_reward_rules/);
assert.match(unified,/yt_pos_preorder_scan_auto/);
assert.match(unified,/product_id/);
assert.match(moonRainbow,/RAINBOW SHOT X1/);
console.log('PASS Moon short-code auto-detection, shared reward binding, KDS and payment settlement contracts');
