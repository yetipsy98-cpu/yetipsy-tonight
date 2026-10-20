export const receiptBlocks=['brand','document','meta','items','discounts','total','payments','footer'];
export const receiptFields=[
 {id:'business_name',name:'店名'},
 {id:'subtitle',name:'副标题'},
 {id:'address_line',name:'地址'},
 {id:'contact_line',name:'联络资料'},
 {id:'document',name:'付款状态 / 单据类型'},
 {id:'order_no',name:'订单号码'},
 {id:'table',name:'桌号'},
 {id:'created_at',name:'开单时间'},
 {id:'staff',name:'操作员工'},
 {id:'paid_at',name:'付款时间'},
 {id:'payment_method',name:'付款方式'},
 {id:'notes',name:'订单备注'},
 {id:'items',name:'商品与数量明细'},
 {id:'subtotal',name:'商品原价小计'},
 {id:'discount_lines',name:'优惠项目明细'},
 {id:'discount_total',name:'优惠总额'},
 {id:'total',name:'应付 / 实收总额'},
 {id:'balance',name:'实收净额与未结余额'},
 {id:'payment_history',name:'付款与退款记录'},
 {id:'reserved_note',name:'优惠预留说明'},
 {id:'pending_warning',name:'结账审核说明'},
 {id:'footer',name:'底部说明'}
];
const fieldIds=new Set(receiptFields.map(x=>x.id));
const fontSizes=['0','7','8','9','10','11','12','13','14','15','16','18','20','22','24'];
const baseFields=receiptFields.map(x=>x.id);
function blockList(list){
 const ids=receiptBlocks;
 if(!Array.isArray(list)||list.length!==ids.length||ids.some(id=>list.filter(x=>x?.id===id).length!==1))
  return ids.map(id=>({id,visible:true}));
 return list.map(b=>({id:b.id,visible:['items','document','total'].includes(b.id)?true:b.visible!==false}));
}
function defaultsFor(settings={}){
 return baseFields.map((field,index)=>({
  key:'field-'+field,type:'field',field,width:'full',align:'left',font_size:'0',
  bold:['business_name','document','order_no','total'].includes(field),
  visible:field==='table'?settings.show_table!==false:
   field==='staff'?settings.show_staff!==false:
   field==='notes'?settings.show_notes!==false:
   ['discount_lines','discount_total'].includes(field)?settings.show_discounts!==false:true
 }));
}
function legacyElements(blocks,settings){
 const expanded={
  brand:['business_name','subtitle','address_line','contact_line'],
  document:['document'],
  meta:['order_no','table','created_at','staff','paid_at','payment_method','notes'],
  items:['items'],
  discounts:['subtotal','discount_lines','discount_total'],
  total:['total','balance'],
  payments:['payment_history'],
  footer:['reserved_note','pending_warning','footer']
 };
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
 const used=new Set(),out=[];
 for(const [index,raw] of list.slice(0,32).entries()){
  if(!raw||typeof raw!=='object')continue;
  const type=['field','text','divider'].includes(raw.type)?raw.type:null;
  if(!type)continue;
  const field=type==='field'&&fieldIds.has(raw.field)?raw.field:null;
  if(type==='field'&&!field)continue;
  const key=String(raw.key||('element-'+(index+1))).replace(/[^a-zA-Z0-9_-]/g,'').slice(0,48)||('element-'+(index+1));
  let unique=key,n=2;while(used.has(unique))unique=key+'-'+n++;
  used.add(unique);
  out.push({
   key:unique,type,field,
   text:type==='text'?String(raw.text??'').slice(0,240):'',
   width:raw.width==='half'?'half':'full',
   align:['left','center','right'].includes(raw.align)?raw.align:'left',
   font_size:fontSizes.includes(String(raw.font_size))?String(raw.font_size):'0',
   bold:raw.bold===true,
   visible:raw.visible!==false,
   divider:raw.divider==='solid'?'solid':'dashed'
  });
 }
 return out;
}
export const defaultReceiptLayout=(settings={})=>{
 const blocks=receiptBlocks.map(id=>({id,visible:true}));
 const elements=defaultsFor(settings);
 return {blocks,font_size:'11',gap:4,variants:{
  paid:{blocks:blocks.map(x=>({...x})),elements:elements.map(x=>({...x}))},
  unpaid:{blocks:blocks.map(x=>({...x})),elements:elements.map(x=>({...x}))}
 }};
};
export function normalizeReceiptLayout(source,settings={}){
 const defaults=defaultReceiptLayout(settings);
 if(!source||typeof source!=='object')return defaults;
 const out={...defaults,...source};
 out.font_size=fontSizes.includes(String(out.font_size))?String(out.font_size):'11';
 out.gap=[0,2,4,6,8,10,12,16].includes(Number(out.gap))?Number(out.gap):4;
 out.blocks=blockList(source.blocks);
 out.variants={};
 for(const mode of ['paid','unpaid']){
  const sourceVariant=source.variants?.[mode]||{};
  const oldBlocks=blockList(sourceVariant.blocks||source.blocks);
  const fallback=legacyElements(oldBlocks,settings);
  out.variants[mode]={
   blocks:oldBlocks,
   elements:elementsList(sourceVariant.elements,fallback)
  };
 }
 return out;
}
export function applyReceiptLayout(paper,raw,mode='paid',settings={}){
 if(!paper)return;
 const config=normalizeReceiptLayout(raw,settings);
 const elements=config.variants[mode==='unpaid'?'unpaid':'paid'].elements;
 const fieldNodes=new Map([...paper.children].filter(node=>node.dataset?.receiptField).map(node=>[node.dataset.receiptField,node]));
 const canvas=document.createElement('div');
 canvas.className='receipt-layout-canvas';
 canvas.style.display='grid';
 canvas.style.gridTemplateColumns='repeat(2,minmax(0,1fr))';
 canvas.style.columnGap=config.gap+'px';
 canvas.style.rowGap=config.gap+'px';
 const usedFields=new Set();
 for(const item of elements){
  if(item.visible===false)continue;
  const wrapper=document.createElement('div');
  wrapper.className='receipt-layout-element receipt-layout-'+item.width+' receipt-align-'+item.align+(item.bold?' receipt-bold':'');
  wrapper.dataset.elementKey=item.key;
  wrapper.style.gridColumn=item.width==='half'?'span 1':'1 / -1';
  if(item.font_size!=='0')wrapper.style.fontSize=item.font_size+'px';
  let content=null;
  if(item.type==='field'){
   const source=fieldNodes.get(item.field);
   if(!source)continue;
   content=usedFields.has(item.field)?source.cloneNode(true):source;
   usedFields.add(item.field);
  }else if(item.type==='text'){
   content=document.createElement('div');
   content.className='receipt-custom-text';
   content.textContent=item.text;
   content.style.whiteSpace='pre-wrap';
  }else if(item.type==='divider'){
   content=document.createElement('hr');
   content.className='receipt-custom-divider';
   content.dataset.divider=item.divider;
  }
  if(content)wrapper.append(content);
  canvas.append(wrapper);
 }
 paper.replaceChildren(canvas);
 paper.style.fontSize=config.font_size+'px';
 paper.style.lineHeight='1.45';
 return paper;
}
