const $=id=>document.getElementById(id);
const labels={records:'营业与发放记录',members:'会员账号',catalog:'菜单与系列',campaigns:'活动与奖励设置',team:'其他工作账号',banners:'轮播广告',storebox:'存酒箱与叫酒记录'};
export function createFactoryReset({work,notice,onReset}){
 let challenge=null,running=false;
 const key='yt-owner-reset-cleanup-v9',choices=[...$('factoryChoices').querySelectorAll('[data-reset-scope]')];
 function syncScopes(){const dependent=choices.some(el=>el.checked&&['members','catalog','campaigns','team'].includes(el.dataset.resetScope));if(dependent)$('scopeRecords').checked=true;$('scopeRecords').disabled=running||dependent;$('factoryDependencies').textContent=dependent?'所选范围包含相关营业记录，已自动勾选，避免保留失效引用。':'';}
 function cancel(){if(running)return;challenge=null;$('factoryPrepareForm').reset();$('factoryConfirmForm').reset();$('factoryPrepareForm').classList.remove('hidden');$('factoryConfirmForm').classList.add('hidden');$('factoryScope').replaceChildren();$('factoryStatus').textContent='';syncScopes();}
 function lock(value){running=value;for(const form of [$('factoryPrepareForm'),$('factoryConfirmForm')])for(const el of form.querySelectorAll('input,button'))el.disabled=value;$('toolDrawerClose').disabled=value;syncScopes();}
 function savedJob(){try{const raw=sessionStorage.getItem(key);if(!raw)return null;try{return JSON.parse(raw)}catch{return {challenge:raw}}}catch{return null;}}
 function saveJob(job){try{job?sessionStorage.setItem(key,JSON.stringify(job)):sessionStorage.removeItem(key);}catch{}}
 async function finish(job){
  saveJob(job);$('factoryStatus').textContent='所选数据已清空，正在完成账号及文件清理…';
  let result;do{result=await work('reset_finish',{challenge:job.challenge},true);$('factoryStatus').textContent=result.complete?'重置完成':'正在清理：剩余 '+result.remaining+' 项';}while(!result.complete);
  saveJob(null);await onReset(result.scopes||job.scopes||[]);
 }
 async function resume(){lock(true);try{const job=savedJob()||await work('reset_status',{},true);if(!job?.challenge)return;await finish(job);}catch(e){$('factoryStatus').textContent='清理未完成，请重新打开系统重置继续。';notice(e.message||'清理暂时失败',true);}finally{lock(false);}}
 $('factoryChoices').onchange=syncScopes;
 $('factorySelectAll').onclick=()=>{const common=choices.filter(el=>el.dataset.resetScope!=='storebox');const all=common.every(el=>el.checked);for(const el of common)el.checked=!all;syncScopes();};
 $('factoryPrepareForm').onsubmit=async e=>{
  e.preventDefault();if(running)return;syncScopes();const scopes=choices.filter(el=>el.checked).map(el=>el.dataset.resetScope);if(!scopes.length){notice('请先选择清空范围',true);return;}lock(true);$('factoryStatus').textContent='正在验证…';
  const password=$('factoryPassword1').value;$('factoryPassword1').value='';
  try{const res=await work('reset_prepare',{password,scopes,request:crypto.randomUUID()},true);challenge=res.challenge;
   const scope=$('factoryScope');scope.replaceChildren();const title=document.createElement('strong');title.textContent='即将清空：'+(res.scopes||[]).map(x=>labels[x]||x).join('、');scope.append(title);
   for(const [label,count] of Object.entries(res.counts||{})){const row=document.createElement('p');row.textContent=label+'：'+count;scope.append(row);}
   const expiry=document.createElement('p');expiry.textContent='范围已锁定，5 分钟内有效。当前 Owner 与内置游戏保留。';scope.append(expiry);
   $('factoryPrepareForm').classList.add('hidden');$('factoryConfirmForm').classList.remove('hidden');$('factoryStatus').textContent='核对上述范围后，输入第二次密码确认。';
  }catch(e){const msg=({storebox_member_reset_blocked:'存酒箱仍关联会员；如需删除会员，必须独立勾选并清空存酒箱。',invalid_credentials:'密码不正确',reset_cleanup_pending:'上次重置清理未完成，请先恢复',reset_verification_failed:'登录验证服务暂时失败',too_many_attempts:'重试次数过多，请稍后再试',invalid_reset_scope:'所选范围无效'}[e.message]||e.message||'重置预检失败');notice(msg,true);$('factoryStatus').textContent='未清空任何记录：'+msg;}finally{lock(false);if(challenge)$('factoryPassword2').focus();}
 };
 $('factoryConfirmForm').onsubmit=async e=>{
  e.preventDefault();if(running||!challenge||!$('factoryConsent').checked)return;lock(true);$('factoryStatus').textContent='正在验证第二次密码…';
  const password=$('factoryPassword2').value;$('factoryPassword2').value='';
  try{const res=await work('reset_confirm',{password,challenge},true);const job={challenge:res.challenge,scopes:res.scopes};saveJob(job);await finish(job);}
  catch(e){
   const raw=e?.message||'server_unavailable';
   const translations={reset_database_error:'数据库未能完成重置，本次没有清空资料；请检查错误日志。',reset_confirmation_expired:'本次确认已超过 5 分钟，请重新选择范围并验证密码。',reset_cleanup_pending:'上一次重置尚有清理工作，请先恢复。',invalid_credentials:'第二次输入的 Owner 密码不正确。',storebox_member_reset_blocked:'还有存酒箱关联会员，不能仅清空会员。',too_many_attempts:'密码尝试次数过多，请稍后重试。',reset_verification_failed:'密码验证服务异常，请稍后重试。',server_unavailable:'服务器暂时无法执行重置，尚未确认完成。'};
   const message=translations[raw]||raw;
   notice(message,true);
   const pendingCleanup=!!savedJob();
   $('factoryStatus').textContent=pendingCleanup?'业务重置已提交，但文件／账号清理未完成；重新打开可继续。': '第二次确认失败：'+message;
   if(raw==='reset_confirmation_expired'){challenge=null;$('factoryPrepareForm').classList.remove('hidden');$('factoryConfirmForm').classList.add('hidden');$('factoryConfirmForm').reset();}
  }finally{lock(false);}
 };
 $('factoryCancel').onclick=cancel;syncScopes();
 return {cancel,resume,get busy(){return running;}};
}
