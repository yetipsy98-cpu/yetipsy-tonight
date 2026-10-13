import { createClient } from 'npm:@supabase/supabase-js@2.117.2';

const URL = Deno.env.get('SUPABASE_URL') || '';
const ADMIN_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
const PUBLIC_KEY = Deno.env.get('SUPABASE_ANON_KEY') || '';
const ALLOWED_ORIGIN = 'https://yetipsy98-cpu.github.io';
const admin = createClient(URL, ADMIN_KEY, {auth:{autoRefreshToken:false,persistSession:false}});
let cachedPepper: string | null = null;

function headers(origin:string|null):Record<string,string> {
 return {'Access-Control-Allow-Origin':origin===ALLOWED_ORIGIN?ALLOWED_ORIGIN:ALLOWED_ORIGIN,
  'Access-Control-Allow-Methods':'POST, OPTIONS',
  'Access-Control-Allow-Headers':'content-type,apikey,authorization,x-client-info',
  'Access-Control-Max-Age':'86400', 'Content-Type':'application/json; charset=utf-8',
  'Cache-Control':'no-store'};
}
function send(data:Record<string,unknown>,status=200,origin:string|null=null) {
 return new Response(JSON.stringify(data),{status,headers:headers(origin)});
}
function phoneValue(raw:unknown):string {
 const s=String(raw||'').replace(/[\s()-]/g,'');
 if(!/^\+(?:601\d{8,9}|65[89]\d{7})$/.test(s))throw Error('invalid_phone');
 return s;
}

function birthValue(raw:unknown):string {
 const s=String(raw||'');
 if(!/^\d{4}-\d{2}-\d{2}$/.test(s))throw Error('invalid_birthday');
 const date=new Date(s+'T00:00:00Z');
 if(!Number.isFinite(date.getTime())||date.toISOString().slice(0,10)!==s)throw Error('invalid_birthday');
 return s;
}
async function sha256hex(s:string) {
 const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s));
 return Array.from(new Uint8Array(digest),x=>x.toString(16).padStart(2,'0')).join('');
}
function pinValue(raw:unknown):string {
 const pin=String(raw??'');
 if(!/^\d{6}$/.test(pin))throw Error('invalid_pin');
 if(/^(\d)\1{5}$/.test(pin)||['123456','654321','012345','987654'].includes(pin))throw Error('weak_pin');
 return pin;
}
async function pepper() {
 if(cachedPepper)return cachedPepper;
 const {data,error}=await admin.rpc('yt_pin_secret_value');
 if(error||typeof data!=='string'||data.length<32)throw Error('server_not_configured');
 cachedPepper=data;return data;
}
async function password(phone:string,pin:string) {
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(await pepper()),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 const bytes=new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode('ytplay:v1:'+phone+':'+pin)));
 return 'YTP-'+Array.from(bytes,x=>x.toString(16).padStart(2,'0')).join('');
}
async function allowed(phone:string) {
 const {data,error}=await admin.rpc('yt_pin_gate',{p_phone:phone,p_reset:false});
 if(error)throw Error('server_unavailable');
 return data===true;
}
async function reset(phone:string) {await admin.rpc('yt_pin_gate',{p_phone:phone,p_reset:true});}
async function signIn(email:string,pass:string) {
 const publicClient=createClient(URL,PUBLIC_KEY,{auth:{autoRefreshToken:false,persistSession:false,detectSessionInUrl:false}});
 return await publicClient.auth.signInWithPassword({email,password:pass});
}

