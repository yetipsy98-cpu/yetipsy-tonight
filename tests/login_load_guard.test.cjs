const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const root=path.join(__dirname,'..');

function exercise(file,flag,formIds){
 const html=fs.readFileSync(path.join(root,file),'utf8');
 const scripts=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(match=>match[1]);
 const source=scripts.find(script=>script.includes(flag));
 assert.ok(source,file+' has an early login guard');
 assert.match(html,/rel="modulepreload"/);
 assert.match(html,/202610(?:11-login-v16-4|12-direct-checkout-v16-6|12-bar-hub-v16-7|12-storebox-combo-v16-8|12-storebox-multi-v16-9|12-kds-v17|12-points-rewards-v18|12-bilingual-receipt-v19|12-v22|12-moon-manual-v1|13-mobile-(?:finish-v1|pos-v2|console-v1)|14-(?:storebox-review-v1|staff-checkout-duitnow-v1|kds-line-confirm-template-v1))/);
 const listeners=new Map(),elements=new Map();
 for(const id of formIds)elements.set(id,{addEventListener:(name,fn)=>listeners.set(id+':'+name,fn)});
 elements.set('notice',{textContent:'',classList:{add(){},remove(){}}});
 elements.set('authError',{textContent:''});
 const window={addEventListener(){}};
 vm.runInNewContext(source,{window,document:{getElementById:id=>elements.get(id)}});
 for(const id of formIds){
  window[flag]=false;let prevented=0;listeners.get(id+':submit')({preventDefault(){prevented++;}});assert.equal(prevented,1,file+' cannot refresh before ready');
  window[flag]=true;prevented=0;listeners.get(id+':submit')({preventDefault(){prevented++;}});assert.equal(prevented,0,file+' yields to the real login handler when ready');
 }
}

test('work and customer login forms cannot reload before JavaScript is ready',()=>{
 for(const role of ['pos','owner','staff','cashier'])exercise(`play/${role}/index.html`,'YT_WORK_READY',['signinForm']);
 exercise('play/index.html','YT_CLIENT_READY',['phoneCheckForm','authForm']);
 const work=fs.readFileSync(path.join(root,'play/pos/pos.js'),'utf8');
 const client=fs.readFileSync(path.join(root,'play/app.js'),'utf8');
 assert.ok(work.indexOf("$('signinForm').addEventListener('submit'")<work.indexOf('window.YT_WORK_READY=true'));
 assert.ok(client.indexOf("$('phoneCheckForm').addEventListener('submit'")<client.indexOf('window.YT_CLIENT_READY=true'));
});
