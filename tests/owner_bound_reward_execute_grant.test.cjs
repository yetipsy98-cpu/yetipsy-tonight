const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const sql=fs.readFileSync(path.join(__dirname,'../supabase/migrations/20261016153332_owner_bound_reward_private_execute_grant_v1.sql'),'utf8');
assert.match(sql,/REVOKE ALL ON FUNCTION private\.yt_owner_update_bound_reward_v1\(uuid,jsonb,jsonb\) FROM PUBLIC,anon/i);
assert.match(sql,/GRANT EXECUTE ON FUNCTION private\.yt_owner_update_bound_reward_v1\(uuid,jsonb,jsonb\) TO authenticated/i);
assert.doesNotMatch(sql,/GRANT EXECUTE ON FUNCTION private\.yt_owner_update_bound_reward_v1\(uuid,jsonb,jsonb\) TO (PUBLIC|anon)/i);
console.log('PASS: bound reward update stays private to authenticated callers; Owner authorization remains in the RPC.');