Deno.serve(async(req:Request)=>{
 const origin=req.headers.get('Origin');
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:headers(origin)});
 if(req.method!=='POST')return send({ok:false,error:'method_not_allowed'},405,origin);
 if(origin&&origin!==ALLOWED_ORIGIN)return send({ok:false,error:'origin_not_allowed'},403,origin);
 if(Number(req.headers.get('content-length')||0)>4096)return send({ok:false,error:'request_too_large'},413,origin);
 if(!ADMIN_KEY||!PUBLIC_KEY||!URL)return send({ok:false,error:'server_not_configured'},503,origin);
 try {
  const body=await req.json();
  if(typeof body!=='object'||!body)return send({ok:false,error:'invalid_request'},400,origin);
  const action=body.action;

  if(!['register','login','check','preview','prizes','rules','referral_check','reset_prepare','reset_finish','change_pin'].includes(action))
    return send({ok:false,error:'unknown_action'},400,origin);


  // Public prize notice: whitelist only reward, gameplay and redemption copy.
  // Never serialize the internal probability-bearing rows to clients.

  if(action==='referral_check'){
    const code=String(body.code||'').trim().toUpperCase();
    if(!/^YT[A-Z0-9]{8}$/.test(code))return send({ok:true,valid:false},200,origin);
    const {data,error}=await admin.rpc('yt_referral_code_check',{p_code:code});
    if(error)throw Error('server_unavailable');
    return send({ok:true,valid:data===true},200,origin);
  }
  if(action==='rules'){
    const slug=String(body.slug||'');
    const campaign=String(body.campaign_id||'');
    if(!['moon-dice','mystery-card','mystery-box','reaction-test','stop-the-bar'].includes(slug)
      ||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(campaign))
      return send({ok:false,error:'invalid_request'},400,origin);
    const {data,error}=await admin.rpc('yt_public_game_rules',{p_campaign:campaign,p_slug:slug});
    if(error)throw Error('server_unavailable');
    return send({ok:true,rules:(data||[]).map((r:any)=>({
      result_key:String(r.result_key||''),reward_name:String(r.reward_name||''),
      description:String(r.description||''),redeem_rules:String(r.redeem_rules||'')
    }))},200,origin);
  }
  if(action==='prizes'){
    const {data:privateRows,error:boardError}=await admin.rpc('yt_prize_board');
    if(boardError)throw Error('server_unavailable');
    const gameplay:Record<string,string>={
      'moon-dice':'摇动五颗骰子，看看你的幸运点数。完成后，奖励将存入会员钱包。',
      'mystery-card':'选择并翻开一张神秘卡，揭晓本轮惊喜奖励。',
      'mystery-box':'开启神秘礼盒，揭晓本轮惊喜奖励。',
      'reaction-test':'等信号变绿后快速点击，挑战反应时间。成绩仅作娱乐展示。',
      'stop-the-bar':'看准移动中的指针并按下 STOP，挑战停在中央。成绩仅作娱乐展示。'
    };
    const published:any[]=[],seen=new Set<string>();
    for(const row of privateRows||[]){
      const key=[row.campaign_name,row.game_slug,row.reward_name].join('\u001f');
      if(seen.has(key))continue;
      seen.add(key);
      published.push({
        campaign_name:String(row.campaign_name||'Yetipsy Play'),
        game_slug:String(row.game_slug||''),
        game_title:String(row.game_title||'Yetipsy Game'),
        how_to_play:gameplay[String(row.game_slug||'')]||'使用已领取的 Game Pass 参与游戏，完成后获得奖励。',
        reward_name:String(row.reward_name||'Yetipsy Reward'),
        description:String(row.description||''),
        redeem_rules:String(row.redeem_rules||'')
      });
    }
    return send({ok:true,prizes:published},200,origin);
  }
  if(action==='preview'){
    const kind=String(body.kind||''),token=String(body.token||'').toLowerCase();
    if(!['gift','claim'].includes(kind)||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(token))
      return send({ok:false,error:'invalid_claim_token'},400,origin);
    const hash=await sha256hex(token), now=Date.now();
    if(kind==='gift'){
      const {data:offer,error:lookupError}=await admin.from('reward_offers')
        .select('active,starts_at,ends_at,max_claims,claimed_count,per_user_limit,rewards(name,description,redeem_rules,active)')
        .eq('token_hash',hash).maybeSingle();
      if(lookupError)throw Error('server_unavailable');
      if(!offer)return send({ok:true,preview:{kind,valid:false,message:'找不到这个领取码'}},200,origin);
      const r=Array.isArray(offer.rewards)?offer.rewards[0]:offer.rewards;
      return send({ok:true,preview:{
        kind,valid:Boolean(offer.active&&r?.active&&Date.parse(offer.starts_at)<=now&&Date.parse(offer.ends_at)>now&&offer.claimed_count<offer.max_claims),
        title:r?.name||'Yetipsy Reward',subtitle:'A GIFT FROM YETIPSY',description:r?.description||'',
        rules:r?.redeem_rules||'',expires_at:offer.ends_at,
        remaining:Math.max(0,offer.max_claims-offer.claimed_count),per_user_limit:offer.per_user_limit
      }},200,origin);
    }
    const {data:pass,error:passErr}=await admin.from('game_passes')
      .select('status,expires_at,campaign_id,campaigns(name,active,starts_at,ends_at)')
      .eq('claim_token_hash',hash).maybeSingle();
    if(passErr)throw Error('server_unavailable');
    if(!pass)return send({ok:true,preview:{kind,valid:false,message:'找不到这个游戏码'}},200,origin);
    const c=Array.isArray(pass.campaigns)?pass.campaigns[0]:pass.campaigns;
    const {count,error:countErr}=await admin.from('campaign_games').select('game_id',{count:'exact',head:true}).eq('campaign_id',pass.campaign_id);
    if(countErr)throw Error('server_unavailable');
    return send({ok:true,preview:{
      kind,valid:Boolean(pass.status==='issued'&&Date.parse(pass.expires_at)>now&&c?.active&&
        (!c.starts_at||Date.parse(c.starts_at)<=now)&&(!c.ends_at||Date.parse(c.ends_at)>now)),
      title:'Yetipsy Game Pass',subtitle:c?.name||'Yetipsy Play',
      description:'领取一次游戏机会，自由选择开放游戏，完成后将获得奖励。',
      game_count:count||0,expires_at:pass.expires_at,status:pass.status
    }},200,origin);
  }
  if(action==='reset_finish'){
    const token=String(body.token||'');
    if(!/^[0-9a-f-]{36}$/i.test(token))return send({ok:false,error:'invalid_reset_token'},400,origin);
    const pin=pinValue(body.pin);
    const hashed=await sha256hex(token);
    const current=new Date().toISOString();
    const {data:entry,error:entryErr}=await admin.from('pin_reset_tokens').update({consumed_at:current})
      .eq('token_hash',hashed).is('consumed_at',null).gt('expires_at',current)
      .select('user_id').maybeSingle();
    if(entryErr||!entry)return send({ok:false,error:'reset_invalid_or_expired'},410,origin);
    const {data:account}=await admin.from('pin_accounts').select('phone').eq('auth_user_id',entry.user_id).maybeSingle();
    if(!account?.phone)throw Error('server_unavailable');
    const {error:changed}=await admin.auth.admin.updateUserById(entry.user_id,{password:await password(account.phone,pin)});
    if(changed)throw Error('server_unavailable');
    return send({ok:true,message:'PIN 已更新，请重新登录'},200,origin);
  }
  const phone=phoneValue(body.phone);
  if(action==='check'){
    const {data:pass,error:rateError}=await admin.rpc('yt_pin_lookup_gate',{p_phone:phone});
    if(rateError||!pass)return send({ok:false,error:'too_many_attempts'},429,origin);
    const {data:account,error:foundError}=await admin.from('pin_accounts').select('auth_user_id').eq('phone',phone).maybeSingle();
    if(foundError)throw Error('server_unavailable');
    return send({ok:true,registered:!!account},200,origin);
  }
  if(action==='reset_prepare'||action==='change_pin'){
    const authToken=(req.headers.get('Authorization')||'').replace(/^Bearer\s+/i,'');
    if(!authToken)return send({ok:false,error:'not_authenticated'},401,origin);
    const {data:session,error:whoError}=await admin.auth.getUser(authToken);
    if(whoError||!session.user)return send({ok:false,error:'not_authenticated'},401,origin);
    if(action==='change_pin'){
      const {data:account}=await admin.from('pin_accounts').select('phone').eq('phone',phone).eq('auth_user_id',session.user.id).maybeSingle();
      if(!account)return send({ok:false,error:'not_authenticated'},403,origin);
      const oldPin=pinValue(body.old_pin),newPin=pinValue(body.pin);
      const {data:profile}=await admin.auth.admin.getUserById(session.user.id);
      if(!profile.user?.email)throw Error('server_unavailable');
      const {data:verified}=await signIn(profile.user.email,await password(phone,oldPin));
      if(!verified.session)return send({ok:false,error:'invalid_credentials'},401,origin);
      const {error:changed}=await admin.auth.admin.updateUserById(session.user.id,{password:await password(phone,newPin)});
      if(changed)throw Error('server_unavailable');
      return send({ok:true},200,origin);
    }
    const {data:staff}=await admin.from('staff_roles').select('role,active').eq('user_id',session.user.id).maybeSingle();
    if(!staff?.active||!['owner','staff'].includes(staff.role))
      return send({ok:false,error:'staff_only'},403,origin);
    if(body.onsite_confirmed!==true)return send({ok:false,error:'onsite_verification_required'},400,origin);
    const birth=birthValue(body.birthday);
    const {data:account}=await admin.from('pin_accounts').select('auth_user_id').eq('phone',phone).maybeSingle();
    if(!account)return send({ok:false,error:'identity_mismatch'},403,origin);
    const {data:person}=await admin.from('member_details').select('birth_date').eq('user_id',account.auth_user_id).maybeSingle();
    if(!person||person.birth_date!==birth)return send({ok:false,error:'identity_mismatch'},403,origin);
    const token=crypto.randomUUID();
    const {error:writeErr}=await admin.from('pin_reset_tokens').insert({
      token_hash:await sha256hex(token),user_id:account.auth_user_id,requested_by:session.user.id,
      expires_at:new Date(Date.now()+5*60000).toISOString()
    });
    if(writeErr)throw Error('server_unavailable');
    await admin.from('audit_logs').insert({actor_id:session.user.id,action:'pin.reset_prepare',entity_type:'member',entity_id:account.auth_user_id});
    return send({ok:true,token,expires_in:300},200,origin);
  }
  const pin=pinValue(body.pin);
  if(!await allowed(phone))return send({ok:false,error:'too_many_attempts',message:'尝试次数过多，请 15 分钟后再试'},429,origin);
  const pass=await password(phone,pin);

  if(action==='register') {
   const name=String(body.nickname??'').trim().slice(0,40);
   if(name.length<2)return send({ok:false,error:'invalid_nickname',message:'请填写至少 2 个字的称呼'},400,origin);
   const birthday=birthValue(body.birthday);
   const invite=String(body.referral_code||'').trim().toUpperCase();
   if(invite && !/^YT[A-Z0-9]{8}$/.test(invite))
     return send({ok:false,error:'invalid_referral_code',message:'好友码格式不正确'},400,origin);
   if(invite){
     const {data:validInvite,error:verifyError}=await admin.rpc('yt_referral_code_check',{p_code:invite});
     if(verifyError)throw Error('server_unavailable');
     if(validInvite!==true)return send({ok:false,error:'invalid_referral_code',message:'好友码无效或活动未开放'},400,origin);
   }
   const {data:existing,error:lookupError}=await admin.from('pin_accounts').select('auth_user_id').eq('phone',phone).maybeSingle();
   if(lookupError)throw Error('server_unavailable');
   if(existing)return send({ok:false,error:'already_registered',message:'这个号码已注册，请使用 PIN 登录'},409,origin);
   const alias=crypto.randomUUID().replaceAll('-','')+'@accounts.yetipsy.app';
   const {data:created,error:createdError}=await admin.auth.admin.createUser({email:alias,password:pass,email_confirm:true});
   if(createdError||!created.user?.id)throw Error('signup_unavailable');
   const uid=created.user.id;
   const {error:insertError}=await admin.from('pin_accounts').insert({auth_user_id:uid,phone});
   if(insertError) {
     await admin.auth.admin.deleteUser(uid);
     if(insertError.code==='23505')return send({ok:false,error:'already_registered',message:'这个号码已注册，请直接登录'},409,origin);
     throw Error('signup_unavailable');
   }

   const {error:memberError}=await admin.from('member_details').insert({
     user_id:uid,birth_date:birthday,privacy_accepted_at:null,marketing_opt_in:body.marketing===true,phone_verified:false
   });
   if(memberError){await admin.auth.admin.deleteUser(uid);throw Error('signup_unavailable');}
   const {error:profileError}=await admin.from('profiles').update({phone,display_name:name||'Yetipsy Member'}).eq('id',uid);
   if(profileError)console.warn('Profile synchronization failed:',profileError.code);
   // Link a weak browser-install identifier before newcomer promotions are issued.
   // The digest is keyed server-side; the raw identifier is never stored in SQL.
   const deviceToken=String(body.device_token||'');
   if(/^[0-9a-f-]{36}$/i.test(deviceToken)){
     const hmacKey=await crypto.subtle.importKey('raw',new TextEncoder().encode(await pepper()),{name:'HMAC',hash:'SHA-256'},false,['sign']);
     const signature=new Uint8Array(await crypto.subtle.sign('HMAC',hmacKey,new TextEncoder().encode('yt-lite-device-v1:'+deviceToken)));
     const deviceDigest=Array.from(signature,x=>x.toString(16).padStart(2,'0')).join('');
     const {error:deviceError}=await admin.rpc('yt_lite_register_device',{p_user:uid,p_digest:deviceDigest});
     if(deviceError){
       await admin.auth.admin.deleteUser(uid);
       throw Error('signup_unavailable');
     }
   }
   const {error:enrollmentError}=await admin.rpc('yt_member_onboard',{p_customer:uid,p_ref_code:invite||null});
   if(enrollmentError){
     console.error('loyalty_onboard_failed',enrollmentError.code);
     const {error:cleanupError}=await admin.auth.admin.deleteUser(uid);
     if(cleanupError)console.error('loyalty_registration_cleanup_failed',cleanupError.code);
     throw Error('signup_unavailable');
   }
   const {data:session,error:authError}=await signIn(alias,pass);
   if(authError||!session.session)throw Error('registered_but_login_failed');
   await reset(phone);
   return send({ok:true,access_token:session.session.access_token,refresh_token:session.session.refresh_token,expires_in:session.session.expires_in},200,origin);
  }
  const {data:linked,error:lookupError}=await admin.from('pin_accounts').select('auth_user_id').eq('phone',phone).maybeSingle();
  if(lookupError)throw Error('server_unavailable');
  if(!linked) return send({ok:false,error:'invalid_credentials',message:'手机号或 PIN 不正确'},401,origin);
  const {data:userInfo,error:userError}=await admin.auth.admin.getUserById(linked.auth_user_id);
  if(userError||!userInfo.user?.email)throw Error('server_unavailable');
  const {data:session,error:authError}=await signIn(userInfo.user.email,pass);
  if(authError||!session.session)return send({ok:false,error:'invalid_credentials',message:'手机号或 PIN 不正确'},401,origin);
  await reset(phone);
  return send({ok:true,access_token:session.session.access_token,refresh_token:session.session.refresh_token,expires_in:session.session.expires_in},200,origin);
 } catch(error) {
  const message=error instanceof Error?error.message:'unknown_error';

  if(['invalid_phone','invalid_pin','weak_pin','invalid_birthday'].includes(message))
   return send({ok:false,error:message,message:({
    invalid_phone:'请输入正确的马来西亚或新加坡手机号',
    invalid_pin:'请输入 6 位数字 PIN',
    weak_pin:'PIN 太容易猜，请换一个',
    invalid_birthday:'请填写有效的完整出生日期'
   } as Record<string,string>)[message]},400,origin);
  console.error('pin-auth:',message);
  return send({ok:false,error:message==='registered_but_login_failed'?message:'server_unavailable',message:'服务暂时不可用，请稍后重试'},503,origin);
 }
});
