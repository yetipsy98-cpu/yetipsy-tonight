
export const receiptBlocks=['brand','document','meta','items','discounts','total','payments','footer'];
export const defaultReceiptLayout=()=>({
  blocks:receiptBlocks.map(id=>({id,visible:true})),font_size:'11',gap:4,
  variants:{
    paid:{blocks:receiptBlocks.map(id=>({id,visible:true}))},
    unpaid:{blocks:receiptBlocks.map(id=>({id,visible:true}))}
  }
});
function sane(list){
 const ids=receiptBlocks;
 if(!Array.isArray(list)||list.length!==ids.length||ids.some(id=>list.filter(x=>x?.id===id).length!==1))
  return ids.map(id=>({id,visible:true}));
 return list.map(b=>({id:b.id,visible:['items','document','total'].includes(b.id)?true:b.visible!==false}));
}
export function normalizeReceiptLayout(source){
 const defaultValue=defaultReceiptLayout();
 if(!source||typeof source!=='object')return defaultValue;
 const out={...defaultValue,...source};
 out.font_size=['9','10','11','12','13','14'].includes(String(out.font_size))?String(out.font_size):'11';
 out.gap=[0,2,4,6,8,10,12,16].includes(Number(out.gap))?Number(out.gap):4;
 out.blocks=sane(source.blocks);
 out.variants={paid:{blocks:sane(source.variants?.paid?.blocks||source.blocks)},unpaid:{blocks:sane(source.variants?.unpaid?.blocks||source.blocks)}};
 return out;
}
export function applyReceiptLayout(paper,raw,mode='paid'){
 if(!paper)return;
 const config=normalizeReceiptLayout(raw),parts=config.variants[mode==='unpaid'?'unpaid':'paid'].blocks;
 const groups=new Map(receiptBlocks.map(id=>[id,[]]));
 let totalStarted=false;
 for(const child of [...paper.children]){
  if(child.dataset.receiptGroup)continue;
  const cls=child.classList;
  let id;
  if(cls.contains('receipt-logo')||cls.contains('receipt-subhead')||cls.contains('receipt-business-line'))id='brand';
  else if(cls.contains('receipt-document'))id='document';
  else if(cls.contains('receipt-facts'))id='meta';
  else if(cls.contains('receipt-items-head')||cls.contains('receipt-row'))id='items';
  else if(cls.contains('receipt-sum')){id='total';totalStarted=true;}
  else if(cls.contains('receipt-discount')||(cls.contains('receipt-subtotal')&&!totalStarted))id='discounts';
  else if(cls.contains('receipt-subtotal')||cls.contains('receipt-hold-note'))id='total';
  else if(cls.contains('receipt-payments'))id='payments';
  else id='footer';
  groups.get(id).push(child);
 }
 paper.style.fontSize=config.font_size+'px';
 paper.style.lineHeight='1.45';
 const wrappers=new Map();
 for(const id of receiptBlocks){
  const div=document.createElement('section');div.dataset.receiptGroup=id;div.className='receipt-layout-group';
  div.style.marginBlock=config.gap+'px';
  groups.get(id).forEach(node=>div.appendChild(node));
  wrappers.set(id,div);
 }
 for(const b of parts){
  const wrapper=wrappers.get(b.id);
  if(wrapper){wrapper.hidden=b.visible===false&& !['items','document','total'].includes(b.id);paper.append(wrapper);}
 }
 return paper;
}
