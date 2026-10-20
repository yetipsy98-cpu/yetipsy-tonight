import {receiptBlocks,receiptFields,normalizeReceiptLayout,applyReceiptLayout} from './receipt-layout.js?v=20261020-receipt-layout-guard-v5';
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fieldName=id=>receiptFields.find(x=>x.id===id)?.name||id;
const clamp=(v,min,max)=>Math.max(min,Math.min(max,Math.round(Number(v)||0)));
const demo=(s={})=>'<div class="receipt-field-node" data-receipt-field="business_name"><div class="receipt-logo">'+esc(s.business_name||'YE·TIPSY')+'</div></div><div class="receipt-field-node" data-receipt-field="subtitle"><div class="receipt-subhead">'+esc(s.subtitle||'KLUANG · POINT OF SALE')+'</div></div><div class="receipt-field-node" data-receipt-field="address_line"><div class="receipt-business-line">'+esc(s.address_line||'12 Jalan Demo, Kluang')+'</div></div><div class="receipt-field-node" data-receipt-field="contact_line"><div class="receipt-business-line">'+esc(s.contact_line||'012-345 6789')+'</div></div><div class="receipt-field-node" data-receipt-field="document"><div class="receipt-document">✓ PAYMENT RECEIPT</div></div><div class="receipt-field-node" data-receipt-field="order_no"><div class="receipt-facts"><p><strong>#YT-1024</strong></p></div></div><div class="receipt-field-node" data-receipt-field="table"><div class="receipt-facts"><p>Table · 08</p></div></div><div class="receipt-field-node" data-receipt-field="created_at"><div class="receipt-facts"><p>Created · Today 20:12</p></div></div><div class="receipt-field-node" data-receipt-field="staff"><div class="receipt-facts"><p>Staff · Alex</p></div></div><div class="receipt-field-node" data-receipt-field="paid_at"><div class="receipt-facts"><p>Paid · Today 20:14</p></div></div><div class="receipt-field-node" data-receipt-field="payment_method"><div class="receipt-facts"><p>Payment Method · DuitNow</p></div></div><div class="receipt-field-node" data-receipt-field="notes"><div class="receipt-facts"><p>Note · Birthday</p></div></div><div class="receipt-field-node" data-receipt-field="items"><div class="receipt-items-head"><span>ITEM</span><span>AMOUNT</span></div><div class="receipt-row"><div><strong>Sparkling Apple</strong><small>2 × RM20.90</small></div><b>RM41.80</b></div></div><div class="receipt-field-node" data-receipt-field="subtotal"><div class="receipt-subtotal"><span>SUBTOTAL</span><b>RM41.80</b></div></div><div class="receipt-field-node" data-receipt-field="discount_lines"><div class="receipt-discount"><div><span>Member Discount</span></div><b>−RM5.00</b></div></div><div class="receipt-field-node" data-receipt-field="discount_total"><div class="receipt-subtotal"><span>DISCOUNT</span><b>−RM5.00</b></div></div><div class="receipt-field-node" data-receipt-field="total"><div class="receipt-sum"><span>TOTAL PAID</span><strong>RM36.80</strong></div></div><div class="receipt-field-node" data-receipt-field="balance"><div class="receipt-subtotal">NET RECEIVED · RM36.80</div></div><div class="receipt-field-node" data-receipt-field="payment_history"><div class="receipt-row"><span>DuitNow · PAYMENT</span><b>RM36.80</b></div></div><div class="receipt-field-node" data-receipt-field="reserved_note"><p class="receipt-hold-note">Discount reserved</p></div><div class="receipt-field-node" data-receipt-field="pending_warning"><p class="receipt-hold-note">Pending review</p></div><div class="receipt-field-node" data-receipt-field="footer"><p class="receipt-bottom">'+esc(s.footer_text||'Thank you for visiting Yetipsy.')+'<br>Store bill · Not a tax invoice</p></div>';
export function createReceiptLayoutEditor({db,root,notice,isOwner,settings}){
 let layout=normalizeReceiptLayout(settings?.layout,settings||{}),mode='paid',saving=false,selectedKey=null,activeDrag=null;
 const current=()=>layout.variants[mode].elements;
 const chosen=()=>current().find(x=>x.key===selectedKey)||null;
 function draw(){
  root.innerHTML='<article class="card receipt-editor receipt-freeform"><p class="kicker">OWNER · RECEIPT DESIGN</p><h2>收据自由画布</h2><p class="muted">在收据上直接拖动元素；拖动右下角可调整大小，点击自定义文字可直接输入。付款方式等字段也可以自由移动。</p>'+
  '<div class="receipt-editor-toolbar"><label>收据版本<select id="layoutMode"><option value="paid">Paid receipt · 已付款</option><option value="unpaid">Unpaid bill · 未付款</option></select></label><button id="layoutReceiptPreviewButton" type="button" class="quiet">预览 Receipt</button></div>'+
  '<details class="receipt-layout-tools"><summary>版面与内容设置</summary><div class="receipt-layout-tool-body"><label>整体字号<select id="layoutFont">'+[7,8,9,10,11,12,13,14,15,16,18,20,22,24].map(n=>'<option value="'+n+'">'+n+' px</option>').join('')+'</select></label><label>画布高度<input id="layoutHeight" type="number" min="400" max="2400" step="20"></label><label>添加字段<select id="layoutAddField"><option value="">选择字段…</option>'+receiptFields.map(f=>'<option value="'+f.id+'">'+esc(f.name)+'</option>').join('')+'</select></label><button type="button" id="layoutAddText">＋添加文字</button><button type="button" id="layoutAddDivider">＋添加分隔线</button><button type="button" id="layoutAutoArrange">自动整理</button></div></details>'+
  '<div class="receipt-freeform-columns"><section class="receipt-canvas-column"><div class="receipt-canvas-heading"><div><h3>收据画布</h3><p class="muted">拖动移动 · 拉右下角调整大小 · 直接点击文字修改</p></div></div><div class="receipt-preview-area"><div id="layoutReceiptPreview"></div></div></section><aside class="receipt-inspector-column"><div id="receiptElementInspector" class="receipt-element-inspector"></div><button id="layoutReceiptSave" type="button" class="main-button">保存收据模板</button><p id="layoutReceiptStatus" role="status"></p></aside></div><div id="receiptPreviewDialog" class="receipt-preview-dialog hidden" role="dialog" aria-modal="true" aria-label="Receipt Preview"></div></article>';
  root.querySelector('#layoutMode').value=mode;root.querySelector('#layoutFont').value=layout.font_size;root.querySelector('#layoutHeight').value=String(layout.canvas_height);
  root.querySelector('#layoutMode').onchange=e=>{mode=e.target.value;selectedKey=null;preview();inspector();};
  root.querySelector('#layoutFont').onchange=e=>{layout.font_size=e.target.value;preview();};
  root.querySelector('#layoutHeight').onchange=e=>{layout.canvas_height=clamp(e.target.value,400,2400);e.target.value=layout.canvas_height;preview();};
  root.querySelector('#layoutAddField').onchange=e=>{const id=e.target.value;if(!id)return;const y=Math.min(2200,Math.max(8,...current().map(x=>x.y+x.h+8)));const n={key:'field-'+id+'-'+Date.now().toString(36),type:'field',field:id,width:'full',align:'left',font_size:'0',x:0,y,w:100,h:34,bold:false,visible:true};current().push(n);selectedKey=n.key;e.target.value='';preview();inspector();};
  root.querySelector('#layoutAddText').onclick=()=>{const n={key:'text-'+Date.now().toString(36),type:'text',text:'点此编辑文字',width:'full',align:'left',font_size:'0',x:4,y:Math.min(2200,current().reduce((m,x)=>Math.max(m,x.y+x.h+8),8)),w:92,h:38,bold:false,visible:true};current().push(n);selectedKey=n.key;preview();inspector();};
  root.querySelector('#layoutAddDivider').onclick=()=>{const n={key:'divider-'+Date.now().toString(36),type:'divider',divider:'dashed',width:'full',align:'left',font_size:'0',x:0,y:Math.min(2200,current().reduce((m,x)=>Math.max(m,x.y+x.h+8),8)),w:100,h:22,bold:false,visible:true};current().push(n);selectedKey=n.key;preview();inspector();};
  root.querySelector('#layoutAutoArrange').onclick=autoArrange;
  root.querySelector('#layoutReceiptSave').onclick=save;root.querySelector('#layoutReceiptPreviewButton').onclick=openPreview;preview();inspector();
 }
 function openPreview(){const host=root.querySelector('#receiptPreviewDialog');if(!host)return;const width=[58,80].includes(Number(settings?.paper_width_mm))?Number(settings.paper_width_mm):80;host.innerHTML='<div class="receipt-preview-backdrop"><section class="receipt-preview-window"><header><strong>Receipt Preview · '+(mode==='paid'?'Paid':'Unpaid')+'</strong><button type="button" data-close-preview aria-label="Close preview">×</button></header><div class="receipt-preview-paper-wrap"><div class="receipt-paper receipt-editor-paper" style="--receipt-width:'+width+'mm">'+demo(settings||{})+'</div></div></section></div>';applyReceiptLayout(host.querySelector('.receipt-paper'),layout,mode,settings||{});host.classList.remove('hidden');host.querySelector('[data-close-preview]').onclick=()=>host.classList.add('hidden');host.onclick=event=>{if(event.target.classList.contains('receipt-preview-backdrop'))host.classList.add('hidden');};}
 function preview(){
  const target=root.querySelector('#layoutReceiptPreview');if(!target)return;
  const s=settings||{},width=[58,80].includes(Number(s.paper_width_mm))?Number(s.paper_width_mm):80;
  target.innerHTML='<div class="receipt-paper receipt-editor-paper" style="--receipt-width:'+width+'mm">'+demo(s)+'</div>';
  const paper=target.querySelector('.receipt-paper');applyReceiptLayout(paper,layout,mode,s);
  const canvas=paper.querySelector('.receipt-layout-canvas');if(!canvas)return;
  canvas.querySelectorAll('[data-element-key]').forEach(el=>{
   const item=current().find(x=>x.key===el.dataset.elementKey);if(!item)return;
   el.tabIndex=0;el.setAttribute('role','button');el.title=item.type==='text'?'点击文字直接编辑，拖动可移动':'拖动可移动，拖动右下角可调整大小';
   el.classList.toggle('is-selected',item.key===selectedKey);
   if(item.type==='text'){
    const textNode=el.querySelector('[data-inline-text]');if(textNode){textNode.contentEditable='true';textNode.spellcheck=false;textNode.addEventListener('input',()=>{item.text=textNode.innerText??textNode.textContent??'';});}
   }
   const handle=document.createElement('button');handle.type='button';handle.className='receipt-resize-handle';handle.dataset.resizeHandle='';handle.setAttribute('aria-label','拖动调整大小');el.append(handle);
  });
  canvas.addEventListener('click',e=>{const el=e.target.closest('[data-element-key]');if(!el)return;selectedKey=el.dataset.elementKey;canvas.querySelectorAll('[data-element-key]').forEach(x=>x.classList.toggle('is-selected',x===el));inspector();});
  canvas.addEventListener('pointerdown',startPointer);canvas.addEventListener('pointermove',movePointer);canvas.addEventListener('pointerup',endPointer);canvas.addEventListener('pointercancel',endPointer);
 }
 function startPointer(e){
  const wrapper=e.target.closest('[data-element-key]');if(!wrapper)return;
  selectedKey=wrapper.dataset.elementKey;const item=chosen();if(!item)return;
  if(e.target.closest('[contenteditable="true"]')&&!e.target.closest('[data-resize-handle]')){inspector();return;}
  e.preventDefault();const canvas=e.currentTarget,rect=canvas.getBoundingClientRect();
  activeDrag={key:item.key,pointer:e.pointerId,x:e.clientX,y:e.clientY,origX:item.x,origY:item.y,origW:item.w,origH:item.h,canvasWidth:rect.width,resize:!!e.target.closest('[data-resize-handle]')};
  canvas.setPointerCapture(e.pointerId);wrapper.classList.add('is-dragging');
 }
 function movePointer(e){
  if(!activeDrag||activeDrag.pointer!==e.pointerId)return;
  const item=current().find(x=>x.key===activeDrag.key),wrapper=e.currentTarget.querySelector('[data-element-key="'+CSS.escape(activeDrag.key)+'"]');if(!item||!wrapper)return;
  const dx=(e.clientX-activeDrag.x)/activeDrag.canvasWidth*100,dy=e.clientY-activeDrag.y;
  if(activeDrag.resize){item.w=clamp(activeDrag.origW+dx,10,100-item.x);item.h=clamp(activeDrag.origH+dy,18,600);wrapper.style.width=item.w+'%';wrapper.style.minHeight=item.h+'px';}
  else{item.x=clamp(activeDrag.origX+dx,0,100-item.w);item.y=clamp(activeDrag.origY+dy,0,2200);wrapper.style.left=item.x+'%';wrapper.style.top=item.y+'px';}
 }
 function endPointer(e){
  if(!activeDrag||activeDrag.pointer!==e.pointerId)return;
  const canvas=e.currentTarget;canvas.querySelector('[data-element-key="'+CSS.escape(activeDrag.key)+'"]')?.classList.remove('is-dragging');
  activeDrag=null;inspector();
 }
 function inspector(){
  const host=root.querySelector('#receiptElementInspector');if(!host)return;
  const item=chosen();if(!item){host.innerHTML='<div class="receipt-inspector-empty"><strong>选择一个元素</strong><p>点画布中的内容后，在这里调整。也可以直接拖动或编辑文字。</p></div>';return;}
  const content=item.type==='field'?'<p class="receipt-selected-name">'+esc(fieldName(item.field))+' <small>动态数据</small></p>':item.type==='text'?'<label>文字内容<textarea id="selectedText" rows="2" maxlength="240">'+esc(item.text)+'</textarea></label>':'<p class="receipt-selected-name">分隔线</p>';
  host.innerHTML='<div class="receipt-inspector-head"><strong>设置 · '+esc(item.type==='field'?fieldName(item.field):item.type==='text'?'自定义文字':'分隔线')+'</strong><button type="button" id="receiptDeleteElement" '+(item.type==='field'&&['document','items','total'].includes(item.field)?'disabled':'')+'>删除</button></div>'+content+
  '<div class="receipt-element-options receipt-element-quick"><label class="checkline"><input type="checkbox" data-prop="visible" '+(item.visible?'checked':'')+'>显示</label><label class="checkline"><input type="checkbox" data-prop="bold" '+(item.bold?'checked':'')+'>加粗</label><label>对齐<select data-prop="align">'+['left','center','right'].map(x=>'<option value="'+x+'" '+(item.align===x?'selected':'')+'>'+({left:'靠左',center:'居中',right:'靠右'}[x])+'</option>').join('')+'</select></label><label>字号<select data-prop="font_size">'+['0',7,8,9,10,11,12,13,14,15,16,18,20,22,24].map(x=>'<option value="'+x+'" '+(String(item.font_size)===String(x)?'selected':'')+'>'+(String(x)==='0'?'跟随整体':x+' px')+'</option>').join('')+'</select></label></div><details class="receipt-advanced-settings"><summary>精细位置与尺寸</summary><div class="receipt-element-options"><label>左侧位置 %<input type="number" min="0" max="90" data-prop="x" value="'+item.x+'"></label><label>上方位置 px<input type="number" min="0" max="2200" data-prop="y" value="'+item.y+'"></label><label>宽度 %<input type="number" min="10" max="100" data-prop="w" value="'+item.w+'"></label><label>高度 px<input type="number" min="18" max="600" data-prop="h" value="'+item.h+'"></label></div></details>';
  host.querySelector('#receiptDeleteElement').onclick=()=>{layout.variants[mode].elements= current().filter(x=>x.key!==item.key);selectedKey=null;preview();inspector();};
  const textArea=host.querySelector('#selectedText');if(textArea)textArea.oninput=()=>{item.text=textArea.value;const n=root.querySelector('[data-inline-text="'+CSS.escape(item.key)+'"]');if(n)n.innerText=item.text;};
  host.querySelectorAll('[data-prop]').forEach(control=>control.addEventListener('change',()=>{item[control.dataset.prop]=control.type==='checkbox'?control.checked:control.type==='number'?Number(control.value):control.value;
   if(control.dataset.prop==='x')item.x=clamp(item.x,0,100-item.w);if(control.dataset.prop==='w')item.w=clamp(item.w,10,100-item.x);if(control.dataset.prop==='y')item.y=clamp(item.y,0,2200);if(control.dataset.prop==='h')item.h=clamp(item.h,18,600);
   preview();inspector();}));
 }
 function autoArrange(){
  let y=8;for(const item of current()){item.x=0;item.y=y;item.w=100;y+=item.h+5;}layout.canvas_height=clamp(y+10,400,2400);
  root.querySelector('#layoutHeight').value=String(layout.canvas_height);preview();inspector();
 }
 async function save(){
  if(saving||!isOwner())return;saving=true;const button=root.querySelector('#layoutReceiptSave'),status=root.querySelector('#layoutReceiptStatus');button.disabled=true;status.textContent='保存中…';
  try{layout.blocks=receiptBlocks.map(id=>({id,visible:true}));const result=await db.rpc('yt_receipt_layout_save',{p_layout:layout});if(result.error)throw result.error;layout=normalizeReceiptLayout(result.data,settings||{});selectedKey=null;preview();inspector();status.textContent='收据模板已保存，之后打开的收据会使用此版式。';notice(status.textContent);}
  catch(e){status.textContent='保存失败：'+(e.message||e);notice(status.textContent,true);}
  finally{saving=false;if(button.isConnected)button.disabled=false;}
 }
 draw();return{preview,setSettings(next){settings={...(settings||{}),...(next||{})};preview();},cancel(){}};
}
