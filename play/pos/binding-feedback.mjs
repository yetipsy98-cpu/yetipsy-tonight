// One monitor belongs to one visible QR host. Never broadcasts POS notices.
export function bindingChanges(previous, current) {
 const before=new Map(previous.members.map(m=>[m.id,m]));
 return current.members.filter(m=>!before.has(m.id)||before.get(m.id).guest&&!m.guest);
}
export function monitorBinding({read,initial,onResult,onError,isOpen,canRead=()=>true,interval=2500,schedule=setTimeout,cancel=clearTimeout}) {
 let stopped=false,pending=false,timer=null,previous=initial;
 const stop=()=>{stopped=true;cancel(timer);timer=null;};
 const check=async()=>{
  if(stopped||pending)return;
  cancel(timer);timer=null;
  if(!isOpen()){stop();return;}
  if(!canRead()){timer=schedule(check,interval);return;}
  pending=true;
  try {
   const current=await read();
   if(stopped||!isOpen())return;
   if(!current||!Array.isArray(current.members))throw Error('Invalid binding status');
   const changes=previous?bindingChanges(previous,current):[];previous=current;onResult(current,changes);
   if(current.token_valid===false)stop();
  } catch(error) {if(!stopped&&isOpen())onError(error);}
  finally {pending=false;if(!stopped){if(isOpen())timer=schedule(check,interval);else stop();}}
 };
 timer=schedule(check,interval);
 return {check,stop};
}
