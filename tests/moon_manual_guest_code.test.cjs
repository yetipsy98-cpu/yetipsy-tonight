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
 for(const id of ['moonGuestPanel','moonGuestCheck','moonGuestCode','moonGuestDrink','moonGuestConfirm','moonGuestRows']){
  assert(html.includes('id="'+id+'"'),page+' missing '+id);
 }
 const ids=[...html.matchAll(/id="([^"]+)"/g)].map(x=>x[1]);
 assert.equal(ids.length,new Set(ids).size,page+' duplicate ids');
}
assert.match(read('play/pos/console.js'),/moon-code-editor\.js/);
assert.match(read('play/pos/pos.js'),/yt_moon_reserve/);
assert.match(read('play/pos/pos.js'),/yt_moon_lookup/);
assert.match(read('play/pos/pos.js'),/yt_moon_release/);
console.log('PASS Moon guest-code manual entry, no customer login, KDS and payment settlement contracts');
