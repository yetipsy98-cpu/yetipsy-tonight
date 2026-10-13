const assert=require('node:assert/strict');
const fs=require('node:fs');
const url=require('node:url');
(async()=>{
 const src=fs.readFileSync('play/pos/moon-code-editor.js','utf8');
 // Import actual browser module in Node; use minimal fake DOM to simulate the Owner drawer.
 const {createMoonCodeEditor}=await import('data:text/javascript;base64,'+Buffer.from(src).toString('base64'));
 function makeRoot(){
  const nodes=new Map();
  const root={
   html:'',
   get innerHTML(){return this.html;},
   set innerHTML(v){
    this.html=v;
    for(const [,id] of v.matchAll(/id="([^"]+)"/g))nodes.set('#'+id,{value:'',textContent:'',innerHTML:'',onclick:null,onsubmit:null,focus(){},classList:{add(){},remove(){}}});
   },
   querySelector(selector){return nodes.get(selector)||null;}
  };
  return root;
 }
 const root=makeRoot(),calls=[];
 const editor=createMoonCodeEditor({db:{async rpc(name){calls.push(name);return{data:[],error:null};}},root,isOwner:()=>true,notice(){}});
 assert.equal(root.querySelector('#moonCodeForm'),null,'panel initially has no Moon form');
 await editor.load();
 assert(root.querySelector('#moonCodeForm'),'load should initialize the form');
 assert(root.querySelector('#moonCodeInput'),'code input should exist');
 assert(root.querySelector('#moonKind'),'reward type selector should exist');
 assert.match(root.querySelector('#moonList').innerHTML,/还没有手动录入/);
 assert.deepEqual(calls,['yt_moon_owner_list']);
 const before=root.innerHTML;
 await editor.load();
 assert.equal(root.innerHTML,before,'refresh must not replace already entered form');
 const errorRoot=makeRoot();
 const failing=createMoonCodeEditor({db:{async rpc(){return{data:null,error:new Error('test failure')};}},root:errorRoot,isOwner:()=>true,notice(){}});
 await assert.rejects(failing.load(),/test failure/);
 assert(errorRoot.querySelector('#moonCodeForm'),'failed RPC must not leave blank screen');
 assert.match(errorRoot.querySelector('#moonList').innerHTML,/暂时无法读取/);
 const consoleCode=fs.readFileSync('play/pos/console.js','utf8');
 const posCode=fs.readFileSync('play/pos/pos.js','utf8');
 assert.match(consoleCode,/moon-code-editor\.js\?v=(?:20261012-moon-manual-v2|20261013-cashier-qr-v1)/);
 assert(posCode.includes('console.js?v=20261013-cashier-qr-v1'));
 for(const page of ['pos','owner','staff','cashier'])assert.match(fs.readFileSync('play/'+page+'/index.html','utf8'),/pos\.js\?v=(?:20261012-moon-manual-v2|20261013-cashier-qr-v1)/);
 console.log('PASS Moon Owner loads form, keeps contents on refresh, shows error state, cache keys updated.');
})().catch(e=>{console.error(e);process.exitCode=1;});
