const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const read=p=>fs.readFileSync(path.join(__dirname,'..',p),'utf8');

test('Work and member authentication do not impose attempt lockouts',()=>{
 const work=read('supabase/functions/yt-work-auth/index.ts');
 const reset=read('supabase/functions/yt-work-auth/owner-reset.ts');
 const ownerReset=read('supabase/functions/yt-owner-reset/index.ts');
 const pin=read('supabase/functions/yt-pin-auth/index.ts');
 assert.doesNotMatch(work,/yt_work_gate|too_many_attempts/);
 assert.doesNotMatch(reset,/rate\\(|too_many_attempts/);
 assert.doesNotMatch(ownerReset,/yt_work_gate|too_many_attempts/);
 assert.doesNotMatch(pin,/yt_pin_gate|yt_pin_lookup_gate|too_many_attempts/);
});

test('Login lockout warning is removed while redemption short-code protection remains',()=>{
 const pos=read('play/pos/pos.js');
 const app=read('play/app.js');
 const reset=read('play/pos/factory-reset.js');
 const ownerTools=read('play/shared/owner-tools.js');
 assert.doesNotMatch(pos,/错误尝试太多，请稍后再试/);
 assert.doesNotMatch(app,/尝试次数过多，请 15 分钟后再试/);
 assert.doesNotMatch(reset,/too_many_attempts|重试次数过多/);
 assert.doesNotMatch(ownerTools,/too_many_attempts|错误次数过多/);
 assert.match(app,/claim_code_rate_limited/);
});
