export const guestStorageKey='yt-freeflow-guest-v1';
export const guestRestoreKey='yt-freeflow-guest-restore-v1';
const valid=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
export function readGuestCredential(storage){try{const item=JSON.parse(storage.getItem(guestStorageKey)||'null');return valid(item?.token)?item.token:null;}catch{return null;}}
export function saveGuestCredential(storage,token){if(!valid(token))throw Error('guest_token_invalid');try{storage.setItem(guestStorageKey,JSON.stringify({token}));if(readGuestCredential(storage)!==token)throw Error();}catch{throw Error('guest_storage_unavailable');}return token;}
export function ensureGuestCredential(storage,makeToken=()=>crypto.randomUUID()){return readGuestCredential(storage)||saveGuestCredential(storage,makeToken());}
export function prepareGuestRestore(storage,code,makeToken=()=>crypto.randomUUID()){
 if(!valid(code))throw Error('guest_restore_invalid');let pending;try{pending=JSON.parse(storage.getItem(guestRestoreKey)||'null');}catch{}
 if(pending?.code===code&&valid(pending.token))return pending.token;
 const token=makeToken();if(!valid(token))throw Error('guest_token_invalid');try{storage.setItem(guestRestoreKey,JSON.stringify({code,token}));const saved=JSON.parse(storage.getItem(guestRestoreKey)||'null');if(saved?.code!==code||saved?.token!==token)throw Error('blocked');}catch{throw Error('guest_storage_unavailable');}return token;
}
export function finishGuestRestore(storage,token){saveGuestCredential(storage,token);try{storage.removeItem(guestRestoreKey);}catch{}}
