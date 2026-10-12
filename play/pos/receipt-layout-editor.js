
import {receiptBlocks,normalizeReceiptLayout,applyReceiptLayout} from './receipt-layout.js?v=20261012-v22';
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const names={brand:'Logo、店名和地址',document:'付款状态 / 单据类型',meta:'订单号、桌号、时间与员工',items:'商品及数量明细',discounts:'小计与折扣明细',total:'应付总额与余额',payments:'付款历史',footer:'感谢词与法律说明'};
export function createReceiptLayoutEditor({db,root,notice,isOwner,settings}){
 let layout=normalizeReceiptLayout(settings?.layout),mode='paid',saving=false;
 const modeBlocks=()=>layout.variants[mode].blocks;
 function draw(){
  root.innerHTML='<article class="card receipt-editor"><p class="kicker">OWNER · RECEIPT DESIGN</p><h2>自由排版与打印</h2><p class="muted">未付款账单与已付款收据可分别排序。必需的商品、金额和凭证类型不可隐藏。</p>'+
  '<label>编辑模板<select id="layoutMode"><option value="paid">已付款收据</option><option value="unpaid">未付款账单</option></select></label>'+
  '<div class="pair"><label>字体大小<select id="layoutFont">'+[9,10,11,12,13,14].map(n=>'<option value="'+n+'">'+n+' px</option>').join('')+'</select></label>'+
  '<label>模块间距<select id="layoutGap">'+[0,2,4,6,8,10,12,16].map(n=>'<option value="'+n+'">'+n+' px</option>').join('')+'</select></label></div>'+
  '<div id="layoutReceiptBlocks"></div><button id="layoutReceiptSave" type="button" class="main-button">保存排版并应用所有设备</button><p id="layoutReceiptStatus" role="status"></p></article>'+
  '<article class="card receipt-preview-card"><p class="kicker">实际打印结构预览</p><div id="layoutReceiptPreview" class="receipt-preview-area"></div></article>';
  root.querySelector('#layoutMode').value=mode;
  root.querySelector('#layoutMode').onchange=e=>{mode=e.target.value;blocks();preview();};
  root.querySelector('#layoutFont').value=layout.font_size;
  root.querySelector('#layoutGap').value=String(layout.gap);
  root.querySelector('#layoutFont').onchange=e=>{layout.font_size=e.target.value;preview();};
  root.querySelector('#layoutGap').onchange=e=>{layout.gap=Number(e.target.value);preview();};
  root.querySelector('#layoutReceiptSave').onclick=save;
  blocks();preview();
 }
 function blocks(){
  const parent=root.querySelector('#layoutReceiptBlocks');
  parent.innerHTML=modeBlocks().map((b,i)=>{
   const required=['items','document','total'].includes(b.id);
   return '<div class="receipt-design-row" data-key="'+b.id+'"><label class="checkline">'+
     '<input type="checkbox" data-visible="'+b.id+'" '+(b.visible?'checked':'')+(required?' disabled':'')+'><span>'+names[b.id]+'</span></label>'+
     '<div><button type="button" data-shift="'+b.id+'" data-dir="-1" '+(i===0?'disabled':'')+'>↑</button>'+
     '<button type="button" data-shift="'+b.id+'" data-dir="1" '+(i===7?'disabled':'')+'>↓</button></div></div>';
  }).join('');
  parent.onchange=e=>{const id=e.target.dataset.visible;if(id){modeBlocks().find(b=>b.id===id).visible=e.target.checked;preview();}};
  parent.onclick=e=>{const btn=e.target.closest('[data-shift]');if(!btn)return;
   const i=modeBlocks().findIndex(b=>b.id===btn.dataset.shift),j=i+Number(btn.dataset.dir);
   if(j<0||j>=modeBlocks().length)return;
   [modeBlocks()[i],modeBlocks()[j]]=[modeBlocks()[j],modeBlocks()[i]];
   blocks();preview();
  };
 }
 function preview(){
  const el=root.querySelector('#layoutReceiptPreview');if(!el)return;
  const s=settings||{},paid=mode==='paid';
  const title=esc(s.business_name||'YE·TIPSY'),subtitle=esc(s.subtitle||'KLUANG · POINT OF SALE');
  const footer=esc(s.footer_text||'Thank you for visiting Yetipsy.');
  el.innerHTML='<div class="receipt-paper" style="--receipt-width:'+([58,80].includes(Number(s.paper_width_mm))?Number(s.paper_width_mm):80)+'mm">'+
    '<div class="receipt-logo">'+title+'</div><div class="receipt-subhead">'+subtitle+'</div>'+
    '<div class="receipt-document">'+(paid?'✓ 已收款 · PAYMENT RECEIPT':'尚未结账 · UNPAID BILL')+'</div>'+
    '<div class="receipt-facts"><p><strong>#YT-1024</strong></p><p>桌号 · Table 08</p><p>Created · Today</p></div>'+
    '<div class="receipt-items-head"><span>商品 / ITEM</span><span>AMOUNT</span></div>'+
    '<div class="receipt-row"><div><strong>Cocktail</strong><small>2 × RM20.00</small></div><b>RM40.00</b></div>'+
    '<div class="receipt-subtotal"><span>SUBTOTAL</span><b>RM40.00</b></div>'+
    '<div class="receipt-discount"><span>Voucher Discount</span><b>−RM5.00</b></div>'+
    '<div class="receipt-sum"><span>'+(paid?'TOTAL PAID':'AMOUNT DUE')+'</span><strong>RM35.00</strong></div>'+
    '<div class="receipt-payments"><small>'+(paid?'PAID · CASH':'AWAITING PAYMENT')+'</small></div>'+
    '<p class="receipt-bottom">'+footer+'</p></div>';
  applyReceiptLayout(el.querySelector('.receipt-paper'),layout,mode);
 }
 async function save(){
  if(saving||!isOwner())return;saving=true;const button=root.querySelector('#layoutReceiptSave');
  const status=root.querySelector('#layoutReceiptStatus');
  button.disabled=true;status.textContent='保存中…';
  try{
   layout.blocks=layout.variants.paid.blocks.map(b=>({...b}));
   const result=await db.rpc('yt_receipt_layout_save',{p_layout:layout});
   if(result.error)throw result.error;
   layout=normalizeReceiptLayout(result.data);status.textContent='排版已保存。之后打开的账单自动采用新格式。';notice(status.textContent);
  }catch(e){status.textContent='保存失败：'+(e.message||e);notice(status.textContent,true);}
  finally{saving=false;button.disabled=false;}
 }
 draw();
 return{preview};
}
