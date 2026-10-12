const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const html=fs.readFileSync('play/index.html','utf8'),app=fs.readFileSync('play/app.js','utf8'),moduleSource=fs.readFileSync('play/customer-store-box.js','utf8');

test('customer has one compact Store Box page in the main navigation',()=>{
 assert.match(html,/id="storeboxPage"/);assert.match(html,/id="customerStoreBoxRoot"/);assert.match(html,/data-page="storebox"/);assert.match(html,/20261012-bilingual-receipt-v19/);
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
 const first=context.freezeStoreBoxRequest(storage,'same',{box:'box',user:'member',selections:[{key:'c1',quantity:1},{key:'c2',quantity:1}],quantity:2,table:'T8'},()=> 'request-1');
 const retry=context.freezeStoreBoxRequest(storage,'same',{box:'box',user:'member',selections:[{key:'c3',quantity:1}],quantity:1,table:'T9'},()=> 'request-2');
 assert.equal(JSON.stringify(retry),JSON.stringify(first));assert.equal(retry.request,'request-1');assert.equal(retry.selections.length,2);assert.equal(retry.quantity,2);assert.equal(retry.table,'T8');
});

test('customer Store Box uses only protected RPC operations',()=>{
 for(const name of ['yt_store_box_claim_preview','yt_store_box_claim','yt_my_store_boxes','yt_store_box_request_v3','yt_store_box_request_cancel'])assert(moduleSource.includes(`'${name}'`),name);
 assert(moduleSource.includes('p_selections:frozen.selections'));assert(moduleSource.includes('p_request:frozen.request'));assert(!moduleSource.includes("db.from('yt_store_boxes')"));
});

test('customer Store Box only shows remaining and served quantities',()=>{
 assert.doesNotMatch(moduleSource,/已喝完/);
 assert.doesNotMatch(moduleSource,/喝完后/);
 assert.match(moduleSource,/剩余/);
 assert.match(moduleSource,/已出/);
});

test('customer can choose a combo item only when the rule allows it',()=>{
 assert.match(moduleSource,/selection_mode!=='customer'/);
 assert.match(moduleSource,/availableComponents/);
 assert.match(moduleSource,/data-store-box-choice/);
 assert.match(moduleSource,/跟随套餐顺序/);
 assert.match(moduleSource,/customer-box-claim-parts/);
 assert.match(moduleSource,/customer-box-history/);
});
