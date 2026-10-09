const $=id=>document.getElementById(id);
export function createFactoryReset({work,notice,onReset}){
 let challenge=null,running=false;
 const key='yt-owner-reset-cleanup-v7';
 function cancel(){if(running)return;challenge=null;$('factoryPrepareForm').reset();$('factoryConfirmForm').reset();$('factoryPrepareForm').classList.remove('hidden');$('factoryConfirmForm').classList.add('hidden');$('factoryScope').replaceChildren();$('factoryStatus').textContent='';}
 function lock(value){running=value;for(const form of [$('factoryPrepareForm'),$('factoryConfirmForm')])for(const el of form.querySelectorAll('input,button'))el.disabled=value;$('toolDrawerClose').disabled=value;}
 function savedJob(){try{return sessionStorage.getItem(key);}catch{return null;}}
 function saveJob(job){try{job?sessionStorage.setItem(key,job):sessionStorage.removeItem(key);}catch{}}
 async function finish(job){
  saveJob(job);$('factoryStatus').textContent='业务数据已清空，正在移除旧账号和广告文件…';
  let result;do{result=await work('reset_finish',{challenge:job},true);$('factoryStatus').textContent=result.complete?'重置完成':'正在清理：剩余 '+result.remaining+' 项';}while(!result.complete);
  saveJob(null);await onReset();
 }
 async function resume(){lock(true);try{const job=savedJob()||(await work('reset_status',{},true)).challenge;if(!job)return;await finish(job);}catch(e){$('factoryStatus').textContent='清理未完成，请重新打开系统重置继续。';notice(e.message||'清理暂时失败',true);}finally{lock(false);}}
 $('factoryPrepareForm').onsubmit=async e=>{
  e.preventDefault();if(running)return;lock(true);$('factoryStatus').textContent='正在验证…';
  const password=$('factoryPassword1').value;$('factoryPassword1').value='';
  try{const res=await work('reset_prepare',{password,request:crypto.randomUUID()},true);challenge=res.challenge;
   const scope=$('factoryScope');scope.replaceChildren();const title=document.createElement('strong');title.textContent='即将清空';scope.append(title);
   for(const [label,count] of Object.entries(res.counts||{})){const row=document.createElement('p');row.textContent=label+'：'+count;scope.append(row);}
   const expiry=document.createElement('p');expiry.textContent='本次确认 5 分钟内有效。仅保留当前 Owner 与内置游戏。';scope.append(expiry);
   $('factoryPrepareForm').classList.add('hidden');$('factoryConfirmForm').classList.remove('hidden');$('factoryStatus').textContent='请输入第二次密码确认。';
  }catch(e){notice(e.message||'密码验证失败',true);$('factoryStatus').textContent='验证失败，尚未清空任何记录。';}finally{lock(false);if(challenge)$('factoryPassword2').focus();}
 };
 $('factoryConfirmForm').onsubmit=async e=>{
  e.preventDefault();if(running||!challenge||!$('factoryConsent').checked)return;lock(true);$('factoryStatus').textContent='正在验证第二次密码…';
  const password=$('factoryPassword2').value;$('factoryPassword2').value='';
  try{const res=await work('reset_confirm',{password,challenge},true);saveJob(res.challenge);await finish(res.challenge);}
  catch(e){notice(e.message||'重置未完成，请重试',true);$('factoryStatus').textContent=savedJob()?'业务记录已清空，重新打开此抽屉可继续清理旧账号及广告。':'未收到完成结果。请重试第二次确认；同一次确认不会重复清空。';}finally{lock(false);}
 };
 $('factoryCancel').onclick=cancel;
 return {cancel,resume,get busy(){return running;}};
}
