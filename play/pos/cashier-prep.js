const escape=value=>String(value??'').replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;','\'':'&#39;'}[ch]));
const number=v=>Number.isFinite(Number(v))?Number(v):0;
function parts(item){return Array.isArray(item.available)?item.available:[];}
export function renderCheckoutPrep(root,quote){
 const items=quote?.items||[];
 root.classList.toggle('hidden',!items.length||!quote?.can_prepare);
 if(!items.length||!quote?.can_prepare){root.replaceChildren();return;}
 root.innerHTML='<div class="cashier-prep-head"><strong>PACKAGE / CHALLENGE · CASHIER 预出杯</strong><small>Cashier 预先安排出酒，收款后直接进入吧台 KDS；不再要求顾客扫码先点酒。</small></div>'+
 items.map(item=>{
  const id=escape(item.item_id),cs=parts(item),challenge=item.mode==='challenge';
  const controls=challenge?
   '<label>本次固定出 1 杯 · 选择内容<select data-prep-challenge="'+id+'">'+cs.filter(x=>number(x.quantity)>0).map(x=>'<option value="'+escape(x.key)+'">'+escape(x.name)+'</option>').join('')+'</select></label>':
   '<div class="cashier-prep-components">'+cs.map(x=>'<label>'+escape(x.name)+' · 共 '+number(x.quantity)+' 杯<input type="number" inputmode="numeric" min="0" max="'+Math.min(99,number(x.quantity))+'" value="0" data-prep-item="'+id+'" data-prep-key="'+escape(x.key)+'"></label>').join('')+'</div>';
  return '<div class="cashier-prep-item" data-prep-box="'+id+'"><div class="cashier-prep-title"><strong>'+escape(item.name)+'</strong><span>'+ (challenge?'挑战 · 每次限 1 杯':'Package · 可选择先出数量')+' · '+number(item.capacity)+' 杯</span></div>'+controls+'</div>';
 }).join('')+'<p class="field-note">首批出品只计入一次 KDS；余下数量留在 Cashier 存酒管理。只有确认已收款才正式发出。</p>';
}
export function readCheckoutPrep(root,quote){
 const items=quote?.items||[],preps=[];
 for(const item of items){
  const partsList=parts(item),choices=[];
  if(item.mode==='challenge'){
   const chosen=root.querySelector('[data-prep-challenge="'+item.item_id+'"]');
   const key=chosen?.value||partsList[0]?.key;
   if(!partsList.some(x=>x.key===key&&number(x.quantity)>=1))throw Error('挑战必须选择且只能出一杯');
   choices.push({key,quantity:1});
  }else{
   for(const p of partsList){
    const field=[...root.querySelectorAll('input[data-prep-item]')].find(x=>x.dataset.prepItem===item.item_id&&x.dataset.prepKey===p.key);
    const raw=field?.value??'0';if(!/^\d{1,2}$/.test(raw))throw Error('Package 出杯数量必须是整数');
    const qty=Number(raw);if(qty>number(p.quantity))throw Error('先出数量不能超过该饮品剩余杯数');
    if(qty>0)choices.push({key:p.key,quantity:qty});
   }
   if(choices.reduce((sum,x)=>sum+x.quantity,0)>99)throw Error('每次最多处理 99 杯，请分批处理');
  }
  preps.push({item_id:item.item_id,selections:choices});
 }
 return preps;
}
export function cashierBoxControls(box){
 if(!box?.cashier_managed||box.customer_id||box.active_request_id||number(box.remaining_units)<=0||!['unclaimed','active'].includes(box.status))return '';
 const partsList=(box.components||[]).map(x=>({key:x.key,name:x.name,remaining:Math.max(0,number(x.total_units)-number(x.served_units))})).filter(x=>x.remaining>0);
 const id=escape(box.id),challenge=box.mode==='challenge';
 if(!partsList.length)return '';
 return '<div class="storebox-cashier-direct" data-box-serve-form="'+id+'"><strong>Cashier 直接叫酒 · 剩余 '+number(box.remaining_units)+' 杯</strong>'+
 (challenge?'<label>挑战每次只能出 1 杯<select data-box-serve-choice>'+partsList.map(x=>'<option value="'+escape(x.key)+'">'+escape(x.name)+'</option>').join('')+'</select></label>':
 partsList.map(x=>'<label>'+escape(x.name)+'（余 '+x.remaining+'）<input type="number" inputmode="numeric" min="0" max="'+Math.min(99,x.remaining)+'" value="0" data-box-serve-key="'+escape(x.key)+'"></label>').join(''))+
 '<button type="button" class="primary" data-box-cashier-serve="'+id+'">发送到吧台 KDS</button></div>';
}
export function readCashierBoxRequest(root,box){
 const partsList=(box.components||[]).map(x=>({key:x.key,remaining:Math.max(0,number(x.total_units)-number(x.served_units))}));
 if(box.mode==='challenge'){
  const key=root.querySelector('[data-box-serve-choice]')?.value;
  if(!partsList.some(x=>x.key===key&&x.remaining>0))throw Error('挑战只能选择一杯可用饮品');
  return [{key,quantity:1}];
 }
 const choices=[];
 for(const part of partsList){
  const el=[...root.querySelectorAll('[data-box-serve-key]')].find(x=>x.dataset.boxServeKey===part.key);
  const raw=el?.value||'0';if(!/^\d{1,2}$/.test(raw))throw Error('出杯数量必须为整数');
  const qty=Number(raw);if(qty>part.remaining)throw Error('出杯数量超过剩余余额');
  if(qty>0)choices.push({key:part.key,quantity:qty});
 }
 const total=choices.reduce((s,x)=>s+x.quantity,0);
 if(total<1||total>99)throw Error('请选择 1–99 杯出品');
 return choices;
}
