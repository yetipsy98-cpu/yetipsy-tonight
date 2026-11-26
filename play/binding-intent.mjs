// Only a pending public QR/link, never a login token or PIN. Server eligibility
// remains authoritative; keeping this intent does not extend QR validity.
export const bindingIntentKey='yt-client-binding-intent-v1';
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const lifetime=10*24*60*60*1000;
export function readBindingIntent(storage,now=Date.now()){
 try{const value=JSON.parse(storage.getItem(bindingIntentKey)||'null');if(!value)return null;
 if(!['bind','freeflow'].includes(value.kind)||!uuid.test(value.token)||!Number.isFinite(value.createdAt)||value.createdAt>now+60000||now-value.createdAt>=lifetime){storage.removeItem(bindingIntentKey);return null;}return value;}catch{return null;}
}
export function saveBindingIntent(storage,intent,now=Date.now()){
 if(!['bind','freeflow'].includes(intent.kind)||!uuid.test(intent.token))throw Error('binding_intent_invalid');
 const old=readBindingIntent(storage,now),same=old?.kind===intent.kind&&old.token===intent.token;
 const value={...(same?old:{}),...intent,createdAt:same?old.createdAt:now};
 try{storage.setItem(bindingIntentKey,JSON.stringify(value));if(storage.getItem(bindingIntentKey)!==JSON.stringify(value))throw Error();}catch{throw Error('binding_storage_unavailable');}return value;
}
export function clearBindingIntent(storage,intent){
 const value=readBindingIntent(storage);if(!value||value.kind!==intent.kind||value.token!==intent.token)return false;
 try{storage.removeItem(bindingIntentKey);return true;}catch{return false;}
}
