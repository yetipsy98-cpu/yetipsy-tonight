const time=(v,fallback)=>{const t=Date.parse(v);return Number.isFinite(t)?t:fallback;};
export function rewardWindow(r){return {start:Math.max(time(r.redeem_after,0),time(r.rewards?.redeem_start_at,0)),end:Math.min(time(r.expires_at,0),time(r.rewards?.redeem_end_at,Infinity))};}
export function rewardAvailability(r,now=Date.now()){
 const {start,end}=rewardWindow(r);
 if(r.status==='redeemed')return {live:false,ready:false,label:'已使用'};
 if(r.status==='revoked')return {live:false,ready:false,label:'已作废'};
 if(end<=now)return {live:false,ready:false,label:'已过期'};
 if(r.status!=='available')return {live:false,ready:false,label:'处理中'};
 if(r.rewards?.active===false)return {live:true,ready:false,label:'暂停使用'};
 if(start>now)return {live:true,ready:false,label:'未到使用日期'};
 const from=r.rewards?.daily_start_local,to=r.rewards?.daily_end_local;
 if(from&&to){const local=new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Kuala_Lumpur',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false}).format(new Date(now));const allowed=from<=to?local>=from&&local<to:local>=from||local<to;if(!allowed)return {live:true,ready:false,label:'时段未到'};}
 return {live:true,ready:true,label:'可使用'};
}
export function buildRewardStacks(wallet,now=Date.now()){
 const live=new Map(),history=new Map();
 for(const award of wallet){const status=rewardAvailability(award,now),map=status.live?live:history,key=award.reward_id||award.id;let stack=map.get(key);if(!stack){stack={key,items:[],ready:[],next:null};map.set(key,stack);}stack.items.push(award);if(status.ready)stack.ready.push(award);}
 const byExpiry=(a,b)=>rewardWindow(a).end-rewardWindow(b).end||time(a.created_at,0)-time(b.created_at,0)||String(a.id).localeCompare(String(b.id));
 for(const stack of [...live.values(),...history.values()]){stack.ready.sort(byExpiry);stack.items.sort((a,b)=>Number(rewardAvailability(b,now).ready)-Number(rewardAvailability(a,now).ready)||byExpiry(a,b));stack.next=stack.ready[0]||stack.items[0];}
 return {live:[...live.values()].sort((a,b)=>Number(!!b.ready.length)-Number(!!a.ready.length)||byExpiry(a.next,b.next)),history:[...history.values()].sort((a,b)=>time(b.next.created_at,0)-time(a.next.created_at,0))};
}
