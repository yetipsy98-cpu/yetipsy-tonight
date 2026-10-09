// Two real password verifications, followed by atomic business reset and resumable API cleanup.
// All authorization is supplied by the existing validated Owner session check.
export function createOwnerReset({admin,ownerFromRequest,rate,verify,sha,send}:any){
 const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
 async function context(req:Request){
  const account=await ownerFromRequest(req);
  const jwt=(req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,'');
  let claims:any;try{const part=jwt.split('.')[1].replace(/-/g,'+').replace(/_/g,'/');claims=JSON.parse(atob(part));}catch{throw Error('not_authenticated');}
  if(claims.sub!==account.auth_user_id||!uuid.test(claims.session_id||''))throw Error('not_authenticated');
  return {account,session:await sha(claims.session_id)};
 }
 async function checkPassword(account:any,value:unknown,stage:string){
  if(typeof value!=='string'||value.length<1||value.length>128)throw Error('invalid_credentials');
  const key='factory-reset:'+stage+':'+account.auth_user_id;
  if(!await rate(key))throw Error('too_many_attempts');
  const {data,error}=await verify(account.username,value,account.auth_user_id);
  if(error||!data?.session)throw Error('invalid_credentials');
  // Verification creates a temporary session; revoke only that session, preserving the Owner console.
  const {error:signoutError}=await admin.auth.admin.signOut(data.session.access_token,'local');
  if(signoutError)throw Error('reset_verification_failed');
  await rate(key,true);
 }
 async function rpc(account:any,session:string,action:string,body:any={}){
  const {data,error}=await admin.rpc('yt_owner_reset_v8',{p_actor:account.auth_user_id,p_session:session,p_action:action,
   p_challenge:body.challenge||null,p_request:body.request||null,p_done:body.done||[],p_scopes:action==='prepare'?body.scopes:null});
  if(error)throw Error(error.message||'reset_failed');return data;
 }
 return async function ownerReset(action:string,body:any,req:Request){
  const {account,session}=await context(req);
  if(action==='reset_status')return send({ok:true,...await rpc(account,session,'status')});
  if(action==='reset_prepare'){
   if(!uuid.test(body.request||''))throw Error('invalid_reset_request');
   if(!Array.isArray(body.scopes)||!body.scopes.length||body.scopes.length>6||body.scopes.some((x:any)=>!['records','members','catalog','campaigns','team','banners'].includes(x)))throw Error('invalid_reset_scope');
   await checkPassword(account,body.password,'first');
   return send({ok:true,...await rpc(account,session,'prepare',body)});
  }
  if(!uuid.test(body.challenge||''))throw Error('invalid_reset_request');
  if(action==='reset_confirm'){
   await checkPassword(account,body.password,'second');
   return send({ok:true,...await rpc(account,session,'commit',body)});
  }
  if(action!=='reset_finish')throw Error('invalid_reset_request');
  const job=await rpc(account,session,'batch',body);if(job.complete)return send({ok:true,challenge:job.challenge,complete:true,remaining:0,scopes:job.scopes});
  const done:number[]=[];const assets=job.batch.filter((x:any)=>x.kind==='asset');
  if(assets.length){
   const {error}=await admin.storage.from('yetipsy-home-banners').remove(assets.map((x:any)=>x.target));
   if(error)throw Error('reset_cleanup_failed');done.push(...assets.map((x:any)=>x.id));
  }
  const users=job.batch.filter((x:any)=>x.kind==='user');
  // Only immutable queued IDs can be removed. Never accept user IDs or paths from the browser.
  for(let i=0;i<users.length;i+=5){
   const outcomes=await Promise.all(users.slice(i,i+5).map(async (x:any)=>{
    if(x.target===account.auth_user_id)return {failed:true};
    const {error}=await admin.auth.admin.deleteUser(x.target);
    return !error||error.status===404?{id:x.id}:{failed:true};
   }));
   for(const item of outcomes)if(item.id!==undefined)done.push(item.id);
   if(outcomes.some((x:any)=>x.failed)){if(done.length)await rpc(account,session,'ack',{...body,done});throw Error('reset_cleanup_failed');}
  }
  const result=await rpc(account,session,'ack',{...body,done});
  return send({ok:true,challenge:result.challenge,complete:result.complete,remaining:result.remaining,scopes:result.scopes});
 };
}
