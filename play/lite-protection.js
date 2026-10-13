// Nonblocking browser-install association. Server performs keyed hashing.
import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';
const config=window.YETIPSY_PLAY_CONFIG;
if(config?.url && config?.publishableKey){
 const client=createClient(config.url,config.publishableKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
 const key='yetipsy:lite-install-v1';
 let token=null;
 try{
  token=localStorage.getItem(key);
  if(!/^[0-9a-f-]{36}$/i.test(token||'')){token=crypto.randomUUID();localStorage.setItem(key,token);}
 }catch{token=null;}
 let lastUser=null;
 async function link(){
  if(!token)return;
  try{
   const {data:{session}}=await client.auth.getSession();
   if(!session?.user||session.user.id===lastUser)return;
   const response=await fetch(config.url+'/functions/v1/yt-pin-auth',{
    method:'POST',headers:{'Content-Type':'application/json',apikey:config.publishableKey,Authorization:'Bearer '+session.access_token},
    body:JSON.stringify({action:'device_link',device_token:token}),cache:'no-store'
   });
   if(response.ok)lastUser=session.user.id;
  }catch{}
 }
 client.auth.onAuthStateChange(()=>{queueMicrotask(()=>{link().catch(()=>{});});});
 link().catch(()=>{});
}
