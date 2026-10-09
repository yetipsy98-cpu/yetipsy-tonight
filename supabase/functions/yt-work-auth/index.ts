import {createOwnerReset} from './owner-reset.ts';
import { createClient } from 'npm:@supabase/supabase-js@2.117.2';

const URL=Deno.env.get('SUPABASE_URL')||'';
const SERVICE=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')||'';
const PUBLIC=Deno.env.get('SUPABASE_ANON_KEY')||'';
const ORIGIN='https://yetipsy98-cpu.github.io';
const admin=createClient(URL,SERVICE,{auth:{autoRefreshToken:false,persistSession:false,detectSessionInUrl:false}});
let pepperCache:string|null=null;
function headers(){return {'Access-Control-Allow-Origin':ORIGIN,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'content-type,apikey,authorization,x-client-info','Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','Access-Control-Max-Age':'86400'};}
function send(data:unknown,status=200){return new Response(JSON.stringify(data),{status,headers:headers()});}
function err(code:string,status=400){return send({ok:false,error:code},status);}
const now=()=>new Date().toISOString();
function username(value:unknown):string{
 const v=String(value||'').trim().toLowerCase();
 if(!/^[a-z][a-z0-9_]{2,23}$/.test(v))throw Error('invalid_username');
 return v;
}
function strong(password:unknown,user=''):string{
 const p=String(password||'');
 if(p.length<12||p.length>128||!/[A-Z]/.test(p)||!/[a-z]/.test(p)||!/\d/.test(p)||p.toLowerCase().includes(user.toLowerCase()))throw Error('weak_password');
 return p;
}
async function sha(s:string):Promise<string>{
 const d=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s));
 return Array.from(new Uint8Array(d),x=>x.toString(16).padStart(2,'0')).join('');
}
async function password(user:string,plain:string):Promise<string>{
 if(!pepperCache){
  const {data,error}=await admin.rpc('yt_pin_secret_value');
  if(error||typeof data!=='string'||data.length<32)throw Error('work_configuration_error');
  pepperCache=data;
 }
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(pepperCache),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 const d=await crypto.subtle.sign('HMAC',key,new TextEncoder().encode('yetipsy:work:v1:'+user+':'+plain));
 return 'YT-WORK-'+Array.from(new Uint8Array(d),x=>x.toString(16).padStart(2,'0')).join('');
}
async function rate(key:string,reset=false):Promise<boolean>{
 const {data,error}=await admin.rpc('yt_work_gate',{p_key:await sha(key),p_reset:reset});
 if(error)throw Error('work_configuration_error');
 return data===true;
}
function publicClient(){return createClient(URL,PUBLIC,{auth:{autoRefreshToken:false,persistSession:false,detectSessionInUrl:false}});}
async function verify(username:string,plain:string,id:string){
 const {data:userInfo,error:userError}=await admin.auth.admin.getUserById(id);
 if(userError||!userInfo.user?.email)throw Error('account_unavailable');
 return publicClient().auth.signInWithPassword({email:userInfo.user.email,password:await password(username,plain)});
}
async function accountFromRequest(req:Request){
 const token=(req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,'');
 if(!token)throw Error('not_authenticated');
 const {data:{user},error}=await admin.auth.getUser(token);
 if(error||!user)throw Error('not_authenticated');
 const {data:acct,error:aerr}=await admin.from('work_accounts').select('auth_user_id,username,role,active,must_change_password').eq('auth_user_id',user.id).maybeSingle();
 if(aerr||!acct||!acct.active)throw Error('not_authenticated');
 return acct;
}
async function ownerFromRequest(req:Request){
 const acct=await accountFromRequest(req);
 if(acct.role!=='owner'||acct.must_change_password)throw Error('owner_only');
 const {data:role,error}=await admin.from('staff_roles').select('role,active').eq('user_id',acct.auth_user_id).maybeSingle();
 if(error||role?.role!=='owner'||!role.active)throw Error('owner_only');
 return acct;
}
async function audit(actor:string,action:string,id:string,metadata:Record<string,unknown>={}){
 const {error}=await admin.from('audit_logs').insert({actor_id:actor,action,entity_type:'work_account',entity_id:id,metadata});
 if(error)console.error('audit_failed',action,error.code);
}
async function createAuthUser(u:string,pass:string){
 const email=crypto.randomUUID().replaceAll('-','')+'@work.yetipsy.app';
 const {data,error}=await admin.auth.admin.createUser({email,password:await password(u,pass),email_confirm:true});
 if(error||!data.user?.id)throw Error('account_creation_failed');
 return data.user.id;
}
async function activate(body:any,req:Request){
 if(String(body.username||'')!=='owner'||String(body.password||'')!=='owner')return err('invalid_setup',403);
 const code=String(body.setup_code||'');
 if(!/^[a-zA-Z0-9_-]{40,80}$/.test(code))return err('invalid_setup',403);
 const newPassword=strong(body.new_password,'owner');
 const client=(req.headers.get('cf-connecting-ip')||req.headers.get('x-real-ip')||'activation');
 if(!await rate('setup:'+client))return err('too_many_attempts',429);
 const tokenHash=await sha(code);
 const {data:reserved,error:reserveError}=await admin.from('work_setup')
 .update({consumed_at:now()}).eq('id',true).eq('token_hash',tokenHash)
 .is('consumed_at',null).gt('expires_at',now()).select('id').maybeSingle();
 if(reserveError)throw Error('work_configuration_error');
 if(!reserved)return err('invalid_setup_or_already_used',403);
 let uid:string|null=null;
 try{
  const {data:already,error:checkError}=await admin.from('work_accounts').select('auth_user_id').eq('role','owner').maybeSingle();
  if(checkError||already)throw Error('owner_already_exists');
  uid=await createAuthUser('owner',newPassword);
  const {error:insertErr}=await admin.from('work_accounts').insert({auth_user_id:uid,username:'owner',role:'owner',active:true,must_change_password:false});
  if(insertErr)throw Error('account_creation_failed');
  const {error:roleErr}=await admin.from('staff_roles').upsert({user_id:uid,role:'owner',active:true});
  if(roleErr)throw Error('account_creation_failed');
  await admin.from('staff_roles').update({active:false}).eq('role','owner').neq('user_id',uid);
  await audit(uid,'work.owner_activated',uid);
  await rate('setup:'+client,true);
  return send({ok:true,username:'owner',message:'Owner 已激活。请使用新密码登录。'});
 }catch(e){
  if(uid){const {error:deleteErr}=await admin.auth.admin.deleteUser(uid);if(deleteErr)console.error('cleanup_failed',deleteErr.message);}
  // Recover unused setup code if database/auth activation could not complete.
  await admin.from('work_setup').update({consumed_at:null}).eq('id',true).eq('token_hash',tokenHash);
  throw e;
 }
}
async function login(body:any,req:Request){
 const u=username(body.username);
 const plain=String(body.password||'');
 if(plain.length<1||plain.length>128)return err('invalid_credentials',401);
 const ip=req.headers.get('cf-connecting-ip')||req.headers.get('x-real-ip')||'';
 if(!await rate('username:'+u)|| (ip&&!await rate('ip:'+ip)))return err('too_many_attempts',429);
 const {data:acct,error:ae}=await admin.from('work_accounts')
 .select('auth_user_id,username,role,active,must_change_password').eq('username',u).maybeSingle();
 if(ae)throw Error('work_configuration_error');
 if(!acct||!acct.active)return err('invalid_credentials',401);
 const {data:auth,error:signError}=await verify(u,plain,acct.auth_user_id);
 if(signError||!auth.session)return err('invalid_credentials',401);
 await rate('username:'+u,true);
 return send({ok:true,access_token:auth.session.access_token,refresh_token:auth.session.refresh_token,expires_in:auth.session.expires_in,username:u,role:acct.role,must_change_password:acct.must_change_password});
}
async function updatePassword(body:any,req:Request){
 const acct=await accountFromRequest(req);
 const prev=String(body.old_password||'');
 if(!await rate('username:'+acct.username))return err('too_many_attempts',429);
 const {data:check,error:ve}=await verify(acct.username,prev,acct.auth_user_id);
 if(ve||!check.session)return err('invalid_credentials',401);
 const replacement=strong(body.new_password,acct.username);
 if(prev===replacement)return err('password_reused');
 const {error:updated}=await admin.auth.admin.updateUserById(acct.auth_user_id,{password:await password(acct.username,replacement)});
 if(updated)throw Error('password_update_failed');
 const {error:stateErr}=await admin.from('work_accounts').update({must_change_password:false,updated_at:now()}).eq('auth_user_id',acct.auth_user_id);
 if(stateErr)throw Error('password_update_failed');
 if(acct.role==='staff'||acct.role==='cashier'){
  const {error:roleErr}=await admin.from('staff_roles').update({active:true}).eq('user_id',acct.auth_user_id).eq('role',acct.role);
  if(roleErr)throw Error('password_update_failed');
 }
 await rate('username:'+acct.username,true);
 await audit(acct.auth_user_id,'work.password_changed',acct.auth_user_id);
 return send({ok:true,message:'密码修改成功。请重新登录。'});
}
async function createStaff(body:any,req:Request){
 const owner=await ownerFromRequest(req);
 const u=username(body.username);
 if(u==='owner')return err('invalid_username');
 const temporary=strong(body.temporary_password,u);
 const {data:exists,error:ee}=await admin.from('work_accounts').select('auth_user_id').eq('username',u).maybeSingle();
 if(ee)throw Error('work_configuration_error');
 if(exists)return err('username_taken',409);
 let uid:string|null=null;
 try{
  uid=await createAuthUser(u,temporary);
  const {error:newErr}=await admin.from('work_accounts').insert({
    auth_user_id:uid,username:u,role:'staff',active:true,
    must_change_password:true,created_by:owner.auth_user_id
  });
  if(newErr)throw Error(newErr.code==='23505'?'username_taken':'staff_creation_failed');
  const {error:roleErr}=await admin.from('staff_roles').insert({user_id:uid,role:'staff',active:false});
  if(roleErr)throw Error('staff_creation_failed');
  await audit(owner.auth_user_id,'work.staff_created',uid,{username:u});
  return send({ok:true,username:u,user_id:uid,requires_password_change:true});
 }catch(e){
  if(uid)await admin.auth.admin.deleteUser(uid);
  throw e;
 }
}
async function listStaff(req:Request){
 await ownerFromRequest(req);
 const {data,error}=await admin.from('work_accounts')
 .select('auth_user_id,username,active,must_change_password,created_at,updated_at')
 .eq('role','staff').order('created_at',{ascending:false}).limit(200);
 if(error)throw Error('work_configuration_error');
 return send({ok:true,staff:data||[]});
}
async function changeStaff(body:any,req:Request,mode:'staff_toggle'|'staff_reset'){
 const owner=await ownerFromRequest(req);
 const u=username(body.username);
 const {data:staff,error}=await admin.from('work_accounts').select('auth_user_id,username,role,active,must_change_password').eq('username',u).maybeSingle();
 if(error||!staff||staff.role!=='staff')return err('staff_not_found',404);
 if(mode==='staff_toggle'){
  if(typeof body.active!=='boolean')return err('invalid_request');
  const enabled=body.active;
  const {error:upErr}=await admin.from('work_accounts').update({active:enabled,updated_at:now()}).eq('auth_user_id',staff.auth_user_id);
  if(upErr)throw Error('work_configuration_error');
  const {error:roleErr}=await admin.from('staff_roles').update({active:enabled&&!staff.must_change_password}).eq('user_id',staff.auth_user_id).eq('role','staff');
  if(roleErr)throw Error('work_configuration_error');
  await audit(owner.auth_user_id,enabled?'work.staff_enabled':'work.staff_disabled',staff.auth_user_id);
  return send({ok:true});
 }
 const temp=strong(body.temporary_password,u);
 const {error:pwErr}=await admin.auth.admin.updateUserById(staff.auth_user_id,{password:await password(u,temp)});
 if(pwErr)throw Error('password_update_failed');
 const {error:resetErr}=await admin.from('work_accounts').update({must_change_password:true,updated_at:now()}).eq('auth_user_id',staff.auth_user_id);
 if(resetErr)throw Error('password_update_failed');
 const {error:roleErr}=await admin.from('staff_roles').update({active:false}).eq('user_id',staff.auth_user_id).eq('role','staff');
 if(roleErr)throw Error('password_update_failed');
 await audit(owner.auth_user_id,'work.staff_password_reset',staff.auth_user_id);
 return send({ok:true,requires_password_change:true});
}

