// One read at a time. Requests arriving during a read get one trailing read.
// Callers share the drain promise, including that trailing read.
export function createRefreshGate(read,{merge=(_prior,next)=>next}={}){
 let running=null,dirty=false,args=[];
 function request(...next){args=dirty?merge(args,next):next;dirty=true;if(!running){running=new Promise((resolve,reject)=>{queueMicrotask(async()=>{let result,error;while(dirty){const batch=args;dirty=false;args=[];try{result=await read(...batch);error=null;}catch(e){error=e;}}running=null;if(error)reject(error);else resolve(result);});});}return running;}
 function clear(){dirty=false;args=[];}

 return {request,clear};
}

// Private database broadcasts only invalidate a scope. Data still comes from its
// existing authorised RPC, never from the notification payload.
export function createWorkspaceLiveRefresh({db,readers,isActive=()=>true,isVisible=()=>!document.hidden,delay=200,retryDelay=5000}){
 let generation=0,channels=[],timer=null,retry=null,active=false;
 const dirty=new Set();
 const available=()=>active&&isActive();
 function flush(){timer=null;if(!available()||!isVisible())return;const scopes=[...dirty];dirty.clear();for(const scope of scopes)Promise.resolve().then(()=>{if(available())return readers[scope]?.();}).catch(error=>console.warn('Live refresh:',scope,error?.message||error));}
 function signal(scope){if(!Object.hasOwn(readers,scope))return;dirty.add(scope);if(available()&&isVisible()&&!timer)timer=setTimeout(flush,delay);}
 function resume(){if(!available())return;for(const scope of Object.keys(readers))signal(scope);}
 function stop(){generation++;active=false;clearTimeout(timer);clearTimeout(retry);timer=retry=null;dirty.clear();const old=channels;channels=[];for(const channel of old)try{Promise.resolve(db.removeChannel(channel)).catch(()=>{});}catch{}}
 function start(){stop();if(!db?.channel||!isActive())return;active=true;const epoch=generation;for(const scope of Object.keys(readers)){
  try{const channel=db.channel('yt-work-'+scope,{config:{private:true}});channels.push(channel);channel.on('broadcast',{event:'changed'},()=>{if(epoch===generation&&available())signal(scope);}).subscribe(status=>{if(epoch!==generation||!available())return;if(status==='SUBSCRIBED'){signal(scope);}else if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(status)&&!retry){retry=setTimeout(()=>{retry=null;if(epoch===generation&&available())start();},retryDelay);}});}catch(error){console.warn('Live connection:',error?.message||error);if(!retry)retry=setTimeout(()=>{retry=null;if(epoch===generation&&available())start();},retryDelay);}
 }return channels.length;}
 return {start,stop,resume,signal};
}
