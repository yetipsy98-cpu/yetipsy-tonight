const assert=require('node:assert/strict'),fs=require('fs'),vm=require('vm');
(async()=>{
 const {requireAmbassadorSession}=await import('../play/pos/ambassador.js');let refreshed=0;const live={access_token:'test-token',user:{id:'employee'},expires_at:Date.now()/1000+300};
 await assert.rejects(()=>requireAmbassadorSession({auth:{getSession:async()=>({data:{session:null}})}}),/工作登录已失效/);
 await assert.rejects(()=>requireAmbassadorSession({auth:{getSession:async()=>({error:Error('expired')})}}),/工作登录已失效/);
 assert.equal(await requireAmbassadorSession({auth:{getSession:async()=>({data:{session:live}})}}),live);
 assert.equal(await requireAmbassadorSession({auth:{getSession:async()=>({data:{session:{...live,expires_at:1}}}),refreshSession:async()=>{refreshed++;return {data:{session:live}};}}}),live);assert.equal(refreshed,1);
 await assert.rejects(()=>requireAmbassadorSession({auth:{getSession:async()=>({data:{session:{...live,expires_at:1}}}),refreshSession:async()=>({error:Error('refresh expired')})}}),/工作登录已失效/);
 const src=fs.readFileSync('play/pos/ambassador.js','utf8');let saves=0,resets=0,session=live,rpcError=null;const form={reset(){resets++;}},button={disabled:false},c={FormData:class{get(k){return {reservation_day:'2026-11-14',planned_pax:'2',pass_type:'group',guest_name:'客人'}[k]||'';}},requireAmbassadorSession,workSessionMessage:'工作登录已失效，请重新登录工作账号后再生成 Pass；填写内容已保留。',db:{auth:{getSession:async()=>({data:{session}})},rpc:async()=>{saves++;return {error:rpcError,data:{id:null}};}},staffPortal:{mode:'pos_direct'},openWorkPass:null,loadWorkPortal:async()=>{},say(){}};
 vm.createContext(c);vm.runInContext(src.slice(src.indexOf(' async function saveWorkPass('),src.indexOf(' async function qrLib(')),c);const event={preventDefault(){},currentTarget:form,submitter:button};
 session=null;await assert.rejects(()=>c.saveWorkPass(event),/填写内容已保留/);assert.equal(saves,0);assert.equal(resets,0);assert.equal(button.disabled,false);
 session=live;rpcError={code:'42501',message:'permission denied for function yt_ambassador_pos_pass_save'};await assert.rejects(()=>c.saveWorkPass(event),/重新登录工作账号/);assert.equal(saves,1,'a rejected save is not automatically replayed');assert.equal(resets,0);assert.equal(button.disabled,false);
 rpcError=null;await c.saveWorkPass(event);assert.equal(saves,2);assert.equal(resets,1);assert.equal(button.disabled,false);console.log('PASS work-session preflight, expired-token refresh, no unauthenticated save, preserved form and no automatic replay of pass issuance.');
})().catch(e=>{console.error(e);process.exit(1);});
