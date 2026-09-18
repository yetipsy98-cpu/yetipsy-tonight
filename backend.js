window.YTBackend=(()=>{
 const API_URL="https://script.google.com/macros/s/AKfycbzCFtnhDubjakfhj3fbdDKa7hUZ0eJV6GCfc62TqQkwWETfTkvcglbip1sYxcuI4hqlNg/exec";
 const configured=()=>API_URL.startsWith("https://");
 async function post(action,data={}){
   if(!configured())return {ok:false,offline:true};
   try{
     const r=await fetch(API_URL,{method:"POST",headers:{"Content-Type":"text/plain;charset=utf-8"},body:JSON.stringify({action,...data})});
     return await r.json();
   }catch(e){return {ok:false,error:String(e)}}
 }
 return{
   configured,
   join:(p)=>post("join",p),
   status:(p)=>post("status",p),
   queue:(p)=>post("queue",p),
   matchStatus:(p)=>post("matchStatus",p),
   verify:(p)=>post("verify",p),
   complete:(p)=>post("complete",p),
   heartbeat:(p)=>post("heartbeat",p)
 };
})();
