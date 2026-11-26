const {JSDOM}=require('jsdom'),assert=require('node:assert/strict');
(async()=>{
 const dom=new JSDOM('<div id="work"></div>',{url:'https://example.test/play/',pretendToBeVisual:true});
 for(const k of ['window','document','FormData','sessionStorage'])global[k]=dom.window[k];
 let members=[],fail=false,valid=true,statusReads=0,defer=null;const notices=[];
 const expiry=new Date(Date.now()+300000).toISOString();
 const db={rpc:async(name,args)=>{
  if(name==='yt_freeflow_binding_status'){
   statusReads++;if(defer)return new Promise(r=>defer=r);
   if(fail)return {error:{message:'offline'}};
   assert.equal(args.p_session,'group-a');return {data:{id:'group-a',capacity:3,token_valid:valid,members:structuredClone(members)}};
  }
  if(args.p_action==='order_binding')return {data:{standalone:true,capacity:3,order_no:'YT001',sessions:[{id:'group-a',capacity:3,name:'Glass'}]}};
  if(args.p_action==='token')return {data:{token:'qr-token',expires_at:expiry}};
  throw Error(name+':'+args.p_action);
 }};
 const {createFreeflowWork}=await import('../play/pos/freeflow.js');
 const tool=createFreeflowWork({db,isOwner:()=>true,isCashier:()=>true,getBusinessDay:()=>'',qrLibrary:async()=>false,notice:(...args)=>notices.push(args),onQueueChange(){},onNewOrder(){}});
 const q=s=>document.querySelector(s),wait=async f=>{for(let i=0;i<150;i++){if(f())return;await new Promise(r=>setTimeout(r,2));}assert.fail('timeout');};
 assert.equal(statusReads,0);await tool.openOrderBinding('order-a');assert.equal(statusReads,0,'merely opening the group page does not start status checks');
 q('[data-group-code]').click();await wait(()=>q('[data-bind-check]'));
 assert.match(q('[data-bind-title]').textContent,/等待/);assert.match(q('[data-bind-count]').textContent,/0 \/ 3/);
 q('[data-bind-check]').click();await wait(()=>statusReads===2);await new Promise(r=>setTimeout(r,0));assert.match(q('[data-bind-title]').textContent,/等待/,'opening a customer page is not binding success');
 members=[{id:'guest-a',guest:true,name:'访客 <A>',status:'active'}];q('[data-bind-check]').click();await wait(()=>q('[data-bind-title]').textContent.includes('访客资格已绑定'));
 assert.equal(q('[data-bind-members] a'),null);assert.match(q('[data-bind-count]').textContent,/1 \/ 3/);
 members=[{id:'guest-a',guest:false,name:'Alice',status:'active'}];q('[data-bind-check]').click();await wait(()=>q('[data-bind-title]').textContent==='会员已绑定：Alice');
 members.push({id:'member-b',guest:false,name:'Bob',status:'active'});q('[data-bind-check]').click();await wait(()=>q('[data-bind-title]').textContent==='会员已绑定：Bob');assert.match(q('[data-bind-count]').textContent,/2 \/ 3/);
 fail=true;q('[data-bind-check]').click();await wait(()=>q('.ff-bind-feedback').classList.contains('is-error'));assert.match(q('[data-bind-detail]').textContent,/连接暂时中断/);
 fail=false;valid=false;q('[data-bind-check]').click();await wait(()=>q('[data-bind-check]').disabled);assert.match(q('#ffCodeTime').textContent,/失效/);assert.equal(q('#ffCopyLink').disabled,true);
 valid=true;q('#ffRotateCode').click();await wait(()=>q('[data-bind-check]')&&!q('[data-bind-check]').disabled);assert.match(q('[data-bind-title]').textContent,/等待/,'existing members are a baseline, not a fresh scan confirmation');
 defer=true;q('[data-bind-check]').click();await wait(()=>typeof defer==='function');const resolve=defer;
 q('#ffBindingClose').click();await wait(()=>!q('.ff-bind-feedback'));resolve({data:{id:'group-a',capacity:3,members:[],token_valid:true}});await new Promise(r=>setTimeout(r,10));assert.equal(q('.ff-bind-feedback'),null);
 assert.deepEqual(notices,[],'feedback never broadcasts a notice to other POS workspaces');
 tool.clear();dom.window.close();console.log('PASS QR-only feedback: idle until QR opens, guest/member distinction, group count, escaped names, network retry, invalidation, rotation baseline, close ignores late replies, no global notices.');
})().catch(e=>{console.error(e);process.exit(1);});
