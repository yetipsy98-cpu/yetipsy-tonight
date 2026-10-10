const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const html=fs.readFileSync('play/index.html','utf8'),app=fs.readFileSync('play/app.js','utf8'),moduleSource=fs.readFileSync('play/customer-store-box.js','utf8');

test('customer has one compact Store Box page in the main navigation',()=>{
 assert.match(html,/id="storeboxPage"/);assert.match(html,/id="customerStoreBoxRoot"/);assert.match(html,/data-page="storebox"/);assert.match(html,/20261010-storebox-v16-2/);
 const ids=[...html.matchAll(/id="([^"]+)"/g)].map(match=>match[1]);assert.equal(ids.length,new Set(ids).size);
});

test('Store Box QR is recognized as its own claim type',()=>{
 const context={URL};vm.createContext(context);vm.runInContext(app.slice(app.indexOf('function tokenDetails('),app.indexOf('const requestStore='))+'\nglobalThis.tokenDetails=tokenDetails;',context);
 const token='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 assert.equal(JSON.stringify(context.tokenDetails('https://example.test/play/?box='+token)),JSON.stringify({kind:'box',token}));
 assert.equal(JSON.stringify(context.tokenDetails('box:'+token)),JSON.stringify({kind:'box',token}));
});

test('lost request response reuses the exact original request',()=>{
 const context={};vm.createContext(context);vm.runInContext(moduleSource.replace(/export /g,'')+'\nglobalThis.freezeStoreBoxRequest=freezeStoreBoxRequest;',context);
 const values=new Map(),storage={getItem:key=>values.get(key)||null,setItem:(key,value)=>values.set(key,value),removeItem:key=>values.delete(key)};
 const first=context.freezeStoreBoxRequest(storage,'same',{box:'box',user:'member',quantity:2,table:'T8'},()=> 'request-1');
 const retry=context.freezeStoreBoxRequest(storage,'same',{box:'box',user:'member',quantity:1,table:'T9'},()=> 'request-2');
 assert.equal(JSON.stringify(retry),JSON.stringify(first));assert.equal(retry.request,'request-1');assert.equal(retry.quantity,2);assert.equal(retry.table,'T8');
});

test('customer Store Box uses only protected RPC operations',()=>{
 for(const name of ['yt_store_box_claim_preview','yt_store_box_claim','yt_my_store_boxes','yt_store_box_request','yt_store_box_request_cancel'])assert(moduleSource.includes(`'${name}'`),name);
 assert(moduleSource.includes('p_request:frozen.request'));assert(!moduleSource.includes("db.from('yt_store_boxes')"));
});
