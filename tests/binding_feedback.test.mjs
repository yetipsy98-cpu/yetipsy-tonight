import {test} from 'node:test';
import assert from 'node:assert/strict';
import {bindingChanges,monitorBinding} from '../play/pos/binding-feedback.mjs';
const snapshot=members=>({capacity:3,members,token_valid:true});
const guest={id:'a',guest:true,name:'访客 A'};
test('only new seats and completed guest-to-member conversion count as binding changes',()=>{
 assert.deepEqual(bindingChanges(snapshot([]),snapshot([])),[]);
 assert.deepEqual(bindingChanges(snapshot([guest]),snapshot([guest])),[]);
 assert.deepEqual(bindingChanges(snapshot([]),snapshot([guest])),[guest]);
 const member={...guest,guest:false,name:'Alice'};
 assert.deepEqual(bindingChanges(snapshot([guest]),snapshot([member])),[member]);
 assert.deepEqual(bindingChanges(snapshot([member]),snapshot([{...member,name:'Alice B'}])),[]);
});
test('monitor serializes reads and ignores responses after the QR closes',async()=>{
 let resolve,calls=0,results=0,open=true;
 const monitor=monitorBinding({initial:snapshot([]),read:()=>{calls++;return new Promise(r=>resolve=r);},onResult:()=>results++,onError:()=>assert.fail('unexpected error'),isOpen:()=>open,schedule:()=>1,cancel(){}});
 const pending=monitor.check();await monitor.check();assert.equal(calls,1);
 open=false;resolve(snapshot([guest]));await pending;assert.equal(results,0);monitor.stop();
});
test('hidden tabs resume, errors retry, and invalid tokens terminate polling',async()=>{
 let callback,hidden=true,reads=0,fail=true,errors=0,results=0;
 const monitor=monitorBinding({initial:snapshot([]),read:async()=>{reads++;if(fail)throw Error('offline');return {...snapshot([guest]),token_valid:false};},
  onResult:()=>results++,onError:()=>errors++,isOpen:()=>true,canRead:()=>!hidden,schedule:fn=>(callback=fn,1),cancel(){callback=null;}});
 await callback();assert.equal(reads,0);assert(callback);
 hidden=false;await callback();assert.equal(errors,1);assert(callback);
 fail=false;await callback();assert.equal(results,1);assert.equal(callback,null);
 await monitor.check();assert.equal(reads,2);monitor.stop();
});
test('a stopped monitor never delivers late successes or errors',async()=>{
 for(const failure of [false,true]){
  let done,events=0;
  const monitor=monitorBinding({initial:snapshot([]),read:()=>new Promise((resolve,reject)=>done=()=>failure?reject(Error('late')):resolve(snapshot([guest]))),
   onResult:()=>events++,onError:()=>events++,isOpen:()=>true,schedule:()=>1,cancel(){}});
  const pending=monitor.check();monitor.stop();done();await pending;assert.equal(events,0);
 }
});
test('missing baseline uses the first recovered snapshot without claiming a new scan',async()=>{
 let changes;
 const monitor=monitorBinding({initial:null,read:async()=>snapshot([guest]),onResult:(_,result)=>changes=result,onError:()=>assert.fail(),isOpen:()=>true,schedule:()=>1,cancel(){}});
 await monitor.check();assert.deepEqual(changes,[]);monitor.stop();
});
