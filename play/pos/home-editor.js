import {homeBlocks} from '../home-layout-core.js?v=20261012-v22';
const defaults={title_zh:'今晚，好事发生。',title_en:'Tonight, good things happen.',subtitle_zh:'',subtitle_en:'',accent:'#E5B769',banner_ratio:'16/9',banner_fit:'contain',blocks:homeBlocks.map(id=>({id,visible:true})),labels:{game:{zh:'扫码玩游戏',en:'Scan to play'},claim:{zh:'领取奖励',en:'Claim reward'},prizes:{zh:'奖品公示',en:'Prizes'},wallet:{zh:'我的奖励',en:'My rewards'},leaderboard:{zh:'游戏排行榜',en:'Leaderboards'}},links:[]};
const names={greeting:'首页标题',carousel:'轮播广告',games:'扫码游戏',claim:'领取奖励',shortcuts:'奖励入口',leaderboard:'排行榜'};
const safe=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;','"':'&quot;'}[c]));
const copy=x=>JSON.parse(JSON.stringify(x));
const normalize=x=>({...copy(defaults),...x,blocks:Array.isArray(x?.blocks)&&x.blocks.length===6?x.blocks:copy(defaults.blocks),labels:{...copy(defaults.labels),...(x?.labels||{})}});
export function createHomeEditor({db,root,notice}){
 let draft=copy(defaults),published=copy(defaults);
 const f=k=>root.querySelector('[data-key="'+k+'"]');
 function draw(){
  root.innerHTML='<article class="card"><p class="kicker">OWNER · HOMEPAGE</p><h2>客户端自定义</h2><p class="muted">可编辑中英文、按钮、模块顺序与轮播显示。先保存草稿，再发布。</p>'+
  ['title_zh','title_en','subtitle_zh','subtitle_en'].map(k=>'<label>'+k+'<input data-key="'+k+'" maxlength="140"></label>').join('')+
  '<div class="pair"><label>主题金色<input type="color" data-key="accent"></label><label>轮播比例<select data-key="banner_ratio"><option>16/9</option><option>32/9</option><option>2/1</option><option>4/3</option></select></label></div>'+
  '<label>轮播显示<select data-key="banner_fit"><option value="contain">完整显示</option><option value="cover">铺满裁切</option></select></label>'+
  '<h3>版块排序与显示</h3><div id="homeLayoutBlocks"></div><h3>按钮名称（中文 / English）</h3><div id="homeLayoutLabels"></div>'+
  '<h3>预览（未发布）</h3><div id="homeLayoutPreview" style="border:1px solid #a48a5966;padding:14px;border-radius:12px"></div>'+
  '<div class="button-row"><button type="button" id="homeLayoutSave" class="quiet">保存草稿</button><button type="button" id="homeLayoutPublish" class="main-button">发布到首页</button><button type="button" id="homeLayoutRollback" class="quiet">恢复已发布版</button></div><p id="homeLayoutStatus" role="status"></p></article>';
  ['title_zh','title_en','subtitle_zh','subtitle_en','accent','banner_ratio','banner_fit'].forEach(k=>{f(k).value=draft[k]||defaults[k];f(k).oninput=()=>{draft[k]=f(k).value;preview();};});
  root.querySelector('#homeLayoutSave').onclick=()=>save(false);
  root.querySelector('#homeLayoutPublish').onclick=()=>save(true);
  root.querySelector('#homeLayoutRollback').onclick=()=>{draft=copy(published);draw();};
  blocks();labels();preview();
 }
 function blocks(){
  const box=root.querySelector('#homeLayoutBlocks');
  box.innerHTML=draft.blocks.map((b,i)=>'<div style="display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:8px;padding:10px;border:1px solid #ffffff24;border-radius:9px"><label class="checkline"><input type="checkbox" data-show="'+safe(b.id)+'" '+(b.visible?'checked':'')+'>'+names[b.id]+'</label><div><button type="button" data-dir="-1" data-id="'+b.id+'" '+(i===0?'disabled':'')+'>↑</button><button type="button" data-dir="1" data-id="'+b.id+'" '+(i===5?'disabled':'')+'>↓</button></div></div>').join('');
  box.onchange=e=>{const id=e.target.dataset.show;if(id){draft.blocks.find(b=>b.id===id).visible=e.target.checked;preview();}};
  box.onclick=e=>{const button=e.target.closest('[data-dir]');if(!button)return;const i=draft.blocks.findIndex(b=>b.id===button.dataset.id),j=i+Number(button.dataset.dir);if(j<0||j>=6)return;[draft.blocks[i],draft.blocks[j]]=[draft.blocks[j],draft.blocks[i]];blocks();preview();};
 }
 function labels(){
  const box=root.querySelector('#homeLayoutLabels');
  box.innerHTML=Object.keys(defaults.labels).map(k=>'<label>'+k+'<div class="pair"><input data-label="'+k+'" data-lang="zh" maxlength="60" value="'+safe(draft.labels[k]?.zh)+'"><input data-label="'+k+'" data-lang="en" maxlength="60" value="'+safe(draft.labels[k]?.en)+'"></div></label>').join('');
  box.oninput=e=>{const t=e.target;if(!t.dataset.label)return;draft.labels[t.dataset.label][t.dataset.lang]=t.value;preview();};
 }
 function preview(){const box=root.querySelector('#homeLayoutPreview');box.replaceChildren();const title=document.createElement('strong');title.textContent=draft.title_zh;box.append(title);for(const b of draft.blocks.filter(b=>b.visible)){const p=document.createElement('p');p.textContent=names[b.id];p.style.cssText='border:1px solid #d0af7245;padding:9px;border-radius:9px';box.append(p);}}
 async function save(publish){const status=root.querySelector('#homeLayoutStatus');status.textContent='保存中…';if(draft.blocks.every(b=>!b.visible)){status.textContent='至少显示一个模块';return;}
  const res=await db.rpc('yt_home_layout_save',{p_layout:draft,p_publish:publish});if(res.error){status.textContent='保存失败：'+res.error.message;notice(status.textContent,true);return;}
  published=normalize(res.data.published);status.textContent=publish?'已发布，顾客刷新后生效':'草稿已保存，未影响顾客首页';notice(status.textContent);
 }
 async function load(){const r=await db.rpc('yt_home_layout_owner_get');if(r.error)throw r.error;published=normalize(r.data?.published||{});draft=normalize(Object.keys(r.data?.draft||{}).length?r.data.draft:r.data.published||{});draw();}
 return{load,cancel(){}};
}
