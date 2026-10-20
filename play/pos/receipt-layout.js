export const receiptBlocks=['brand','document','meta','items','discounts','total','payments','footer'];
export const receiptFields=[
 {id:'business_name',name:'店名'},{id:'subtitle',name:'副标题'},{id:'address_line',name:'地址'},{id:'contact_line',name:'联络资料'},
 {id:'document',name:'付款状态 / 单据类型'},{id:'order_no',name:'订单号码'},{id:'table',name:'桌号'},{id:'created_at',name:'开单时间'},
 {id:'staff',name:'操作员工'},{id:'paid_at',name:'付款时间'},{id:'payment_method',name:'付款方式'},{id:'notes',name:'订单备注'},
 {id:'items',name:'商品与数量明细'},{id:'subtotal',name:'商品原价小计'},{id:'discount_lines',name:'优惠项目明细'},
 {id:'discount_total',name:'优惠总额'},{id:'total',name:'应付 / 实收总额'},{id:'balance',name:'实收净额与未结余额'},
 {id:'payment_history',name:'付款与退款记录'},{id:'reserved_note',name:'优惠预留说明'},{id:'pending_warning',name:'结账审核说明'},{id:'footer',name:'底部说明'}
];
const fieldIds=new Set(receiptFields.map(x=>x.id));
const fontSizes=['0','7','8','9','10','11','12','13','14','15','16','18','20','22','24'];
const positionMap={
 business_name:[0,8,100,22],subtitle:[0,31,100,20],address_line:[0,53,100,18],contact_line:[0,71,100,18],
 document:[0,91,100,36],order_no:[0,131,100,20],table:[0,152,100,20],created_at:[0,173,100,20],
 staff:[0,194,100,20],paid_at:[0,215,100,20],payment_method:[0,236,100,20],notes:[0,257,100,24],
 items:[0,283,100,110],subtotal:[0,397,100,22],discount_lines:[0,421,100,42],discount_total:[0,465,100,22],
 total:[0,489,100,42],balance:[0,533,100,42],payment_history:[0,577,100,72],reserved_note:[0,651,100,34],
 pending_warning:[0,687,100,34],footer:[0,723,100,46]
};
const int=(v,min,max,fallback)=>{const n=Number(v);return Number.isFinite(n)?Math.max(min,Math.min(max,Math.round(n))):fallback;};
function blockList(list){
 const ids=receiptBlocks;
 if(!Array.isArray(list)||list.length!==ids.length||ids.some(id=>list.filter(x=>x?.id===id).length!==1))return ids.map(id=>({id,visible:true}));
 return list.map(b=>({id:b.id,visible:['items','document','total'].includes(b.id)?true:b.visible!==false}));
}
function defaultsFor(settings={}){
 return receiptFields.map(f=>{
  const p=positionMap[f.id]||[0,0,100,24];
  return {key:'field-'+f.id,type:'field',field:f.id,width:'full',align:'left',font_size:'0',
   x:p[0],y:p[1],w:p[2],h:p[3],bold:['business_name','document','order_no','total'].includes(f.id),
   visible:f.id==='table'?settings.show_table!==false:f.id==='staff'?settings.show_staff!==false:f.id==='notes'?settings.show_notes!==false:
    ['discount_lines','discount_total'].includes(f.id)?settings.show_discounts!==false:true};
 });
}
function legacyElements(blocks,settings){
 const expanded={brand:['business_name','subtitle','address_line','contact_line'],document:['document'],
  meta:['order_no','table','created_at','staff','paid_at','payment_method','notes'],items:['items'],
  discounts:['subtotal','discount_lines','discount_total'],total:['total','balance'],payments:['payment_history'],
  footer:['reserved_note','pending_warning','footer']};
 const enabled=Object.fromEntries(blocks.map(x=>[x.id,x.visible]));
 return defaultsFor(settings).map(el=>{
  const block=Object.keys(expanded).find(id=>expanded[id].includes(el.field));
  let visible=enabled[block]!==false&&el.visible;
  if(el.field==='table')visible=visible&&settings.show_table!==false;
  if(el.field==='staff')visible=visible&&settings.show_staff!==false;
  if(el.field==='notes')visible=visible&&settings.show_notes!==false;
  if(['discount_lines','discount_total'].includes(el.field))visible=visible&&settings.show_discounts!==false;
  return {...el,visible};
 });
}
function elementsList(list,fallback){
 if(!Array.isArray(list))return fallback.map(x=>({...x}));
 const used=new Set(),out=[],seenFields=new Set();let appendY=8;
 for(const [index,raw] of list.slice(0,32).entries()){
  if(!raw||typeof raw!=='object')continue;
  const type=['field','text','divider'].includes(raw.type)?raw.type:null;
  if(!type)continue;
  const field=type==='field'&&fieldIds.has(raw.field)?raw.field:null;
  if(type==='field'&&!field)continue;
  const key=String(raw.key||('element-'+(index+1))).replace(/[^a-zA-Z0-9_-]/g,'').slice(0,48)||('element-'+(index+1));
  let unique=key,n=2;while(used.has(unique))unique=key+'-'+n++;
  used.add(unique);
  const duplicate=type==='field'&&seenFields.has(field),p=positionMap[field]||[0,appendY,100,36],fallbackY=duplicate||type!=='field'?appendY:p[1];
  const element={key:unique,type,field,text:type==='text'?String(raw.text??'').slice(0,240):'',
   width:raw.width==='half'?'half':'full',align:['left','center','right'].includes(raw.align)?raw.align:'left',
   font_size:fontSizes.includes(String(raw.font_size))?String(raw.font_size):'0',
   x:int(raw.x,0,90,duplicate?0:p[0]),y:int(raw.y,0,2200,fallbackY),w:int(raw.w,10,100,raw.width==='half'?48:p[2]),h:int(raw.h,18,600,p[3]),
   bold:raw.bold===true,visible:raw.visible!==false,divider:raw.divider==='solid'?'solid':'dashed'};
  out.push(element);if(field)seenFields.add(field);appendY=Math.max(appendY,element.y+element.h+8);
 }
 return out;
}
export const defaultReceiptLayout=(settings={})=>{
 const blocks=receiptBlocks.map(id=>({id,visible:true})),elements=defaultsFor(settings);
 return {blocks,font_size:'11',gap:4,canvas_height:800,variants:{
  paid:{blocks:blocks.map(x=>({...x})),elements:elements.map(x=>({...x}))},
  unpaid:{blocks:blocks.map(x=>({...x})),elements:elements.map(x=>({...x}))}
 }};
};
export function normalizeReceiptLayout(source,settings={}){
 const defaults=defaultReceiptLayout(settings);
 if(!source||typeof source!=='object')return defaults;
 const out={...defaults,...source};
 out.compact_flow=source.compact_flow===true;
 out.font_size=fontSizes.includes(String(out.font_size))?String(out.font_size):'11';
 out.gap=[0,2,4,6,8,10,12,16].includes(Number(out.gap))?Number(out.gap):4;
 out.canvas_height=int(out.canvas_height,400,2400,800);
 out.blocks=blockList(source.blocks);out.variants={};
 for(const mode of ['paid','unpaid']){
  const sourceVariant=source.variants?.[mode]||{},oldBlocks=blockList(sourceVariant.blocks||source.blocks);
  out.variants[mode]={blocks:oldBlocks,elements:elementsList(sourceVariant.elements,legacyElements(oldBlocks,settings))};
 }
 return out;
}
export function applyReceiptLayout(paper,raw,mode='paid',settings={},options={}){
 if(!paper)return;
 const config=normalizeReceiptLayout(raw,settings),elements=config.variants.paid.elements;
 const fieldNodes=new Map([...paper.children].filter(node=>node.dataset?.receiptField).map(node=>[node.dataset.receiptField,node]));
 const compactFlow=config.compact_flow===true&&options.compact===true;
 const usedFields=new Set(),placed=[];
 const makeNode=(item,index)=>{
  let content=null;
  if(item.type==='field'){
   const source=fieldNodes.get(item.field);if(!source)return null;
   content=usedFields.has(item.field)?source.cloneNode(true):source;usedFields.add(item.field);
  }else if(item.type==='text'){
   content=document.createElement('div');content.className='receipt-custom-text';content.textContent=item.text;content.style.whiteSpace='pre-wrap';content.style.overflowWrap='anywhere';
  }else if(item.type==='divider'){
   content=document.createElement('hr');content.className='receipt-custom-divider';content.dataset.divider=item.divider;
  }
  if(!content)return null;
  const wrapper=document.createElement('div');
  wrapper.className='receipt-layout-element receipt-align-'+item.align+(item.bold?' receipt-bold':'');
  wrapper.dataset.elementKey=item.key;wrapper.dataset.elementType=item.type;
  if(item.type==='field')wrapper.dataset.receiptField=item.field;
  wrapper.style.boxSizing='border-box';wrapper.style.minWidth='0';
  if(compactFlow){
   wrapper.style.position='relative';wrapper.style.left='auto';wrapper.style.top='auto';
   wrapper.style.width='auto';wrapper.style.minHeight='0';
  }else{
   wrapper.style.position='absolute';wrapper.style.left=item.x+'%';wrapper.style.top=item.y+'px';
   wrapper.style.width=item.w+'%';wrapper.style.minHeight=item.h+'px';wrapper.style.zIndex=String(index+1);
  }
  if(item.font_size!=='0')wrapper.style.fontSize=item.font_size+'px';
  if(item.type==='text')content.dataset.inlineText=item.key;
  wrapper.append(content);
  return wrapper;
 };
 elements.forEach((item,index)=>{
  if(!item.visible)return;
  const wrapper=makeNode(item,index);
  if(wrapper)placed.push({item,index,wrapper});
 });
 const canvas=document.createElement('div');canvas.className='receipt-layout-canvas';
 canvas.style.position='relative';canvas.style.width='100%';canvas.style.minWidth='0';
 if(compactFlow){
  canvas.dataset.compact='true';canvas.style.display='flex';canvas.style.flexDirection='column';canvas.style.alignItems='stretch';canvas.style.alignContent='start';canvas.style.gap=config.gap+'px';canvas.style.height='auto';canvas.style.minHeight='0';
  const rows=new Map();
  for(const entry of placed){const y=Number(entry.item.y)||0;if(!rows.has(y))rows.set(y,[]);rows.get(y).push(entry);}
  for(const [y,rowItems] of [...rows.entries()].sort((a,b)=>a[0]-b[0])){
   const row=document.createElement('div');row.className='receipt-layout-row';
   row.style.display='grid';row.style.gridTemplateColumns='repeat(100,minmax(0,1fr))';
   row.style.columnGap='0';row.style.alignItems='start';row.style.alignContent='start';row.style.gridAutoRows='min-content';row.style.height='auto';row.style.minHeight='0';row.style.flex='0 0 auto';row.style.width='100%';row.style.minWidth='0';
   for(const {item,wrapper} of rowItems){
    const start=rowItems.length===1?0:Math.max(0,Math.min(99,Number(item.x)||0));
    const span=rowItems.length===1?100:Math.max(1,Math.min(Number(item.w)||100,100-start));
    wrapper.style.gridColumn=(start+1)+' / span '+span;row.append(wrapper);
   }
   canvas.append(row);
  }
  paper.replaceChildren(canvas);paper.style.fontSize=config.font_size+'px';paper.style.lineHeight='1.45';return paper;
 }
 let maxBottom=0;
 for(const {item,wrapper} of placed){canvas.append(wrapper);maxBottom=Math.max(maxBottom,item.y+item.h);}
 canvas.style.minHeight='360px';canvas.style.columnGap=config.gap+'px';
 canvas.style.height=Math.max(config.canvas_height,maxBottom+12)+'px';
 paper.replaceChildren(canvas);paper.style.fontSize=config.font_size+'px';paper.style.lineHeight='1.45';return paper;
}
