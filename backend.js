window.YTBackend=(()=>{
  // Paste your deployed Google Apps Script /exec URL here. Leave blank for local demo mode.
  const API_URL='';
  const enabled=()=>API_URL.startsWith('https://script.google.com/');
  async function call(action,data={}){
    if(!enabled()) return {ok:false,demo:true};
    try{
      const r=await fetch(API_URL,{method:'POST',headers:{'Content-Type':'text/plain;charset=utf-8'},body:JSON.stringify({action,...data})});
      return await r.json();
    }catch(e){return {ok:false,error:String(e)}}
  }
  function session(){let id=localStorage.getItem('yt_session');if(!id){id=(crypto.randomUUID?crypto.randomUUID():Date.now()+'-'+Math.random());localStorage.setItem('yt_session',id)}return id}
  return {
    enabled,
    join:(mode)=>call('join',{session:session(),mode}),
    heartbeat:()=>call('heartbeat',{session:session()}),
    status:()=>call('status',{session:session()}),
    wall:()=>call('wall'),
    postWall:(message)=>call('postWall',{session:session(),message}),
    event:()=>call('event'),
    session
  }
})();
