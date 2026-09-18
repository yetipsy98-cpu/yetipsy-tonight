window.YTAudio=(()=>{
 let settings=JSON.parse(localStorage.getItem("yt_audio_v2")||'{"voice":true,"sfx":true,"vibration":true}');
 let ctx=null;
 function save(){localStorage.setItem("yt_audio_v2",JSON.stringify(settings))}
 function ensure(){try{ctx=ctx||new(window.AudioContext||window.webkitAudioContext)();if(ctx.state==="suspended")ctx.resume()}catch(e){}}
 function tone(freq=240,d=.08,g=.035,type="sine"){if(!settings.sfx)return;ensure();if(!ctx)return;let o=ctx.createOscillator(),a=ctx.createGain();o.type=type;o.frequency.value=freq;a.gain.setValueAtTime(g,ctx.currentTime);a.gain.exponentialRampToValueAtTime(.0001,ctx.currentTime+d);o.connect(a).connect(ctx.destination);o.start();o.stop(ctx.currentTime+d)}
 function impact(){tone(95,.18,.07,"sine");setTimeout(()=>tone(190,.08,.025,"triangle"),30);vibrate([35,25,60])}
 function tap(){tone(420,.035,.018,"sine")}
 function vibrate(p){if(settings.vibration&&navigator.vibrate)navigator.vibrate(p)}
 function speak(word){
   if(!settings.voice || !("speechSynthesis" in window))return Promise.resolve(false);
   return new Promise(resolve=>{
     try{
       speechSynthesis.cancel();
       let u=new SpeechSynthesisUtterance(word);
       u.lang="en-US";u.rate=.78;u.pitch=.82;u.volume=1;
       let voices=speechSynthesis.getVoices();
       let preferred=voices.find(v=>/en-US/i.test(v.lang)&&/Samantha|Daniel|Google|Microsoft|English/i.test(v.name))||voices.find(v=>/^en/i.test(v.lang));
       if(preferred)u.voice=preferred;
       u.onend=()=>resolve(true);u.onerror=()=>resolve(false);
       speechSynthesis.speak(u);
     }catch(e){resolve(false)}
   });
 }
 async function countWord(word){
   let ok=await speak(word);
   if(!ok&&settings.sfx){tone(word==="THREE"?270:word==="TWO"?300:word==="ONE"?340:190,.13,.05,"triangle")}
   vibrate(word==="POINT"?[45,30,90]:25);
 }
 return{
  ensure,tap,impact,countWord,
  get:()=>({...settings}),
  set:(k,v)=>{settings[k]=!!v;save()},
  allOn:()=>{settings={voice:true,sfx:true,vibration:true};save();ensure()},
  quiet:()=>{settings={voice:false,sfx:false,vibration:false};save()}
 };
})();