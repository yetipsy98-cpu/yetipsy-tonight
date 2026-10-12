// GamePass Lucky Box client: the same ?claim= / ?bundle= QR, without a new QR service.
const escape=s=>String(s??'').replace(/[&<>"']/g,x=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[x]));
const labels={ordinary:'普通幸运',lucky:'幸运礼物',shining:'闪耀礼物',gold:'黄金礼物',legendary:'传说礼物'};
const key=(kind,token)=>'yt-lucky-box-v1:'+kind+':'+token;
function readSaved(kind,token){try{return sessionStorage.getItem(key(kind,token));}catch{return null;}}
function remember(kind,token,secret){try{sessionStorage.setItem(key(kind,token),secret);}catch{}}
export function createLuckyBox({db,showSheet,sheetHtml,getUser,onNeedLogin,onClaimed,notify,stripLink}){
 let ongoing=false;
 const rpc=async(name,args)=>{const r=await db.rpc(name,args);if(r.error)throw r.error;return r.data;};
 function startPanel(kind,token,preview){
  showSheet('LUCKY BOX','YE·TIPSY · OPEN YOUR SURPRISE');
  sheetHtml('<div class="sheet-content lucky-box-screen"><div class="lucky-box-top">LUCKY BOX · YETIPSY PLAY</div>'+
   '<h2>开启属于你的惊喜</h2><p>打开礼物箱，揭晓本次消费的随机积分。</p>'+
   '<div class="lucky-gift-wrap" aria-hidden="true"><div class="lucky-gift"><div class="lucky-gift-lid"><span></span></div><div class="lucky-gift-bow">✦</div><div class="lucky-gift-body"><span></span></div><div class="lucky-gift-light"></div></div><div class="lucky-sparkles">✦　✧　✦</div></div>'+
   '<p class="lucky-box-note">无需先注册；中奖后登录或注册，即可领取积分。</p>'+
   '<button type="button" id="luckyOpenNow" class="button button-primary wide">打开礼物箱 · OPEN BOX</button>'+
   '<p id="luckyBoxStatus" class="tiny-help" role="status">请在领取 QR 有效期内打开。</p></div>');
  const b=document.getElementById('luckyOpenNow');
  b.onclick=async()=>{if(ongoing)return;ongoing=true;b.disabled=true;let secret=readSaved(kind,token);
   if(!secret){secret=crypto.randomUUID();remember(kind,token,secret);}
   try{
    document.querySelector('.lucky-gift')?.classList.add('is-opening');
    const result=await rpc('yt_lucky_reveal',{p_token:token,p_kind:kind,p_secret:secret});
    await new Promise(resolve=>setTimeout(resolve,1200));
    showResult(kind,token,secret,result);
   }catch(e){const status=document.getElementById('luckyBoxStatus');if(status)status.textContent=e.message||'开箱失败，请重试';b.disabled=false;notify(e.message||'开箱失败',true);}
   finally{ongoing=false;}
  };
 }
 function showResult(kind,token,secret,result){
  const claimed=!!result.claimed,expired=Date.parse(result.claim_deadline)<=Date.now();
  const n=Number(result.points||0);
  showSheet(claimed?'领取完成':'你的 Lucky Box','YETIPSY · LUCKY BOX RESULT');
  sheetHtml('<div class="sheet-content lucky-box-screen lucky-result '+escape(result.grade)+'">'+
   '<div class="lucky-box-top">'+(result.grade==='legendary'?'✦ LEGENDARY ✦':'LUCKY BOX REVEALED')+'</div>'+
   '<div class="lucky-result-glyph">✦</div><h2>'+escape(labels[result.grade]||'惊喜积分')+'</h2>'+
   '<div class="lucky-points">+'+n.toLocaleString('en-MY')+'<small>POINTS</small></div>'+
   '<p>本次参与金额 RM'+Number(result.amount_rm||0).toFixed(2)+'</p>'+
   '<div id="luckyClaimSlot"></div>'+
   '<p class="lucky-box-note">每个礼物箱只有一次中奖结果；积分领取后不可转赠。</p></div>');
  const slot=document.getElementById('luckyClaimSlot');
  if(claimed){slot.innerHTML='<p class="lucky-success">✓ 积分已经领取</p>';return;}
  if(expired){slot.innerHTML='<p class="lucky-error">认领期限已过，未领取积分已作废。</p>';return;}
  slot.innerHTML='<p class="tiny-help">请在 '+escape(new Date(result.claim_deadline).toLocaleTimeString('zh-MY',{hour:'2-digit',minute:'2-digit'}))+' 前领取。</p>'+
    '<button type="button" id="luckyClaimButton" class="button button-primary wide">'+(getUser()?'领取 '+n+' 积分到我的钱包':'登录 / 注册领取 '+n+' 积分')+'</button>';
  const button=slot.querySelector('#luckyClaimButton');
  button.onclick=async()=>{
   if(!getUser()){onNeedLogin({kind,token});return;}
   if(ongoing)return;ongoing=true;button.disabled=true;
   try{await claimSecret(kind,token,secret);}
   catch(e){button.disabled=false;notify(e.message||'领取失败',true);}
   finally{ongoing=false;}
  };
 }
 async function claimSecret(kind,token,secret){
  const data=await rpc('yt_lucky_claim',{p_secret:secret});
  stripLink(kind);await onClaimed?.();
  showSheet('积分领取成功','YETIPSY · MY POINTS');
  sheetHtml('<div class="sheet-content lucky-box-screen"><div class="lucky-result-glyph">✦</div>'+
   '<h2>已存入会员钱包</h2><div class="lucky-points">+'+Number(data.points||0).toLocaleString('en-MY')+'<small>POINTS</small></div>'+
   '<p>目前积分余额 '+Number(data.balance||0).toLocaleString('en-MY')+' 分</p><p class="lucky-success">✓ 这张礼物箱已完成领取</p></div>');
  return data;
 }
 async function preview(token,kind){
  if(!['claim','bundle'].includes(kind))return false;
  const v=await rpc('yt_lucky_preview',{p_token:token,p_kind:kind});
  if(!v?.lucky)return false;
  const secret=readSaved(kind,token);
  if(v.opened){
   if(secret){try{const result=await rpc('yt_lucky_reveal',{p_token:token,p_kind:kind,p_secret:secret});showResult(kind,token,secret,result);}
    catch(e){showSheet('领取状态','LUCKY BOX');sheetHtml('<div class="sheet-content"><h2>礼物箱已经打开</h2><p>请使用首次开箱的设备继续领取。</p></div>');}}
   else{showSheet('领取状态','LUCKY BOX');sheetHtml('<div class="sheet-content"><h2>礼物箱已经打开</h2><p>每张 QR 只能开奖一次。请使用原设备领取积分。</p></div>');}
   return true;
  }
  if(!v.valid){
   showSheet('领取状态','LUCKY BOX');sheetHtml('<div class="sheet-content"><h2>二维码已失效</h2><p>尚未开奖请让员工刷新领取码；已开奖请使用原设备继续领取。</p></div>');
   return true;
  }
  startPanel(kind,token,v);return true;
 }
 async function claimPending({kind,token}){
  const secret=readSaved(kind,token);if(!secret)throw Error('找不到本次开箱凭证，请使用原设备');
  return claimSecret(kind,token,secret);
 }
 return{preview,claimPending};
}
