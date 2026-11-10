const key='yt-service-bell-guest-v1';
const valid=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
export function createServiceBellClient({db,getUser,storage=localStorage,makeToken=()=>crypto.randomUUID()}){
 function credential(){try{let token=storage.getItem(key);if(!valid(token)){token=makeToken();if(!valid(token))throw Error();storage.setItem(key,token);if(storage.getItem(key)!==token)throw Error();}return token;}catch{throw Error('guest_storage_unavailable');}}
 async function rpc(name,args={}){
  if(name==='yt_play_bell_config'||getUser())return db.rpc(name,args);
  const action={yt_play_bell_list:'list',yt_play_bell_call:'call',yt_play_bell_cancel:'cancel'}[name];
  if(!action)throw Error('invalid_bell_request');
  const data=action==='call'?{table:args.p_table,type:args.p_type,note:args.p_note,lat:args.p_lat,lng:args.p_lng}:action==='cancel'?{id:args.p_id}:{};
  return db.rpc('yt_play_bell_guest',{p_action:action,p_credential:credential(),p_data:data});
 }
 return {rpc};
}
