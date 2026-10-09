const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');const {webcrypto}=require('node:crypto');
const root=path.resolve(__dirname,'..'),src=fs.readFileSync(path.join(root,'play/app.js'),'utf8');
const js=src.slice(src.indexOf('function tokenDetails('),src.indexOf('function stripLink('));
const store=new Map(),calls=[];let closed=0,fail=false,walletFail=false,succeeded=0;
const c={URL,sessionStorage:{getItem:k=>store.get(k),setItem:(k,v)=>store.set(k,v),removeItem:k=>store.delete(k)},uuid:()=>webcrypto.randomUUID(),state:{user:null},closeSheet:async()=>closed++,shell(){},changeAuthMode(){},$:()=>({textContent:''}),isStaff:()=>false,stripLink(){},unpack:r=>{if(r.error)throw Error(r.error.message);return r.data;},wallet:async()=>{if(walletFail)throw Error('wallet fetch lost');},refreshPasses:async()=>{if(walletFail)throw Error('passes fetch lost');},showSheet(){},sheetHtml(){},showSimpleSuccess:async()=>succeeded++,db:{rpc:async(name,args)=>{calls.push({name,args:structuredClone(args)});if(name==='yt_pos_bundle_claim')return {data:{count:2,idempotent:true}};if(fail)return {data:{error_code:'account_claim_limit'}};return {data:{awards:[{award_id:'award',reward_name:'RM5'}]}};}}};
vm.createContext(c);vm.runInContext(js+'\nglobalThis.test={tokenDetails,redeemScanValue,previewClaim};',c);
(async()=>{
 assert.equal(JSON.stringify(c.test.tokenDetails(' 7k3m-9x2p ')),JSON.stringify({kind:'gift_code',token:'7K3M9X2P'}));
 await c.test.redeemScanValue('7K3M-9X2P');assert.equal(closed,1);assert.equal(c.state.pendingClaim.kind,'gift_code');assert.equal(calls.length,0);
 c.state.user={id:'customer'};fail=true;await assert.rejects(c.test.redeemScanValue(c.state.pendingClaim.token,c.state.pendingClaim.kind),/account_claim_limit/);assert.equal(succeeded,0);const id=calls.at(-1).args.p_request;
 fail=false;walletFail=true;await assert.rejects(c.test.redeemScanValue('7k3m9x2p'),/wallet fetch lost/);assert.equal(calls.at(-1).args.p_request,id);
 walletFail=false;await c.test.redeemScanValue('7K3M-9X2P');assert.equal(calls.at(-1).args.p_request,id);assert.equal(calls.at(-1).name,'yt_claim_offer_code');assert.equal(succeeded,1);assert.equal(store.size,0);
 const token='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';c.state.user=null;await c.test.redeemScanValue('https://example.test/play/?bundle='+token);assert.equal(c.state.pendingClaim.kind,'bundle');c.state.user={id:'customer'};walletFail=true;await assert.rejects(c.test.redeemScanValue(token,'bundle'),/passes fetch lost/);walletFail=false;await c.test.redeemScanValue(token,'bundle');assert.equal(calls.at(-1).name,'yt_pos_bundle_claim');assert.equal(calls.at(-1).args.p_token,token);
 for(const page of ['index.html','pos/index.html','cashier/index.html']){const html=fs.readFileSync(path.join(root,'play',page),'utf8'),ids=[...html.matchAll(/id="([^"]+)"/g)].map(m=>m[1]);assert.equal(ids.length,new Set(ids).size);assert(ids.includes('ownerBannersPanel'));assert(html.includes('20261009-console-v8-2'));}
 assert(src.includes('const offer=unpack(await db.rpc(\'yt_create_offer_v5\''));
 const pos=fs.readFileSync(path.join(root,'play/pos/pos.js'),'utf8');assert(pos.includes("code.textContent=offer.display_code"));assert(!pos.includes('a.textContent=link.href'));
 console.log('PASS: normalized Reward Claim, login continuation, exact retry after errors and lost wallet response, both Owner entry points and consistent DOM/version markers.');
})().catch(e=>{console.error(e);process.exitCode=1;});
