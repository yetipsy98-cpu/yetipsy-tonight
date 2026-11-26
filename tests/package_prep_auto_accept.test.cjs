const assert=require('node:assert/strict'),fs=require('node:fs');
const migration=fs.readFileSync('supabase/migrations/20261016100650_pos_package_prep_auto_accept_kds.sql','utf8');
const pos=fs.readFileSync('play/pos/pos.js','utf8');
const save=pos.slice(pos.indexOf('async function promptCashierPackagePrep'),pos.indexOf('async function loadCashierPackagePrep'));
assert.match(migration,/if o\.status='pending' then[\s\S]*?set status='confirmed',accepted_by=actor,accepted_at=clock_timestamp\(\)/);
assert.match(migration,/yt_pos_order_chits/);
assert.match(migration,/values\(p_order,actor,'accepted','cashier'/);
assert.match(migration,/order_status',v_order_status/);
assert.match(save,/yt_store_box_prep_intent_save/);
assert.match(save,/await refreshOrders\(false\)/);
assert.match(save,/无需接单，订单已进入 KDS 待出品/);
assert.match(save,/cashierPackagePrepPlan\(quote.items,root\)/);
const vm=require('node:vm'),ctx={};vm.createContext(ctx);vm.runInContext(pos.slice(pos.indexOf('function cashierPackagePrepPlan('),pos.indexOf('async function promptCashierPackagePrep(')),ctx);
const item={item_id:'challenge',mode:'challenge',capacity:3},input={dataset:{prepItem:'challenge',prepKey:'cup'},value:'1',max:'3'},root={querySelectorAll:()=>[input]};
assert.equal(ctx.cashierPackagePrepPlan([item],root)[0].selections[0].quantity,1);
for(const quantity of ['0','2']){input.value=quantity;assert.throws(()=>ctx.cashierPackagePrepPlan([item],root),/challenge_one_cup_only/);}
input.value='4';assert.throws(()=>ctx.cashierPackagePrepPlan([item],root),/Package 出杯数量不正确/);
console.log('Cashier Package / Challenge pre-serve auto-accepts and loads into KDS');
