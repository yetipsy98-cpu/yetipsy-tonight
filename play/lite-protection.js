// Lite Protection: non-blocking, privacy-conscious browser association.
// A random install token is not a hardware fingerprint. This is a weak signal only.
import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';
const config=window.YETIPSY_PLAY_CONFIG;
if(config?.url && config?.publishableKey && crypto?.subtle){
  const client=createClient(config.url,config.publishableKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
  const key='yetipsy:lite-install-v1';
  let token;
  try{
    token=localStorage.getItem(key);
    if(!/^[0-9a-f-]{36}$/i.test(token||'')){token=crypto.randomUUID();localStorage.setItem(key,token);}
  }catch{token=null;}
  let lastUser=null;
  async function link(){
    if(!token)return;
    try{
      const {data:{user}}=await client.auth.getUser();
      if(!user || user.id===lastUser)return;
      const bytes=new TextEncoder().encode('yt-lite-v1:'+token);
      const hash=await crypto.subtle.digest('SHA-256',bytes);
      const digest=Array.from(new Uint8Array(hash),b=>b.toString(16).padStart(2,'0')).join('');
      const {error}=await client.rpc('yt_lite_link_my_device',{p_digest:digest});
      if(!error)lastUser=user.id;
      // Feature is optional until migrations are deployed. Never block checkout/login.
    }catch{}
  }
  client.auth.onAuthStateChange(()=>{queueMicrotask(()=>{link().catch(()=>{});});});
  link().catch(()=>{});
}
