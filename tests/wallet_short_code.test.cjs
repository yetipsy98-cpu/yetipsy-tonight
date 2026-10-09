const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../play/app.js'),'utf8');
const functions=source.slice(source.indexOf('async function showCodeSheet('),source.indexOf('function tokenDetails('));
const elements={};let clock=Date.now(),tick,markup,copied,request,qrFails=false;
function element(){return {textContent:'',disabled:false,isConnected:true,style:{},flags:new Set(),classList:{add(v){this.owner.flags.add(v);},owner:null},setAttribute(){},after(e){this.afterButton=e;}};}
function setup(){for(const id of ['sheetToken','sheetCopy','sheetCountdown','sheetQR','sheetBarcode']){const el=element();el.classList.owner=el;elements[id]=el;}}
const context={URL,Date:class extends Date{static now(){return clock;}},$:(id)=>elements[id],esc:s=>s,
 showSheet:()=>setup(),sheetHtml:s=>{markup=s;},qrcode:async()=>{if(qrFails)throw Error('offline');},barcode:async()=>{},toast(){},copy:s=>{copied=s;},millis:s=>Date.parse(s),setInterval:f=>{tick=f;return 1;},clearInterval(){},uuid:()=> 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',unpack:r=>r.data,newLink:(key,t)=>'https://example.test/play/?'+key+'='+t,pending:(_,f)=>f(),document:{createElement:()=>element()},db:{rpc:async(name,args)=>{request={name,args};return {data:{display_code:'7K3M-9X2P',expires_at:new Date(clock+60000).toISOString()}};}}};
vm.createContext(context);vm.runInContext(functions+'\nglobalThis.test={showRewardQR,showCodeSheet};',context);
(async()=>{
 await context.test.showRewardQR({id:'award',rewards:{name:'RM5'}});
 assert.equal(request.name,'yt_make_redeem_v5');assert.equal(request.args.p_award,'award');
 assert.equal(elements.sheetToken.textContent,'7K3M-9X2P');assert(elements.sheetToken.flags.has('redeem-short-code'));assert(!markup.includes('https://'));
 elements.sheetCopy.onclick();assert.equal(copied,'7K3M-9X2P');assert.match(elements.sheetCountdown.textContent,/二维码与兑换码/);
 clock+=61000;tick();assert(elements.sheetCopy.disabled);assert(elements.sheetToken.flags.has('code-expired'));
 assert.equal(elements.sheetCountdown.afterButton.textContent,'重新生成兑换码');await elements.sheetCountdown.afterButton.onclick();assert.equal(elements.sheetCopy.disabled,false);
 qrFails=true;await context.test.showRewardQR({id:'award'});assert.equal(elements.sheetToken.textContent,'7K3M-9X2P');elements.sheetCopy.onclick();assert.equal(copied,'7K3M-9X2P');
 qrFails=false;const link='https://example.test/play/?gift=test';await context.test.showCodeSheet('Gift','claim',link,false);elements.sheetCopy.onclick();assert.equal(copied,link);
 console.log('PASS: Wallet short-code issuance, visible and copied code, expiry, regeneration, QR failure fallback and existing gift link behavior.');
})().catch(e=>{console.error(e);process.exitCode=1;});
