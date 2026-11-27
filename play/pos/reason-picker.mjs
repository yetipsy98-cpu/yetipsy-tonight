export const reasonOptions={
 cancel:['酒款缺货','顾客更换饮品','重复下单','顾客取消','数量录入错误'],
 edit:['顾客更换饮品','数量录入错误','酒款缺货调整','商品录入错误','付款方式更正','营业日期更正','顾客取消订单'],
 discount:['活动优惠','会员优惠','服务补偿','Owner 招待','现场议定优惠'],
 reject:['资料不完整','金额不一致','重复申请','未符合活动条件','请核对后重新提交'],
 payment:['付款截图不清晰','金额不一致','未收到款项','重复付款记录','付款方式错误'],
 time:['出品延误补时','设备或网络问题','现场服务补偿','延长营业时间','原有效时间录入错误'],
 code:['重新发码','重新分配','顾客更换','重复发放','原码不再使用'],
 points:['积分补发','活动奖励','服务补偿','重复积分更正','积分录入错误'],
 reward:['活动奖励补发','顾客申请兑换','服务补偿','重复发放更正','奖励有效期调整'],
 closing:['补录遗漏订单','收款记录更正','退款记录更正','核对后修正报表','已现场核对'],
 append:['顾客追加商品','遗漏商品补录','数量不足补录','现场核对补单'],
 refund:['顾客取消退款','重复收款退回','服务补偿退款','核对后保留奖励','退款撤回关联奖励']
};
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function style(doc){if(doc.getElementById('reasonPickerStyle'))return;const el=doc.createElement('style');el.id='reasonPickerStyle';el.textContent='.reason-choices{display:flex;gap:7px;flex-wrap:wrap;margin:9px 0}.reason-choices button{font:inherit;font-size:12px!important;padding:8px 11px!important;min-height:34px;border:1px solid #b8a27566;border-radius:9px;background:#25362b;color:#e5d7b7;cursor:pointer}.reason-choices button[aria-pressed=true]{background:#ddc28a;color:#17251d;border-color:#ddc28a}.reason-choices button:disabled{opacity:.4;cursor:default}.reason-picker-overlay{position:fixed;inset:0;z-index:10000;background:#030a07b8;display:grid;place-items:center;padding:20px}.reason-picker-card{box-sizing:border-box;width:min(480px,100%);max-height:90dvh;overflow:auto;padding:23px;background:#192b21;color:#eee8d7;border:1px solid #bba36d77;border-radius:20px;box-shadow:0 24px 80px #0006}.reason-picker-card h3{font-size:22px;margin:0 0 14px}.reason-picker-card textarea{box-sizing:border-box;width:100%;padding:12px;font:inherit;font-size:16px;background:#101e16;color:#eee8d7;border:1px solid #71805c;border-radius:10px;resize:vertical}.reason-picker-card footer{display:flex;justify-content:flex-end;gap:10px;margin-top:18px}.reason-picker-card footer button{font:inherit;padding:11px 18px;border:1px solid #9b8e66;border-radius:10px;color:#efe6ce;background:#253b2d}.reason-picker-card footer button[type=submit]{background:#ddc28a;color:#17251d}.reason-picker-error{color:#edb296;font-size:13px}.reason-picker-card small{display:block;font-size:12px;color:#aab6a1;margin-top:7px}';doc.head.append(el);}
export function reasonKind(text){
 if(/缺货|取消.*杯|取消.*出品/.test(text))return 'cancel';
 if(/延时|有效时间|更改原因/.test(text))return 'time';
 if(/回填|拒绝|审批/.test(text))return 'reject';
 if(/积分/.test(text))return 'points';
 if(/退款|退回/.test(text))return 'refund';
 if(/奖励/.test(text))return 'reward';
 if(/二维码|领取码|发码|分配/.test(text))return 'code';
 if(/优惠|FOC|Discount|manualAdjustment/i.test(text))return 'discount';
 if(/closing|重新打开|批准原因|超过72/i.test(text))return 'closing';
 if(/append|加单/.test(text))return 'append';
 if(/修改|改单|editReason/.test(text))return 'edit';
 return 'cancel';
}
export function attachReasonChoices(field,kind='cancel'){
 if(!field||field.dataset.reasonChoices)return;style(field.ownerDocument);field.dataset.reasonChoices='true';
 const box=field.ownerDocument.createElement('span');box.className='reason-choices';box.setAttribute('role','group');box.setAttribute('aria-label','常见原因');
 const choices=reasonOptions[kind]||reasonOptions.cancel;
 box.innerHTML=[...choices,'其他'].map(v=>`<button type="button" data-reason-value="${esc(v)}" aria-pressed="false">${esc(v)}</button>`).join('');field.before(box);
 const sync=()=>box.querySelectorAll('button').forEach(b=>{const disabled=field.disabled||field.readOnly;if(b.disabled!==disabled)b.disabled=disabled;const selected=b.dataset.reasonValue===field.value.trim();if(b.getAttribute('aria-pressed')!==String(selected))b.setAttribute('aria-pressed',String(selected));});
 box.onclick=e=>{const b=e.target.closest('button');if(!b||field.disabled||field.readOnly)return;e.preventDefault();e.stopPropagation();field.value=b.dataset.reasonValue==='其他'?'':b.dataset.reasonValue;field.dispatchEvent(new field.ownerDocument.defaultView.Event('input',{bubbles:true}));field.dispatchEvent(new field.ownerDocument.defaultView.Event('change',{bubbles:true}));if(b.dataset.reasonValue==='其他')field.focus();sync();};
 field.addEventListener('input',sync);sync();return sync;
}
export function mountReasonChoices(root=document){
 const syncs=new Map();let queued=false;
 const scan=()=>{queued=false;for(const [f,sync] of syncs){if(!f.isConnected)syncs.delete(f);else sync();}
  root.querySelectorAll('textarea,input:not([type]),input[type=text]').forEach(f=>{const label=f.closest('label');const text=[f.id,f.name,f.hasAttribute('data-reopen-reason')?'重新打开':'',label?.textContent].join(' ');if(!/reason|原因/i.test(text)||f.dataset.reasonChoices)return;const context=f.closest('form')?.querySelector('h3,h4')?.textContent||'';syncs.set(f,attachReasonChoices(f,reasonKind(text+' '+context)));});};
 scan();const doc=root.ownerDocument||root;const observer=new doc.defaultView.MutationObserver(()=>{if(!queued){queued=true;queueMicrotask(scan);}});
 observer.observe(root,{childList:true,subtree:true,attributes:true,attributeFilter:['disabled','readonly','class','hidden']});
 return {scan,clear(){observer.disconnect();syncs.clear();}};
}
export function askReason({title='选择操作原因',kind='cancel',initial='',min=2,optional=false}={}){
 const doc=document;style(doc);const focus=doc.activeElement;
 return new Promise(resolve=>{const overlay=doc.createElement('section');overlay.className='reason-picker-overlay';overlay.setAttribute('role','dialog');overlay.setAttribute('aria-modal','true');overlay.setAttribute('aria-labelledby','reasonPickerTitle');overlay.innerHTML=`<form class="reason-picker-card"><h3 id="reasonPickerTitle">${esc(title)}</h3><textarea name="reason" rows="2" maxlength="300" placeholder="选择常见原因，或填写其他说明">${esc(initial)}</textarea><small>选择常见原因即可；也可以补充说明。</small><p class="reason-picker-error" role="alert"></p><footer><button type="button" data-reason-close>返回</button><button type="submit">确认</button></footer></form>`;
  const siblings=[...doc.body.children].map(el=>({el,inert:el.inert}));siblings.forEach(({el})=>el.inert=true);doc.body.append(overlay);
  const finish=value=>{overlay.remove();siblings.forEach(({el,inert})=>el.inert=inert);doc.removeEventListener('keydown',key,true);focus?.isConnected&&focus.focus({preventScroll:true});resolve(value);};
  const field=overlay.querySelector('textarea');attachReasonChoices(field,kind);overlay.querySelector('[data-reason-close]').onclick=()=>finish(null);
  overlay.onclick=e=>{if(e.target===overlay)finish(null);};
  const key=e=>{if(e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();finish(null);}else if(e.key==='Tab'){const items=[...overlay.querySelectorAll('button,textarea')].filter(x=>!x.disabled),first=items[0],last=items.at(-1);if(e.shiftKey&&doc.activeElement===first){e.preventDefault();last.focus();}else if(!e.shiftKey&&doc.activeElement===last){e.preventDefault();first.focus();}}};doc.addEventListener('keydown',key,true);
  overlay.querySelector('form').onsubmit=e=>{e.preventDefault();const value=field.value.trim();if((!optional||value)&&value.length<min){overlay.querySelector('[role=alert]').textContent=`请填写至少 ${min} 个字的原因。`;field.focus();return;}finish(value);};overlay.querySelector('.reason-choices button').focus();
 });
}
