const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const sql = fs.readFileSync(require('node:path').join(__dirname, '../sql/074_lite_protection_observation.sql'), 'utf8');
test('Lite risk tables require RLS', () => {
  assert.ok(sql.includes('ALTER TABLE public.yt_lite_device_links ENABLE ROW LEVEL SECURITY'));
  assert.ok(sql.includes('ALTER TABLE public.yt_lite_risk_events ENABLE ROW LEVEL SECURITY'));
});
test('Owner summary checks owner authorization', () => {
  assert.ok(sql.includes('private.yt_work_owner()'));
  assert.ok(sql.includes('SECURITY INVOKER'));
});
test('Does not replace reward routines', () => {
  assert.ok(!sql.includes('CREATE OR REPLACE FUNCTION private.yt_award_promo('));
});
