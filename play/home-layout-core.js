// Yetipsy homepage owner layout renderer, safe text-only inputs.
export const homeBlocks=['greeting','carousel','games','claim','shortcuts','leaderboard'];
export function applyHomeLayout(root,data,language='zh'){
 if(!root||!data||!Array.isArray(data.blocks))return;
 const sections={greeting:root.querySelector('.home-greeting'),carousel:root.querySelector('#homeCarousel'),games:root.querySelector('.home-game-actions'),claim:root.querySelector('#homeRewardClaim'),shortcuts:root.querySelector('.home-shortcuts'),leaderboard:root.querySelector('#homeLeaderboard')};
 for(const block of data.blocks){if(!homeBlocks.includes(block.id))continue;const node=sections[block.id];if(!node)continue;node.style.display=block.visible===false?'none':'';root.append(node);}
 const heading=sections.greeting?.querySelector('h1');
 const title=language==='en'?data.title_en:data.title_zh;
 if(heading&&typeof title==='string'&&title.trim()){heading.textContent=title;}
 const subtitle=language==='en'?data.subtitle_en:data.subtitle_zh;
 const sub=root.querySelector('#homeGreetingSub');if(sub&&typeof subtitle==='string'&&subtitle.trim())sub.textContent=subtitle;
 const frame=sections.carousel?.querySelector('.home-ad-frame');if(frame&&['32/9','16/9','2/1','4/3'].includes(data.banner_ratio))frame.style.aspectRatio=data.banner_ratio;
 if(['cover','contain'].includes(data.banner_fit))sections.carousel?.querySelectorAll('img').forEach(img=>img.style.objectFit=data.banner_fit);
 const lang=language==='en'?'en':'zh';
 const selector={game:'#heroScan',claim:'#homeRewardClaim strong',prizes:'#homePrizes strong',wallet:'#homeWallet strong',leaderboard:'#homeLeaderboard strong'};
 for(const key of Object.keys(selector)){const node=root.querySelector(selector[key]),text=data.labels?.[key]?.[lang];if(node&&typeof text==='string'&&text.trim())node.textContent=key==='game'?'▣ '+text+' ↗':text;}
 if(/^#[0-9a-f]{6}$/i.test(data.accent||''))root.style.setProperty('--gold',data.accent);
}
