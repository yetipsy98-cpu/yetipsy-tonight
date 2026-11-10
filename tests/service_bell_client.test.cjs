const {test}=require('node:test'),assert=require('node:assert/strict');
test('visitor bell routes only its browser credential; member calls retain existing RPCs',async()=>{
 const {createServiceBellClient}=await import('../play/service-bell-client.mjs');
 const saved=new Map(),storage={getItem:k=>saved.get(k),setItem:(k,v)=>saved.set(k,v)};
 let user=null,made=0;const calls=[],db={rpc:async(name,args)=>{calls.push({name,args});return {data:[]};}};
 const options={db,getUser:()=>user,storage,makeToken:()=>{made++;return '00000000-0000-4000-8000-700000000001';}};
 let client=createServiceBellClient(options);await client.rpc('yt_play_bell_config');assert.equal(saved.size,0);
 await client.rpc('yt_play_bell_list');client=createServiceBellClient(options);
 await client.rpc('yt_play_bell_call',{p_table:'A1',p_type:'help',p_note:'',p_lat:null,p_lng:null});
 await client.rpc('yt_play_bell_cancel',{p_id:'request'});assert.equal(made,1);
 assert.deepEqual(calls.slice(1).map(c=>c.args.p_action),['list','call','cancel']);
 assert(calls.slice(1).every(c=>c.args.p_credential==='00000000-0000-4000-8000-700000000001'));
 assert.equal(calls[2].args.p_data.table,'A1');assert.equal(calls[3].args.p_data.id,'request');
 await assert.rejects(()=>client.rpc('yt_play_bell_ack'),/invalid_bell_request/);
 user={id:'member'};await client.rpc('yt_play_bell_list');assert.equal(calls.at(-1).name,'yt_play_bell_list');
});
test('visitor storage failure stops before submitting a service call',async()=>{
 const {createServiceBellClient}=await import('../play/service-bell-client.mjs');let calls=0;
 const client=createServiceBellClient({db:{rpc:()=>calls++},getUser:()=>null,storage:{getItem:()=>null,setItem:()=>{throw Error('blocked');}}});
 await assert.rejects(()=>client.rpc('yt_play_bell_call'),/guest_storage_unavailable/);assert.equal(calls,0);
});
test('GPS off never requests location, GPS on requests fresh location, and policy errors fail closed',async()=>{
 const {serviceLocation,readLocationPolicy}=await import('../play/location-policy.mjs');let calls=0;
 const old=Object.getOwnPropertyDescriptor(global,'navigator');Object.defineProperty(global,'navigator',{configurable:true,value:{geolocation:{getCurrentPosition:(ok,no,options)=>{calls++;assert.equal(options.maximumAge,0);ok({coords:{latitude:1,longitude:2}});}}}});
 try{
  assert.deepEqual(await serviceLocation(false),{lat:null,lng:null});assert.equal(calls,0);
  assert.deepEqual(await serviceLocation(true),{lat:1,lng:2});assert.equal(calls,1);
  await assert.rejects(()=>readLocationPolicy({rpc:async()=>({error:{message:'offline'}})}),/offline/);
  await assert.rejects(()=>readLocationPolicy({rpc:async()=>({data:{}})}),/location_policy_unavailable/);
  const policy=await readLocationPolicy({rpc:async()=>({data:{bell_gps_required:false,freeflow_gps_required:true}})});assert.equal(policy.bell_gps_required,false);assert.equal(policy.freeflow_gps_required,true);
 }finally{if(old)Object.defineProperty(global,'navigator',old);else delete global.navigator;}
});
