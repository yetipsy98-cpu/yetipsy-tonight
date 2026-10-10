const assert=require('node:assert/strict'),fs=require('node:fs');
const tools=fs.readFileSync('play/shared/owner-tools.js','utf8');
const app=fs.readFileSync('play/app.js','utf8');
for(const stale of ['yt_loyalty_owner_tier','yt_loyalty_owner_save','loyaltyPointsEnabled','loyaltyTierEditor','随机积分档位'])assert(!tools.includes(stale),stale);
assert(tools.includes("db.rpc('yt_loyalty_owner_member_save'"));
assert(!fs.existsSync('play/shared/work.js'));
assert(app.includes("h.innerHTML='<strong>我的积分</strong><span>POINTS</span>'"));
assert(app.includes("invite.className='loyalty-referral'"));
for(const role of ['pos','owner','staff','cashier']){
 const html=fs.readFileSync(`play/${role}/index.html`,'utf8');
 for(const stale of ['OWNER · RANDOM POINTS','ops_loyaltyPointsEnabled','ops_loyaltyTierEditor','ops_addLoyaltyTier'])assert(!html.includes(stale),`${role}: ${stale}`);
 assert(html.includes('id="ownerPointsRoot"'));
 assert(html.includes('20261010-workbench-v15-1'));
}
console.log('PASS: retired random-points controls and dead entry file are gone; member campaigns use the focused RPC and points stay in the rewards surface.');
