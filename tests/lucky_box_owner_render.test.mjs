import assert from 'node:assert/strict';
import fs from 'node:fs';
const source=fs.readFileSync('play/pos/lucky-box-owner.js','utf8');
const {createLuckyOwner}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
const defaults={mode:'game',base_points_per_rm:3.5,cap_points_per_rm:10,minimum_spend_rm:15,claim_minutes:20,
 weights:[15,55,25,5],hidden_probabilities:[1,2,3,5],version:1,opened:0,claimed:0,points_credited:0};
function fakeRoot(){
 let content='',nodes={};
 const form={elements:{},querySelector(s){return s==='[type=submit]'?{disabled:false}:null}};
 return {
  get innerHTML(){return content;},
  set innerHTML(html){content=html; nodes={
   '#luckyOwnerForm':form,
   '#luckyResetDefaults':{disabled:false,onclick:null},
   '#luckyOwnerStatus':{textContent:''},'#luckyOwnerBudgetReport':{textContent:''}
  };
  for(const match of html.matchAll(/name="([^"]+)"/g))form.elements[match[1]]={value:''};
  },
  querySelector(sel){return nodes[sel]||null;},
  replaceChildren(){this.innerHTML='';},
 };
}
{
 const root=fakeRoot(),calls=[];
 const db={async rpc(name,args){
  calls.push({name,args});
  if(name==='yt_lucky_owner_save')return {data:{...defaults,...args.p_settings,version:2},error:null};
  if(name==='yt_lucky_owner_reset')return {data:defaults,error:null};
  return {data:defaults,error:null};
 }};
 const alerts=[];
 const editor=createLuckyOwner({root,db,isOwner:()=>true,notice:(s)=>alerts.push(s)});
 await editor.load();
 assert.deepEqual(calls.map(x=>x.name),['yt_lucky_owner_settings'],'settings RPC must run after mounting');
 const form=root.querySelector('#luckyOwnerForm');
 assert.equal(typeof form.onsubmit,'function','save handler bound');
 assert.equal(typeof root.querySelector('#luckyResetDefaults').onclick,'function','reset handler bound');
 assert.equal(form.elements.mode.value,'game');
 assert.equal(form.elements.base_points_per_rm.value,3.5);
 assert.equal(form.elements['weight2'].value,25);
 assert.equal(form.elements['hidden3'].value,5);
 assert.match(root.querySelector('#luckyOwnerStatus').textContent,/配置版本 1/);
 form.elements.mode.value='lucky';
 await form.onsubmit({preventDefault(){},currentTarget:form});
 assert.equal(calls[1].name,'yt_lucky_owner_save');
 assert.equal(calls[1].args.p_settings.mode,'lucky');
 assert.deepEqual(calls[1].args.p_settings.weights,[15,55,25,5]);
 const before=root.innerHTML;
 await editor.load();
 assert.equal(root.innerHTML,before,'reload must not wipe form');
 globalThis.confirm=()=>true;
 await root.querySelector('#luckyResetDefaults').onclick();
 assert.equal(calls.at(-1).name,'yt_lucky_owner_reset');
 assert.equal(form.elements.mode.value,'game');
 assert.equal(form.elements.cap_points_per_rm.value,10);
}
{
 const root=fakeRoot(),failure=createLuckyOwner({root,db:{async rpc(){return{error:new Error('simulated network error')}}},isOwner:()=>true,notice(){}});
 await assert.rejects(failure.load(),/simulated network error/);
 assert(root.querySelector('#luckyOwnerForm'),'failed RPC should still render a form');
 assert.match(root.querySelector('#luckyOwnerStatus').textContent,/读取失败/);
}
console.log('PASS Lucky Box Owner mounts controls, loads live settings, saves, resets, reopens, and exposes RPC errors.');
