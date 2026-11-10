const {JSDOM}=require('jsdom'),assert=require('node:assert/strict');
(async()=>{
 const dom=new JSDOM('<div id="dashboard"><div class="intro"></div><section id="tab-orders"></section></div><div id="playBellSettingsRoot"></div>');global.window=dom.window;global.document=dom.window.document;
 const map={setView(){return this;},on(){return this;},invalidateSize(){}};window.L={map:()=>map,tileLayer:()=>({addTo(){}}),circle:()=>({addTo(){return this;},setLatLng(){},setRadius(){}}),marker:()=>({addTo(){return this;},on(){return this;}})};
 let settings={bell_lat:null,bell_lng:null,bell_radius_m:100,bell_complete_seconds:30,bell_remind_seconds:30,bell_gps_required:true,freeflow_gps_required:false,types:[]};const writes=[],notices=[];
 const db={rpc:async(name,args)=>{if(name==='yt_pos_refresh_schedule')return {data:{enabled:false}};assert.equal(name,'yt_play_bell_settings');if(args.p_data){writes.push(args.p_data);settings={...settings,...args.p_data};}return {data:settings};}};
 const {createPlayWork}=await import('../play/pos/play-upgrade.js');const work=createPlayWork({db,isOwner:()=>true,isCashier:()=>false,notice:(m,b)=>notices.push({m,b})});work.mount();
 const wait=async fn=>{for(let i=0;i<100;i++){if(fn())return;await new Promise(r=>setTimeout(r,5));}assert.fail('Settings did not update');};await wait(()=>document.getElementById('playBellGpsRequired').checked);
 assert.equal(document.getElementById('playFreeflowGpsRequired').checked,false);
 document.getElementById('playBellGpsRequired').checked=false;document.getElementById('playSettingsSave').click();await wait(()=>writes.length===1);assert.equal(writes[0].bell_gps_required,false);assert.equal(writes[0].freeflow_gps_required,false);assert.equal(writes[0].bell_lat,null);
 document.getElementById('playFreeflowGpsRequired').checked=true;document.getElementById('playSettingsSave').click();await wait(()=>notices.some(n=>n.b));assert.equal(writes.length,1);
 document.getElementById('playBellLat').value='1.5';document.getElementById('playBellLng').value='103.5';document.getElementById('playSettingsSave').click();await wait(()=>writes.length===2);assert.equal(writes[1].freeflow_gps_required,true);assert.equal(writes[1].bell_gps_required,false);
 dom.window.close();console.log('PASS Owner GPS switches load independently, save both-off without a center, and require a center when either policy is enabled.');
})().catch(e=>{console.error(e);process.exit(1);});
