import {applyHomeLayout,homeBlocks} from './home-layout-core.js?v=20261012-v22';
export function startHomeLayout({db,language}){
 const root=document.getElementById('homePage');
 if(!root)return {refresh:async()=>{},apply:()=>{}};
 let data={title_zh:'今晚，好事发生。',title_en:'Tonight, good things happen.',banner_ratio:'16/9',banner_fit:'contain',blocks:homeBlocks.map(id=>({id,visible:true}))};
 const apply=()=>applyHomeLayout(root,data,language());
 async function refresh(){
  const result=await db.rpc('yt_home_layout_get');if(result.error)throw result.error;
  if(result.data&&Array.isArray(result.data.blocks))data={...data,...result.data};
  apply();
 }
 const carousel=root.querySelector('#homeCarousel');
 if(carousel)new MutationObserver(apply).observe(carousel,{childList:true,subtree:true});
 apply();
 return{refresh,apply};
}
