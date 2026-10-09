import {BANNER_BUCKET} from './owner-banners.js?v=20261009-client-v5-1';
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function createHomeCarousel({db,root}){
 let slides=[],index=0,paused=false,startX=null,epoch=0;
 const fallback=[{title:'今晚，玩点新的。',kicker:'YE · TIPSY PLAY',copy:'五款小游戏，把幸运收进你的奖励钱包。'},{title:'一份好礼，随时收藏。',kicker:'YOUR REWARDS CLUB',copy:'扫描领取 QR 或输入短码，查看奖励使用时间。'}];
 function select(n){index=(n+slides.length)%slides.length;root.querySelectorAll('.home-ad-slide').forEach((e,i)=>e.hidden=i!==index);root.querySelectorAll('[data-ad-dot]').forEach((e,i)=>{e.setAttribute('aria-pressed',String(i===index));e.classList.toggle('active',i===index);});root.querySelector('.ad-position').textContent=(index+1)+' / '+slides.length;}
 function render(data){slides=data.length?data:fallback;index=0;root.innerHTML='<div class="home-ad-frame" aria-roledescription="轮播" aria-label="Yetipsy 最新消息">'+slides.map((a,i)=>'<div class="home-ad-slide '+(a.image_path?'':'home-ad-default')+'" '+(i?'hidden':'')+'>'+ (a.image_path?'<img src="'+esc(db.storage.from(BANNER_BUCKET).getPublicUrl(a.image_path).data.publicUrl)+'" alt="'+esc(a.title)+'" '+(i?'loading="lazy"':'fetchpriority="high"')+'><span class="ad-image-title">'+esc(a.title)+'</span>':'<span class="ad-star" aria-hidden="true">✳</span><span class="ad-kicker">'+esc(a.kicker)+'</span><h2>'+esc(a.title)+'</h2><p>'+esc(a.copy)+'</p>')+'</div>').join('')+'</div><div class="home-ad-controls"><span class="ad-position">1 / '+slides.length+'</span><div class="ad-dots">'+slides.map((_,i)=>'<button type="button" data-ad-dot="'+i+'" aria-label="广告 '+(i+1)+'" aria-pressed="'+(i===0)+'" class="'+(i===0?'active':'')+'"></button>').join('')+'</div><div class="ad-arrows"><button type="button" data-ad-prev aria-label="上一张广告">←</button><button type="button" data-ad-next aria-label="下一张广告">→</button></div></div>';
 root.querySelectorAll('[data-ad-dot]').forEach(b=>b.onclick=()=>select(Number(b.dataset.adDot)));root.querySelector('[data-ad-prev]').onclick=()=>select(index-1);root.querySelector('[data-ad-next]').onclick=()=>select(index+1);
 }
 async function refresh(){const e=++epoch;const result=await db.rpc('yt_home_banner_list');if(result.error)throw Error(result.error.message);if(e!==epoch)return;render(result.data||[]);}
 root.onpointerdown=e=>{startX=e.clientX;};root.onpointerup=e=>{if(startX!==null&&Math.abs(e.clientX-startX)>45)select(index+(e.clientX<startX?1:-1));startX=null;};root.onpointercancel=()=>startX=null;
 root.onmouseenter=()=>paused=true;root.onmouseleave=()=>paused=false;root.onfocusin=()=>paused=true;root.onfocusout=()=>paused=false;
 render([]);const timer=setInterval(()=>{if(slides.length>1&&!paused&&document.visibilityState==='visible'&&root.getClientRects().length&&!window.matchMedia('(prefers-reduced-motion: reduce)').matches)select(index+1);},5500);
 return {refresh,destroy(){clearInterval(timer);}};
}
