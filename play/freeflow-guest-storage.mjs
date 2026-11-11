export const guestStorageKey='yt-freeflow-guest-v1';
export const guestRestoreKey='yt-freeflow-guest-restore-v1';
const valid=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
export const guestImportKey='yt-freeflow-guest-import-v1';
export const guestLifetimeMs=10*24*60*60*1000;
export function clearGuestDevice(storage){for(const key of [guestStorageKey,guestRestoreKey,guestImportKey])try{storage.removeItem(key);}catch{}try{const drafts=globalThis.sessionStorage;for(let i=(drafts?.length||0)-1;i>=0;i--){const key=drafts.key(i);if(key.startsWith('yt-ff-order:freeflow-guest-')||key.startsWith('yt-ff-entry:'))drafts.removeItem(key);}}catch{}}
export function readGuestCredential(storage,now=Date.now()){
 try{let item=JSON.parse(storage.getItem(guestStorageKey)||'null');if(!valid(item?.token))return null;
  if(!Number.isFinite(item.expiresAt)){item={...item,expiresAt:now+guestLifetimeMs};storage.setItem(guestStorageKey,JSON.stringify(item));}
  if(item.expiresAt<=now){clearGuestDevice(storage);return null;}return item.token;
 }catch{return null;}
}
export function saveGuestCredential(storage,token,now=Date.now()){
 if(!valid(token))throw Error('guest_token_invalid');
 try{const old=JSON.parse(storage.getItem(guestStorageKey)||'null');const expiresAt=old?.token===token&&Number.isFinite(old.expiresAt)?old.expiresAt:now+guestLifetimeMs;
  storage.setItem(guestStorageKey,JSON.stringify({token,expiresAt}));if(readGuestCredential(storage,now)!==token)throw Error();
 }catch{throw Error('guest_storage_unavailable');}return token;
}
export function prepareGuestImport(storage){const token=readGuestCredential(storage);if(!token)throw Error('guest_token_invalid');try{storage.setItem(guestImportKey,'1');if(storage.getItem(guestImportKey)!=='1')throw Error();}catch{throw Error('guest_storage_unavailable');}return token;}
export function hasPendingGuestImport(storage){return !!readGuestCredential(storage)&&storage.getItem(guestImportKey)==='1';}
export function ensureGuestCredential(storage,makeToken=()=>crypto.randomUUID()){return readGuestCredential(storage)||saveGuestCredential(storage,makeToken());}
export function prepareGuestRestore(storage,code,makeToken=()=>crypto.randomUUID()){
 if(!valid(code))throw Error('guest_restore_invalid');let pending;try{pending=JSON.parse(storage.getItem(guestRestoreKey)||'null');}catch{}
 if(pending?.code===code&&valid(pending.token)&&pending.expiresAt>Date.now())return pending.token;
 const token=makeToken();if(!valid(token))throw Error('guest_token_invalid');try{storage.setItem(guestRestoreKey,JSON.stringify({code,token,expiresAt:Date.now()+guestLifetimeMs}));const saved=JSON.parse(storage.getItem(guestRestoreKey)||'null');if(saved?.code!==code||saved?.token!==token)throw Error('blocked');}catch{throw Error('guest_storage_unavailable');}return token;
}
export function finishGuestRestore(storage,token){saveGuestCredential(storage,token);try{storage.removeItem(guestRestoreKey);}catch{}}
