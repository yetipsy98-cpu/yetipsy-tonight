// Selector must be scoped to the mounted Owner drawer. The previous two-argument
// helper was called with one argument, causing mount() to throw before the RPC.
const toNumber=(n,d)=>Number.isFinite(Number(n))?Number(n):d;
export function createLuckyOwner({db,root,notice,isOwner}){
 const $=selector=>root.querySelector(selector);
 let busy=false,loaded=false;
 const fields=['base_points_per_rm','cap_points_per_rm','minimum_spend_rm','claim_minutes'];
 const modes=[['game','GAME · 原有小游戏'],['lucky','LUCKY BOX · 开箱积分'],['off','OFF · 暂停发码']];
 function mount(){
  root.innerHTML='<div class="card stack"><p class="kicker">GAME PASS · REWARD MODE</p><h2>Lucky Box 活动控制</h2>'+
   '<p class="muted">全店统一切换。沿用 GamePass QR，旧 QR 按原规则继续有效。Lucky Box 只抽积分，不需要选择奖品。</p>'+
   '<form id="luckyOwnerForm" class="stack"><label>目前发放模式<select name="mode">'+modes.map(([id,label])=>'<option value="'+id+'">'+label+'</option>').join('')+'</select></label>'+
   '<div class="pair"><label>基础积分 / RM<input name="base_points_per_rm" type="number" min=".1" max="50" step=".1" required></label>'+
   '<label>每 RM 最高积分<input name="cap_points_per_rm" type="number" min=".1" max="100" step=".1" required></label></div>'+
   '<div class="pair"><label>最低合资格消费 RM<input name="minimum_spend_rm" type="number" min="1" max="5000" step=".01" required></label>'+
   '<label>开箱后认领分钟<input name="claim_minutes" type="number" min="3" max="120" step="1" required></label></div>'+
   '<h3>普通开箱概率（合计 100%）</h3><div class="pair">'+['普通','幸运','闪耀','黄金'].map((s,i)=>'<label>'+s+' %<input name="weight'+i+'" type="number" min="0" max="100" step="1" required></label>').join('')+'</div>'+
   '<h3>整单隐藏大奖概率</h3><div class="pair">'+['RM15–49.99','RM50–99.99','RM100–199.99','RM200+'].map((s,i)=>'<label>'+s+' %<input name="hidden'+i+'" type="number" min="0" max="10" step="1" required></label>').join('')+'</div>'+
   '<p class="field-note">建议：1 分≈RM0.01 内部奖品成本；平均预算目标约营业额 2%，单笔上限 5%。更改只影响之后新发出的 GamePass，已有结果永久保留。</p>'+
   '<button type="submit" class="main-button">保存活动模式及概率</button></form>'+
   '<button type="button" id="luckyResetDefaults" class="quiet">恢复 Lucky Box 默认设置（不删除记录）</button>'+
   '<p id="luckyOwnerStatus" role="status" class="field-note">正在读取设置…</p></div>';
  $('#luckyOwnerForm').onsubmit=save;
  $('#luckyResetDefaults').onclick=reset;
 }
 function values(payload){
  const f=$('#luckyOwnerForm');
  f.elements.mode.value=payload.mode;
  for(const k of fields)f.elements[k].value=payload[k];
  (payload.weights||[]).forEach((v,i)=>f.elements['weight'+i].value=v);
  (payload.hidden_probabilities||[]).forEach((v,i)=>f.elements['hidden'+i].value=v);
  $('#luckyOwnerStatus').textContent='当前：'+modes.find(x=>x[0]===payload.mode)?.[1]+
   ' · 配置版本 '+payload.version+' · 已开 '+payload.opened+' 箱 · 已领取 '+payload.claimed+
   ' 箱 / '+payload.points_credited+' 分';
 }
 async function load(){
  if(!isOwner())throw Error('owner_only');
  if(!loaded){mount();loaded=true;}
  const {data,error}=await db.rpc('yt_lucky_owner_settings');if(error){$('#luckyOwnerStatus').textContent='读取失败：'+error.message;throw error;}
  values(data);return data;
 }
 async function save(e){
  e.preventDefault();if(busy)return;
  const f=e.currentTarget, weights=[0,1,2,3].map(i=>Number(f.elements['weight'+i].value));
  const probabilities=[0,1,2,3].map(i=>Number(f.elements['hidden'+i].value));
  if(weights.some(x=>!Number.isInteger(x)||x<0)||weights.reduce((a,b)=>a+b,0)!==100){notice('普通等级概率必须合计 100%',true);return;}
  if(probabilities.some(x=>!Number.isInteger(x)||x<0||x>10)||probabilities.some((n,i)=>i&&n<probabilities[i-1])){notice('隐藏大奖概率应逐阶不下降且不高于 10%',true);return;}
  const config={mode:f.elements.mode.value,weights,hidden_probabilities:probabilities};
  for(const field of fields)config[field]=toNumber(f.elements[field].value,0);
  const button=f.querySelector('[type=submit]');busy=true;button.disabled=true;
  try{
   const {data,error}=await db.rpc('yt_lucky_owner_save',{p_settings:config});
   if(error)throw error;
   values(data);notice('Lucky Box 设置已保存，旧 QR 和历史积分不受影响');
  }catch(e){notice(e.message||'保存失败',true);}
  finally{busy=false;button.disabled=false;}
 }
 async function reset(){
  if(busy)return;
  if(!confirm('确定恢复 Lucky Box 出厂概率、模式与预算？这不会删除已有箱子和积分记录。'))return;
  busy=true;const button=$('#luckyResetDefaults');button.disabled=true;
  try{const {data,error}=await db.rpc('yt_lucky_owner_reset');if(error)throw error;values(data);notice('已恢复默认设置，历史记录保留');}
  catch(e){notice(e.message||'恢复失败',true);}
  finally{button.disabled=false;busy=false;}
 }
 return {load,clear(){loaded=false;root.replaceChildren();}};
}
