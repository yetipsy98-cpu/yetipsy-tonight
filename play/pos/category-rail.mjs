// Mouse wheels scroll only the category rail while there are categories to reveal.
// At either edge, the normal page scroll remains available. Trackpad deltaX stays native.
export function createCategoryRail(root,{left,right}={}){
 if(!root||!left||!right)return;
 if(root.updateCategoryRail)return root.updateCategoryRail;
 const maximum=()=>Math.max(0,root.scrollWidth-root.clientWidth);
 const update=()=>{const max=maximum();left.disabled=root.scrollLeft<=1;right.disabled=root.scrollLeft>=max-1;left.hidden=right.hidden=max<=1;};
 const move=delta=>{const before=root.scrollLeft;root.scrollLeft=Math.max(0,Math.min(maximum(),before+delta));update();return root.scrollLeft!==before;};
 left.onclick=()=>move(-Math.max(120,root.clientWidth*.75));right.onclick=()=>move(Math.max(120,root.clientWidth*.75));
 root.addEventListener('wheel',e=>{if(e.ctrlKey||e.shiftKey||Math.abs(e.deltaX)>=Math.abs(e.deltaY)||!maximum())return;const scale=e.deltaMode===1?16:e.deltaMode===2?root.clientWidth:1;if(move(e.deltaY*scale))e.preventDefault();},{passive:false});
 root.addEventListener('scroll',update,{passive:true});
 root.tabIndex=0;root.addEventListener('keydown',e=>{if(e.target!==root)return;if(e.key==='ArrowRight'||e.key==='ArrowLeft'){if(move((e.key==='ArrowRight'?1:-1)*Math.max(120,root.clientWidth*.75)))e.preventDefault();}else if(e.key==='Home'||e.key==='End'){if(move(e.key==='Home'?-maximum():maximum()))e.preventDefault();}});
 if(typeof ResizeObserver!=='undefined')new ResizeObserver(update).observe(root);else if(typeof window!=='undefined')window.addEventListener('resize',update);
 root.updateCategoryRail=update;update();return update;
}
