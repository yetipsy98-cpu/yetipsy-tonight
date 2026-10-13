// Owner-only review UI. Uses authenticated RPCs; no privileged key in browser.
import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';
const cfg=window.YETIPSY_PLAY_CONFIG;
const button=document.getElementById('liteProtectionRefresh');
const status=document.getElementById('liteProtectionStatus');
const queue=document.getElementById('liteProtectionQueue');
if(button && status && queue && cfg?.url && cfg?.publishableKey){
 const db=createClient(cfg.url,cfg.publishableKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
 const show=message=>{status.textContent=message;};
 const refresh=async()=>{
  button.disabled=true;show('正在读取…');queue.replaceChildren();
  try{
   const {data,error}=await db.rpc('yt_lite_owner_review_queue');
   if(error)throw error;
   const items=Array.isArray(data?.items)?data.items:[];
   show(items.length?'待查看：'+items.length+' 个账号':'暂无需要查看的账号');
   for(const item of items){
    const card=document.createElement('div');card.className='work-panel';
    const label=document.createElement('p');
    label.textContent='账号 '+String(item.user_id).slice(0,8)+'… · 关联账号 '+Number(item.account_count||0)+' · '+(item.released?'已放行':'待审核');
    const action=document.createElement('button');action.type='button';action.className='button button-outline';
    action.textContent=item.released?'撤销放行':'审核并放行';
    action.addEventListener('click',async()=>{
     action.disabled=true;
     const {error:saveError}=await db.rpc('yt_lite_owner_review',{p_user:item.user_id,p_release:!item.released,p_reason:'Owner dashboard review'});
     if(saveError){show('操作失败：'+saveError.message);action.disabled=false;return;}
     await refresh();
    });
    card.append(label,action);queue.append(card);
   }
  }catch(error){show('暂无法读取防刷资料：'+(error?.message||'请确认数据库已部署'));}
  finally{button.disabled=false;}
 };
 button.addEventListener('click',refresh);
}
