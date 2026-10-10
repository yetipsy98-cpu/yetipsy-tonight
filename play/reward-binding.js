const unwrap=r=>{if(r.error)throw Error(r.error.message);return r.data||[];};
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const isBoundReward=r=>r.active&&['product','series','any_drink'].includes(r.mode);
export function createRewardBindingEditor({db,root}){
 let rules=[],products=[],series=[],retry=null;
 root.classList.add('reward-binding-editor');
 root.innerHTML='<h4>兑奖权益 <small>必选</small></h4><label>权益来源<select data-bind="source"><option value="new">设置新权益</option><option value="existing">沿用现有权益</option></select></label><label data-wrap="template" hidden>选择现有权益<select data-bind="template"><option value="">请选择</option></select></label><div data-wrap="manual"><label>适用范围<select data-bind="mode"><option value="product">指定商品</option><option value="series">指定系列任一款</option><option value="any_drink">任意饮品抵扣</option></select></label><label data-wrap="product">商品<select data-bind="product"><option value="">请选择</option></select></label><label data-wrap="series" hidden>系列<select data-bind="series"><option value="">请选择</option></select></label><label>抵扣方式<select data-bind="type"><option value="free">免费一杯</option><option value="fixed">固定金额 RM</option><option value="percent">百分比折扣 %</option></select></label><label data-wrap="value" hidden>抵扣金额／百分比<input data-bind="value" type="number" min="0.01" max="5000" step="0.01" value="5"></label><div class="binding-pair"><label>至少付费饮品<input data-bind="minimum" type="number" min="1" max="20" value="1" step="1"></label><label>最低净消费 RM<input data-bind="spend" type="number" min="0" max="10000" step="0.01" value="0"></label></div></div><p data-bind="summary" class="binding-note"></p>';
 const field=k=>root.querySelector('[data-bind="'+k+'"]');
 const wrap=k=>root.querySelector('[data-wrap="'+k+'"]');
 function update(){
  const existing=field('source').value==='existing',mode=field('mode').value;
  wrap('template').hidden=!existing;wrap('manual').hidden=existing;
  wrap('product').hidden=mode!=='product';wrap('series').hidden=mode!=='series';
  field('type').options[0].disabled=mode==='any_drink';
  if(mode==='any_drink'&&field('type').value==='free')field('type').value='fixed';
  wrap('value').hidden=field('type').value==='free';
  field('value').max=field('type').value==='percent'?'100':'5000';
  const r=rules.find(r=>r.reward_id===field('template').value);
  field('summary').textContent=existing&&r?describeRule(r):'';
 }
 function describeRule(r){const scope=r.mode==='product'?products.find(p=>p.id===r.product_id)?.name||'指定商品':r.mode==='series'?series.find(s=>s.id===r.series_id)?.name||'指定系列':'任意饮品';return scope+' · '+(r.discount_type==='fixed'?'抵扣 RM'+r.discount_value:r.discount_type==='percent'?r.discount_value+'% 折扣':'免费一杯')+' · 至少 '+(r.min_paid_drinks??1)+' 杯付费饮品'+(Number(r.min_spend_rm)>0?' · 净消费 RM'+r.min_spend_rm:'');}
 for(const k of ['source','mode','type','template'])field(k).onchange=update;
 function options(k,rows,id,label){const el=field(k),old=el.value;el.innerHTML='<option value="">请选择</option>'+rows.map(r=>'<option value="'+esc(id(r))+'">'+esc(label(r))+'</option>').join('');if(rows.some(r=>id(r)===old))el.value=old;}
 async function load(){const results=await Promise.all([db.rpc('yt_pos_owner_reward_rules'),db.rpc('yt_pos_catalog'),db.rpc('yt_pos_series_catalog')]);rules=unwrap(results[0]);products=unwrap(results[1]);series=unwrap(results[2]);options('template',rules.filter(isBoundReward),r=>r.reward_id,r=>r.reward_name+' · '+describeRule(r));options('product',products.filter(p=>p.active),p=>p.id,p=>p.name+' · RM'+Number(p.price_rm).toFixed(2));options('series',series.filter(s=>s.active),s=>s.id,s=>s.name);update();return rules;}
 function binding(){
  if(field('source').value==='existing'){const id=field('template').value;if(!rules.some(r=>r.reward_id===id&&isBoundReward(r)))throw Error('请选择已绑定的现有权益');return {template_reward_id:id};}
  const mode=field('mode').value,type=field('type').value,product=field('product').value,serie=field('series').value;
  const value=type==='free'?0:Number(field('value').value),minimum=Number(field('minimum').value),spend=Number(field('spend').value);
  if(mode==='product'&&!product||mode==='series'&&!serie)throw Error('请选择权益对应的商品或系列');
  if(!Number.isInteger(minimum)||minimum<1||minimum>20||!Number.isFinite(spend)||spend<0||spend>10000)throw Error('至少保留一杯付费饮品，并填写有效最低消费');
  if(type!=='free'&&(!Number.isFinite(value)||value<=0||value>(type==='percent'?100:5000)))throw Error('请填写有效抵扣金额或百分比');
  return {mode,product_id:mode==='product'?product:null,series_id:mode==='series'?serie:null,discount_type:type,discount_value:value,min_paid_drinks:minimum,min_spend_rm:spend};
 }
 async function create(args){
  const reward={name:args.p_name,description:args.p_description,category:args.p_category,validity_days:args.p_validity,next_day_only:args.p_next_day,use_from:args.p_use_from,use_until:args.p_use_until,daily_from:args.p_daily_from,daily_until:args.p_daily_until},bound=binding();
  const key=JSON.stringify([reward,bound]);if(retry?.key!==key)retry={key,request:crypto.randomUUID()};
  const result=await db.rpc('yt_owner_create_bound_reward_v6',{p_reward:reward,p_binding:bound,p_request:retry.request});
  return unwrap(result);
 }
 update();return {load,create,rules:()=>rules,reset(){retry=null;field('source').value='new';field('template').value='';field('mode').value='product';field('product').value='';field('series').value='';field('type').value='free';field('value').value=5;field('minimum').value=1;field('spend').value=0;update();}};
}
