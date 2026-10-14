const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const pos = read('play/pos/pos.js');
const staff = read('play/pos/ambassador.js');
const client = read('play/ambassador-client.js');
const sql = read('sql/085_ambassador_pos_sales.sql');
const checkout = read('sql/086_ambassador_freeflow_checkout.sql');
const dayClose = read('play/pos/day-close.js');

// Pass scan routes before the ordinary reward cart requirement.
const scan = pos.slice(pos.indexOf('async function scanDraftReward()'), pos.indexOf('async function', pos.indexOf('async function scanDraftReward()') + 15));
assert(scan.indexOf('isAmbassadorToken(raw)') >= 0);
assert(scan.indexOf('isAmbassadorToken(raw)') < scan.indexOf("if(!state.cart.size)throw Error('cart_requires_paid_drink')"));
assert.match(pos, /async function scanAmbassadorPass\(raw\)/);
assert.match(pos, /draftRedeemCheck'\)\.disabled=!!noScan/);
assert.match(pos, /draftRedeemScan'\)\.disabled=locked\|\|mutating/);
assert.match(pos, /ambassadorPassWarning/);
assert.match(pos, /Freeflow Male|Freeflow Female/);

// A Pass creates a normal fulfilled POS order with only Freeflow items; no KDS chit is issued.
assert.match(sql, /yt_ambassador_pos_order_create/);
assert.match(sql, /values\('future_pos','fulfilled',ono,'Freeflow'/);
assert.match(sql, /'Freeflow Male'/);
assert.match(sql, /'Freeflow Female'/);
assert.doesNotMatch(sql, /insert into public\.yt_pos_order_chits/i);
assert.match(pos, /productionRows\(\).*isAmbassadorOrder/);

// Payment receives AB-prefixed category and captures commission/check-in after payment.
assert.match(sql, /new\.payment_method:='AB_'\|\|case/);
assert.match(sql, /yt_ambassador_pos_capture/);
assert.match(sql, /insert into public\.yt_ambassador_checkins/);
assert.match(sql, /insert into public\.yt_ambassador_ledger/);
assert.match(checkout, /yt_ambassador_pos_sales where order_id=new\.id/);
assert.match(dayClose, /AB_DuitNow/);

// Keep the established controls: staff Pass issue window, no self redemption, no separate check-in UI.
assert.match(staff, /yt_ambassador_work_portal/);
assert.match(staff, /yt_ambassador_work_pass_save/);
assert.doesNotMatch(staff, /yt_ambassador_checkin/);
assert.match(client, /yt_ambassador_portal/);
assert.match(client, /classList\.toggle\('ready',data\.enabled===true\)/);
assert.match(client, /YTAMB:/);
assert.match(pos, /cannot_redeem_own_pass/);
console.log('Ambassador POS sales and empty-cart Pass scan invariants passed');
