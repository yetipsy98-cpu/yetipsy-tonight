const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const sql = fs.readFileSync(path.join(root, 'sql/080_ambassador_system.sql'), 'utf8')
  + fs.readFileSync(path.join(root, 'sql/081_ambassador_security_and_zero_commission_fix.sql'), 'utf8')
  + fs.readFileSync(path.join(root, 'sql/082_ambassador_payout_ambiguity_fix.sql'), 'utf8');
const pos = fs.readFileSync(path.join(root, 'play/pos/ambassador.js'), 'utf8');
const client = fs.readFileSync(path.join(root, 'play/ambassador-client.js'), 'utf8');
const posEntry = fs.readFileSync(path.join(root, 'play/pos/pos.js'), 'utf8');
const memberEntry = fs.readFileSync(path.join(root, 'play/app.js'), 'utf8');

for (const table of ['yt_ambassadors', 'yt_ambassador_prices', 'yt_ambassador_special_prices',
  'yt_ambassador_passes', 'yt_ambassador_checkins', 'yt_ambassador_ledger']) {
  assert.match(sql, new RegExp('alter table public\\.' + table + ' enable row level security'));
  assert.match(sql, new RegExp(table + '[\\s\\S]{0,900}from public,anon,authenticated'));
}
assert.match(sql, /grant execute on function public\.yt_ambassador_pass_lookup\(text\) to authenticated/);
assert.match(sql, /revoke all on function private\.yt_ambassador_price\(date\) from public,anon,authenticated/);
assert.match(sql, /wa\.role in \('staff','cashier'\)/);
assert.match(sql, /if a\.member_user_id=auth\.uid\(\) or a\.work_user_id=auth\.uid\(\) then raise exception 'cannot_redeem_own_pass'/);
assert.match(sql, /private\.yt_business_day\(now\(\)\)/);
assert.match(sql, /private\.yt_business_start\(v\.reservation_day\+1\)/);
assert.match(sql, /s:=round\(m\*mp\+f\*fp,2\); comm:=round\(s\*a\.commission_rate\/100,2\)/);
assert.match(sql, /over_planned',done>v\.planned_pax/);
assert.match(sql, /on conflict\(request_id\) do nothing/);
assert.match(sql, /if comm>0 then/);
assert.doesNotMatch(sql, /status\s*=\s*'closed'/i);

assert.match(pos, /yt_ambassador_work_access/);
assert.match(pos, /yt_ambassador_pass_lookup/);
assert.match(pos, /yt_ambassador_checkin/);
assert.doesNotMatch(pos, /yt_pos_order_submit|yt_pos_checkout|\.from\(/);
assert.match(pos, /不会创建订单或收款/);
assert.match(client, /yt_ambassador_portal/);
assert.match(client, /yt_ambassador_pass_save/);
assert.match(client, /classList\.toggle\('ready',data\.enabled===true\)/);
assert.match(client, /YTAMB:/);
assert.match(posEntry, /createAmbassadorTools/);
assert.match(memberEntry, /createAmbassadorClient/);
console.log('Ambassador system invariants passed');