async function createCashier(body:any,req:Request){
  const owner=await ownerFromRequest(req);
  const u=username(body.username);
  if(u==='owner')return err('invalid_username');
  const temporary=strong(body.temporary_password,u);
  const {data:exists,error:ee}=await admin.from('work_accounts').select('auth_user_id').eq('username',u).maybeSingle();
  if(ee)throw Error('work_configuration_error');
  if(exists)return err('username_taken',409);
  let uid:string|null=null;
  try{
    uid=await createAuthUser(u,temporary);
    const {error:newErr}=await admin.from('work_accounts').insert({
      auth_user_id:uid,username:u,role:'cashier',active:true,
      can_cashier:true,can_edit_orders:true,must_change_password:true,
      created_by:owner.auth_user_id
    });
    if(newErr)throw Error(newErr.code==='23505'?'username_taken':'cashier_creation_failed');
    const {error:roleErr}=await admin.from('staff_roles').insert({user_id:uid,role:'cashier',active:false});
    if(roleErr)throw Error('cashier_creation_failed');
    await audit(owner.auth_user_id,'work.cashier_created',uid,{username:u});
    return send({ok:true,username:u,user_id:uid,requires_password_change:true});
  }catch(e){
    if(uid)await admin.auth.admin.deleteUser(uid);
    throw e;
  }
}
async function listCashier(req:Request){
  await ownerFromRequest(req);
  const {data,error}=await admin.from('work_accounts').select(
    'auth_user_id,username,active,must_change_password,created_at'
  ).eq('role','cashier').order('created_at',{ascending:false}).limit(100);
  if(error)throw Error('work_configuration_error');
  return send({ok:true,cashiers:data||[]});
}
async function manageCashier(body:any,req:Request,mode:'cashier_toggle'|'cashier_reset'){
  const owner=await ownerFromRequest(req);
  const u=username(body.username);
  const {data:acct,error}=await admin.from('work_accounts')
    .select('auth_user_id,username,role,active,must_change_password')
    .eq('username',u).maybeSingle();
  if(error||!acct||acct.role!=='cashier')return err('cashier_not_found',404);
  if(mode==='cashier_toggle'){
    if(typeof body.active!=='boolean')return err('invalid_request');
    const enabled=body.active;
    const {error:up}=await admin.from('work_accounts')
     .update({active:enabled,updated_at:now()}).eq('auth_user_id',acct.auth_user_id);
    if(up)throw Error('work_configuration_error');
    const {error:role}=await admin.from('staff_roles')
     .update({active:enabled&&!acct.must_change_password}).eq('user_id',acct.auth_user_id).eq('role','cashier');
    if(role)throw Error('work_configuration_error');
    await audit(owner.auth_user_id,enabled?'work.cashier_enabled':'work.cashier_disabled',acct.auth_user_id);
    return send({ok:true});
  }
  const temporary=strong(body.temporary_password,u);
  const {error:pwErr}=await admin.auth.admin.updateUserById(
   acct.auth_user_id,{password:await password(u,temporary)}
  );
  if(pwErr)throw Error('password_update_failed');
  const {error:flag}=await admin.from('work_accounts')
   .update({must_change_password:true,updated_at:now()}).eq('auth_user_id',acct.auth_user_id);
  if(flag)throw Error('password_update_failed');
  const {error:roleErr}=await admin.from('staff_roles')
   .update({active:false}).eq('user_id',acct.auth_user_id).eq('role','cashier');
  if(roleErr)throw Error('password_update_failed');
  await audit(owner.auth_user_id,'work.cashier_password_reset',acct.auth_user_id);
  return send({ok:true,requires_password_change:true});
}
const ownerReset=createOwnerReset({admin,ownerFromRequest,rate,verify,sha,send});

Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:headers()});
 if(req.method!=='POST')return err('method_not_allowed',405);
 const origin=req.headers.get('Origin');
 if(origin&&origin!==ORIGIN)return err('origin_denied',403);
 if(Number(req.headers.get('content-length')||0)>8192)return err('payload_too_large',413);
 if(!URL||!SERVICE||!PUBLIC)return err('work_configuration_error',503);
 try{
  const body=await req.json();
  if(!body||typeof body!=='object'||Array.isArray(body))return err('invalid_request');
  const action=String(body.action||'');
  if(action==='setup_status'){
   const {data,error}=await admin.from('work_setup').select('consumed_at,expires_at').eq('id',true).maybeSingle();
   if(error)throw Error('work_configuration_error');
   return send({ok:true,activated:!!data?.consumed_at,bootstrap_available:!!data&&!data.consumed_at&&Date.parse(data.expires_at)>Date.now()});
  }
  if(action==='activate_owner')return await activate(body,req);
  if(action==='login')return await login(body,req);
  if(action==='me'){const a=await accountFromRequest(req);return send({ok:true,username:a.username,role:a.role,must_change_password:a.must_change_password});}
  if(['reset_prepare','reset_confirm','reset_finish','reset_status'].includes(action))return await ownerReset(action,body,req);
  if(action==='password_change')return await updatePassword(body,req);
  if(action==='staff_create')return await createStaff(body,req);
  if(action==='staff_list')return await listStaff(req);
  if(action==='staff_toggle'||action==='staff_reset')return await changeStaff(body,req,action);
  if(action==='cashier_create')return await createCashier(body,req);
  if(action==='cashier_list')return await listCashier(req);
  if(action==='cashier_toggle'||action==='cashier_reset')return await manageCashier(body,req,action);
  return err('unknown_action',400);
 }catch(e){
  const code=e instanceof Error?e.message:'server_error';
  const publicErrors:Record<string,number>={
    invalid_username:400,weak_password:400,invalid_credentials:401,too_many_attempts:429,
    username_taken:409,not_authenticated:401,owner_only:403,staff_not_found:404,cashier_not_found:404,
    invalid_reset_request:400,reset_confirmation_expired:409,reset_not_committed:409,reset_cleanup_pending:409,reset_cleanup_failed:503,reset_verification_failed:503,password_reused:400,invalid_setup:403,invalid_setup_or_already_used:403,owner_already_exists:409
  };
  if(publicErrors[code])return err(code,publicErrors[code]);
  console.error('yt-work-auth',code);
  return err('server_unavailable',503);
 }
});
