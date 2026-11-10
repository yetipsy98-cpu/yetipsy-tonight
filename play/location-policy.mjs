export async function readLocationPolicy(db){
 const {data,error}=await db.rpc('yt_play_location_config');
 if(error)throw Error(error.message);
 if(!data||typeof data.bell_gps_required!=='boolean'||typeof data.freeflow_gps_required!=='boolean')throw Error('location_policy_unavailable');
 return data;
}
export async function serviceLocation(required){
 if(required===false)return {lat:null,lng:null};
 if(!navigator.geolocation)throw Error('location_required');
 const p=await new Promise((resolve,reject)=>navigator.geolocation.getCurrentPosition(resolve,reject,{enableHighAccuracy:true,timeout:12000,maximumAge:0}));
 return {lat:p.coords.latitude,lng:p.coords.longitude};
}
