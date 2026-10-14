const assert=require('node:assert/strict'),fs=require('node:fs');
const pos=fs.readFileSync('play/pos/pos.js','utf8'),consoleSrc=fs.readFileSync('play/pos/console.js','utf8'),owner=fs.readFileSync('play/pos/payment-qr-settings.js','utf8'),sql=fs.readFileSync('sql/062_cashier_duitnow_qr.sql','utf8');
assert.match(pos,/if\(!\(isCashier\(\)\|\|isOwner\(\)\)\)throw Error\('cashier_only'\)/);
assert.match(pos,/if\(isCashier\(\)\)calls\.push\(db\.rpc\('yt_pos_orders',\{p_scope:'pending'/);
assert.match(pos,/scope==='pending'&&isCashier\(\)&&row\.status==='pending'/);
assert.match(pos,/action==='accept'&&sourceRow\?\.checkout_mode==='pay_now'&&isCashier\(\)/);
assert.match(pos,/cartCheckoutPayment'\)\.value='duitnow'/);
assert.match(pos,/yt_receipt_settings_get/);
assert.match(pos,/yetipsy-payment-qr/);
assert.match(pos,/getPublicUrl\(state\.duitnowQrPath\)/);
assert.match(consoleSrc,/dataset\.ownerTool='paymentqr'/);
assert.match(consoleSrc,/payment-qr-settings\.js\?v=20261013-cashier-qr-v1/);
assert.match(owner,/if\(!isOwner\(\)\)throw Error\('owner_only'\)/);
assert.match(owner,/\.from\(bucket\)\.upload/);
assert.match(owner,/yt_owner_payment_qr_save/);
for(const page of ['pos','owner','staff','cashier']){
 const html=fs.readFileSync('play/'+page+'/index.html','utf8');
 assert.match(html,/pos\.js\?v=20261014-ambassador-staffwallet-qr-v2/);
 assert.match(html,/value="duitnow" selected>DuitNow（默认）/);
 assert.match(html,/id="cashierDuitNowQr"/);
 assert.match(html,/id="cashierDuitNowQrImage"/);
}
assert.match(sql,/create policy yt_payment_qr_owner_insert/);
assert.match(sql,/private\.yt_banner_owner\(\)/);
assert.match(sql,/bucket_id='yetipsy-payment-qr'/);
assert.match(sql,/if not private\.yt_banner_owner\(\) then raise exception 'owner_only'/);
assert.match(sql,/grant execute on function private\.yt_owner_payment_qr_save\(text\),public\.yt_owner_payment_qr_save\(text\) to authenticated/);
console.log('PASS Cashier/Owner DuitNow checkout QR, pending approval pay-now, Owner upload, and Supabase access controls.');