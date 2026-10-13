const assert=require('node:assert/strict'),fs=require('node:fs');
const source=fs.readFileSync('play/pos/pos.js','utf8');
const db=fs.readFileSync('sql/060_unified_moon_preorder_submit.sql','utf8');
for(const page of ['pos','owner','staff','cashier']){
 const html=fs.readFileSync('play/'+page+'/index.html','utf8');
 for(const id of ['categoryProductButtons','draftRedeemToken','cashierPackagePrep','cashierPackagePrepItems'])assert(html.includes('id="'+id+'"'),page+' missing '+id);
 assert(html.includes('20261013-unified-pos-v1'),'stale cache '+page);
}
assert(source.includes('renderCategoryButtons();'),'category chips should render');
assert(source.includes("yt_moon_preorder_scan"),'Moon uses single preorder field');
assert(source.includes("yt_moon_preorder_summary"),'Moon subtotal merged');
assert(source.includes("yt_moon_preorder_release"),'Moon release');
assert(source.includes("yt_pos_checkout_with_prep"),'Cashier preps at checkout');
assert(source.includes("if(item.mode==='challenge'&&count!==1)"),'Challenge client validation');
assert(source.includes("p_preps:cashierPackageSelections()"),'Cashier KDS preps sent atomically');
assert(db.includes('private.yt_moon_preorder_attach'),'Moon holds attached before payment');
assert(db.includes("if not coalesce((data->>'idempotent')::boolean,false)"),'avoid re-attaching retries');
assert(db.includes('private.yt_moon_preorder_summary'),'Moon pre-order minimum spend');
console.log('PASS category strip, unified Moon pre-order and Cashier package/Challenge checkout');
