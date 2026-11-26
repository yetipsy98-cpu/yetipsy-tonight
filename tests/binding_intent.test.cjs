const assert=require('node:assert/strict');
const {readBindingIntent,saveBindingIntent,clearBindingIntent,bindingIntentKey}=require('../play/binding-intent.mjs');
const values=new Map(),storage={getItem:k=>values.get(k)||null,setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)};
const token='00000000-0000-4000-8000-000000000001',other='00000000-0000-4000-8000-000000000002',now=Date.now();
const first=saveBindingIntent(storage,{kind:'freeflow',token,stage:'reserving'},now);saveBindingIntent(storage,{kind:'freeflow',token,stage:'reserved',memberId:'seat'},now+1000);assert.equal(readBindingIntent(storage,now+2000).createdAt,first.createdAt);assert.equal(readBindingIntent(storage).stage,'reserved');
assert.equal(clearBindingIntent(storage,{kind:'bind',token}),false,'one type must not remove another pending link');assert.equal(clearBindingIntent(storage,{kind:'freeflow',token:other}),false,'late completion cannot remove a newer scan');assert.equal(clearBindingIntent(storage,{kind:'freeflow',token}),true);assert.equal(readBindingIntent(storage),null);
saveBindingIntent(storage,{kind:'bind',token},now);assert.equal(readBindingIntent(storage,now+10*24*60*60*1000),null);storage.setItem(bindingIntentKey,'{broken');assert.equal(readBindingIntent(storage),null);assert.throws(()=>saveBindingIntent(storage,{kind:'bind',token:'invalid'}),/binding_intent_invalid/);
assert.throws(()=>saveBindingIntent({getItem:()=>null,setItem(){throw Error('blocked')}},{kind:'freeflow',token}),/binding_storage_unavailable/);
console.log('PASS pending binding survives reload/stage changes, has bounded retention, protects newer scans and checks storage before reserving a seat.');
