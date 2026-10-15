const assert=require('node:assert/strict'),fs=require('node:fs');
const root=fs.readFileSync('play/pos/factory-reset.js','utf8');
const sql=fs.readFileSync('sql/050_repair_owner_reset_where_guards.sql','utf8');
const client=fs.readFileSync('play/pos/pos.js','utf8');
const fix=fs.readFileSync('sql/051_owner_reset_new_order_children.sql','utf8');
const playFix=fs.readFileSync('supabase/migrations/20261015123836_owner_reset_play_order_children.sql','utf8');
const authFix=fs.readFileSync('supabase/migrations/20261015124600_owner_reset_auth_cleanup_fk.sql','utf8');
const consoleSrc=fs.readFileSync('play/pos/console.js','utf8');
assert.match(client,/console\.js\?v=20261015-(?:approval-moved-v2|owner-dot-v2|member-bell-reorg-v1|owner-categories-v1)/);
assert.match(consoleSrc,/factory-reset\.js\?v=20261012-reset-fix-v23/);
assert.match(root,/reset_database_error/);
assert.match(root,/reset_confirmation_expired/);
assert.doesNotMatch(root,/未收到完成结果。请重试第二次确认/);
assert.match(sql,/update public\.yt_loyalty_config set welcome_enabled=false,referral_enabled=false,updated_at=now\(\) where true/);
assert.match(sql,/update public\.games set points_max=100,reaction_perfect_ms=200,reaction_zero_ms=1000 where true/);
assert.match(sql,/delete from public\.yt_point_shop_items where true/);
assert.match(sql,/update public\.yt_store_boxes b[\s\S]*?where b\.source_order_id=o\.id/);
assert.match(fix,/yt_lucky_day_reservations,public\.yt_moon_preorder_holds/,'new order-linked reservations are cleared before orders');
for(const table of ['yt_play_order_tokens','yt_play_consumption_bindings','yt_play_first_purchases','yt_play_referral_events']){
 assert.match(playFix,new RegExp(`public\\.${table}`),`${table} must be truncated with its order parent`);
}
assert.match(playFix,/public\.yt_referral_links restart identity/,'reset patch must fail closed when its expected v9 anchor changes');
for(const table of ['yt_play_member_tokens','yt_play_invite_tokens','yt_play_bell_requests']){
 assert.match(authFix,new RegExp(`public\\.${table}`),`${table} must be included in business-record reset`);
}
assert.match(authFix,/yt_play_member_tokens_customer_id_fkey[\s\S]*?on delete cascade/i);
assert.match(authFix,/yt_play_invite_tokens_inviter_customer_id_fkey[\s\S]*?on delete cascade/i);
assert.match(authFix,/yt_play_bell_requests_customer_id_fkey[\s\S]*?on delete cascade/i);
assert.match(authFix,/yt_play_bell_requests_acknowledged_by_fkey[\s\S]*?on delete set null/i);
assert.match(authFix,/public\.yt_play_referral_events restart identity/,'reset patch must fail closed when its expected v9 anchor changes');
assert.doesNotMatch(sql,/delete from public\.[a-z_]+;/i);
console.log('PASS: Reset SQL guards, second-confirmation errors, and Play order FK children.');
