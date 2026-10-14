const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const pos = read('play/pos/pos.js');
const staff = read('play/pos/ambassador.js');
const client = read('play/ambassador-client.js');
const sql = read('sql/085_ambassador_pos_sales.sql');
const followup = read('sql/088_ambassador_pos_cart_issue_7day.sql');
const checkout = read('sql/086_ambassador_freeflow_checkout.sql');
const ownerCancel = read('sql/090_ambassador_pass_owner_cancel.sql');
const cashierRedeem = read('sql/091_ambassador_cashier_self_redeem.sql');
const dayClose = read('play/pos/day-close.js');

// Pass scan works with an empty product cart; ordinary rewards retain the drink requirement.
const scan = pos.slice(pos.indexOf('async function scanDraftReward()'), pos.indexOf('function renderDraftChoices'));
assert(scan.indexOf('isAmbassadorToken(raw)') >= 0);
assert(scan.indexOf('isAmbassadorToken(raw)') < scan.indexOf("if(!state.cart.size)throw Error('cart_requires_paid_drink')"));
assert.match(pos, /async function scanAmbassadorPass\(raw\)/);
assert.match(pos, /Freeflow Pass 已加入购物车/);
assert.match(pos, /data-amb-inc/);
assert.match(pos, /state\.ambassadorDraft/);
assert.match(pos, /yt_ambassador_pos_order_create/);
assert.match(pos, /draftRedeemScan'\)\.disabled=locked\|\|mutating/);
assert.match(pos, /productionRows\(\).*isAmbassadorOrder/);

// Freeflow uses the POS basket and normal payment drawer, and remains out of KDS.
assert.match(pos, /showTab\('unpaid'\)/);
assert.match(pos, /openOrderCart\(data\.id\)/);
assert.match(sql, /values\('future_pos','fulfilled',ono,'Freeflow'/);
assert.match(sql, /'Freeflow Male'/);
assert.match(sql, /'Freeflow Female'/);
assert.doesNotMatch(sql, /insert into public\.yt_pos_order_chits/i);

// Payment receives AB-prefixed category and captures check-in/commission only after payment.
assert.match(sql, /new\.payment_method:='AB_'\|\|case/);
assert.match(sql, /yt_ambassador_pos_capture/);
assert.match(sql, /insert into public\.yt_ambassador_checkins/);
assert.match(sql, /insert into public\.yt_ambassador_ledger/);
assert.match(checkout, /yt_ambassador_pos_sales where order_id=new\.id/);
assert.match(dayClose, /AB_DuitNow/);

// Staff issue window is rendered; Cashier/Owner can issue at 0 commission and see today's Pass list.
assert.match(staff, /id="ytaWorkPassForm"/);
assert.match(staff, /yt_ambassador_pos_issue_portal/);
assert.match(staff, /yt_ambassador_pos_pass_save/);
assert.match(staff, /ytaTodayPasses/);
assert.match(staff, /ytaWalletSummary/);
assert.match(staff, /staffPortal\.wallet_balance/);
assert.match(staff, /sharePassCard\(x\)/);
assert.match(staff, /data-pass-share/);
assert.match(staff, /data-pass-redeem/);
assert.match(staff, /onRedeemPass\('YTAMB:'/);
assert.doesNotMatch(staff, /e\.currentTarget\.reset\(\)/);
assert.match(staff, /const form=e\.currentTarget/);
assert.match(staff, /7\*86400000/);
assert.doesNotMatch(staff, /yt_ambassador_checkin/);
assert.match(followup, /ambassador_id drop not null/);
assert.match(followup, /issued_by=auth\.uid\(\)/);
assert.match(followup, /rate:=coalesce\(a\.commission_rate,0\)/);
assert.match(followup, /yt_business_day\(now\(\)\)\+7/);
assert.match(followup, /today_passes/);
assert.match(client, /yt_ambassador_portal/);
assert.match(client, /classList\.toggle\('ready',data\.enabled===true\)/);
assert.match(client, /YTAMB:/);
assert.match(client, /data-pass-share/);
assert.match(client, /sharePassCard\(x\)/);
assert.match(client, /yta-pass-ticket/);
assert.match(ownerCancel, /yt_ambassador_owner_cancel_pass/);
assert.match(ownerCancel, /yt_ambassador_assert_owner/);
assert.match(ownerCancel, /pass_has_orders/);
assert.match(cashierRedeem, /not \(private\.yt_pos_work_cashier\(\) or private\.yt_has_role\('owner'\)\)/);
assert.match(staff, /yt_ambassador_owner_passes/);
assert.match(staff, /data-pass-cancel/);
assert.match(staff, /yt_ambassador_owner_cancel_pass/);
assert.match(pos, /cannot_redeem_own_pass/);
console.log('Ambassador POS/cart checkout, Staff commission wallet, QR template sharing, owner cancellation, and seven-day window invariants passed');
