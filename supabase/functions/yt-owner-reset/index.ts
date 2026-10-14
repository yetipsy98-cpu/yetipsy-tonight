
import {createClient} from 'npm:@supabase/supabase-js@2.117.2';
const URL=Deno.env.get('SUPABASE_URL')||'';
const SERVICE=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')||'';
const PUBLIC=Deno.env.get('SUPABASE_ANON_KEY')||'';
const admin=createClient(URL,SERVICE,{auth:{autoRefreshToken:false,persistSession:false,detectSessionInUrl:false}});
const publicClient=()=>createClient(URL,PUBLIC,{auth:{autoRefreshToken:false,persistSession:false,detectSessionInUrl:false}});
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const scopesAllowed=['records','members','catalog','campaigns','team','banners','storebox'];
const origin='https://yetipsy98-cpu.github.io';
const headers={'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'content-type,apikey,authorization,x-client-info','Content-Type':'application/json','Cache-Control':'no-store'};
const reply=(data:any,status=200)=>new Response(JSON.stringify(data),{status,headers});
const sha=async(v:string)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(v))),x=>x.toString(16).padStart(2,'0')).join('');
function fail(s:string):never{throw Error(s);}
async function owner(req:Request){
 const jwt=(req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,'');
 if(!jwt)fail('not_authenticated');
 const {data:{user},error}=await admin.auth.getUser(jwt);
 if(error||!user)fail('not_authenticated');
 const {data:account,error:accountError}=await admin.from('work_accounts').select('auth_user_id,username,role,active,must_change_password').eq('auth_user_id',user.id).maybeSingle();
 if(accountError||!account||account.role!=='owner'||!account.active||account.must_change_password)fail('owner_only');
 const {data:role,error:roleError}=await admin.from('staff_roles').select('role,active').eq('user_id',user.id).maybeSingle();
 if(roleError||role?.role!=='owner'||!role.active)fail('owner_only');
 let claims:any;try{claims=JSON.parse(atob(jwt.split('.')[1].replace(/-/g,'+').replace(/_/g,'/')));}catch{fail('not_authenticated');}
 if(claims.sub!==user.id||!uuid.test(claims.session_id||''))fail('not_authenticated');
 return {account,session:await sha(claims.session_id)};
}
async function checkPassword(account:any,value:any){
 if(typeof value!=='string'||value.length<1||value.length>128)fail('invalid_credentials');
 const {data:accountInfo,error:accountError}=await admin.auth.admin.getUserById(account.auth_user_id);
 if(accountError||!accountInfo?.user?.email)fail('account_unavailable');
 const {data:pepper,error:pepperError}=await admin.rpc('yt_pin_secret_value');
 if(pepperError||typeof pepper!=='string'||pepper.length<32)fail('work_configuration_error');
 const secret=await crypto.subtle.importKey('raw',new TextEncoder().encode(pepper),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 const signature=await crypto.subtle.sign('HMAC',secret,new TextEncoder().encode('yetipsy:work:v1:'+account.username+':'+value));
 const secretPassword='YT-WORK-'+Array.from(new Uint8Array(signature),x=>x.toString(16).padStart(2,'0')).join('');
 const {data:login,error:loginError}=await publicClient().auth.signInWithPassword({email:accountInfo.user.email,password:secretPassword});
 if(loginError||!login.session)fail('invalid_credentials');
 const {error:revokeError}=await admin.auth.admin.signOut(login.session.access_token,'local');
 if(revokeError)fail('reset_verification_failed');
}
async function resetRpc(account:any,session:string,action:string,body:any={}){
 const {data,error}=await admin.rpc('yt_owner_reset_v9',{p_actor:account.auth_user_id,p_session:session,p_action:action,p_challenge:body.challenge||null,p_request:body.request||null,p_done:body.done||[],p_scopes:action==='prepare'?body.scopes:null});
 if(error)fail(error.message||'reset_database_error');
 return data;
}
async function finish(account:any,session:string,body:any){
 const job=await resetRpc(account,session,'batch',body);
 if(job.complete)return {challenge:job.challenge,complete:true,remaining:0,scopes:job.scopes};
 const done:number[]=[];
 const assets=job.batch.filter((x:any)=>x.kind==='asset');
 if(assets.length){
  const {error}=await admin.storage.from('yetipsy-home-banners').remove(assets.map((x:any)=>x.target));
  if(error)fail('reset_cleanup_failed');done.push(...assets.map((x:any)=>x.id));
 }
 const users=job.batch.filter((x:any)=>x.kind==='user');
 for(let i=0;i<users.length;i+=5){
  const results=await Promise.all(users.slice(i,i+5).map(async (x:any)=>{
   if(x.target===account.auth_user_id)return {failed:true};
   const {error}=await admin.auth.admin.deleteUser(x.target);
   return !error||error.status===404?{id:x.id}:{failed:true};
  }));
  for(const result of results)if(result.id!==undefined)done.push(result.id);
  if(results.some((x:any)=>x.failed)){
   if(done.length)await resetRpc(account,session,'ack',{...body,done});
   fail('reset_cleanup_failed');
  }
 }
 const result=await resetRpc(account,session,'ack',{...body,done});
 return {challenge:result.challenge,complete:result.complete,remaining:result.remaining,scopes:result.scopes};
}
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return reply({ok:false,error:'method_not_allowed'},405);
 try{
  const body=await req.json(),action=String(body.action||'');
  if(!['reset_prepare','reset_confirm','reset_finish','reset_status'].includes(action))fail('unknown_action');
  const {account,session}=await owner(req);
  if(action==='reset_status')return reply({ok:true,...await resetRpc(account,session,'status')});
  if(action==='reset_prepare'){
   if(!uuid.test(body.request||''))fail('invalid_reset_request');
   if(!Array.isArray(body.scopes)||body.scopes.length<1||body.scopes.length>7||body.scopes.some((s:any)=>!scopesAllowed.includes(s)))fail('invalid_reset_scope');
   await checkPassword(account,body.password);
   return reply({ok:true,...await resetRpc(account,session,'prepare',body)});
  }
  if(!uuid.test(body.challenge||''))fail('invalid_reset_request');
  if(action==='reset_confirm'){
   await checkPassword(account,body.password);
   return reply({ok:true,...await resetRpc(account,session,'commit',body)});
  }
  return reply({ok:true,...await finish(account,session,body)});
 }catch(error){
  const message=error instanceof Error?error.message:'server_unavailable';
  const known:Record<string,number>={not_authenticated:401,owner_only:403,invalid_credentials:401,invalid_reset_scope:400,invalid_reset_request:400,invalid_reset_scope_blocked:409,storebox_member_reset_blocked:409,reset_confirmation_expired:409,reset_cleanup_pending:409,reset_scope_conflict:409,reset_cleanup_failed:503,reset_verification_failed:503,reset_not_committed:409};
  if(message in known)return reply({ok:false,error:message},known[message]);
  console.error('yt-owner-reset failure:',message);
  return reply({ok:false,error:'reset_database_error'},503);
 }
});
