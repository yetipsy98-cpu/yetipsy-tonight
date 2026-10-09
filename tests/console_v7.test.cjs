const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.join(__dirname,'..');
class El{constructor(){this.flags=new Set();this.dataset={};this.classList={add:k=>this.flags.add(k),remove:k=>this.flags.delete(k),contains:k=>this.flags.has(k),toggle:(k,v)=>v?this.flags.add(k):this.flags.delete(k)};this.children=[];this.disabled=false;this.inert=false;this.value='';this.textContent='';}focus(){this.focused=true;}addEventListener(){}querySelectorAll(){return [];}querySelector(){return null;}}
(async()=>{
 const markup=fs.readFileSync(path.join(root,'play/owner/index.html'),'utf8');
 for(const role of ['owner','staff','cashier','pos']){
  const html=fs.readFileSync(path.join(root,'play',role,'index.html'),'utf8');const ids=[...html.matchAll(/id="([^"]+)"/g)].map(m=>m[1]);assert.equal(ids.length,new Set(ids).size,role+' duplicate ID');
  assert(html.includes('toolDrawerOverlay'));assert(html.includes('factoryConfirmForm'));assert(!html.includes('href="../owner/"'));assert(!html.includes('内部测试'));assert(!html.includes('测试版'));assert(!html.includes('FUTURE'));assert(!/>V4</.test(html));
 }
 const pos=fs.readFileSync(path.join(root,'play/pos/pos.js'),'utf8');const ids=new Set([...markup.matchAll(/id="([^"]+)"/g)].map(m=>m[1]));for(const ref of pos.matchAll(/\$\('([^']+)'\)/g))assert(ids.has(ref[1]),'Missing POS element '+ref[1]);
 const tools=fs.readFileSync(path.join(root,'play/shared/owner-tools.js'),'utf8');const init=tools.slice(tools.indexOf('export function initOwnerTools('),tools.indexOf('export async function loadOwnerTool('));for(const ref of init.matchAll(/\$\('([^']+)'\)/g))assert(ids.has('ops_'+ref[1]),'Missing embedded Owner element '+ref[1]);
 const els=Object.fromEntries([...ids].map(id=>[id,new El()]));const drawer=els.toolDrawer,overlay=els.toolDrawerOverlay,main=new El(),head=new El(),focus=new El(),body=new El();overlay.flags.add('hidden');els.ops_modalBackdrop.flags.add('hide');
 const panes=['catalog','rewards','team','campaign','loyalty','banners','insights','factory','pin'].map(key=>{const e=new El();e.dataset.pane=key;return e;});const subs=['give','new','rules'].map(key=>{const e=new El();e.dataset.subpane=key;return e;});const buttons=subs.map(sub=>{const e=new El();e.dataset.sub=sub.dataset.subpane;return e;});panes[1].querySelectorAll=s=>s==='[data-subpane]'?subs:buttons;drawer.querySelectorAll=()=>panes;drawer.querySelector=s=>s==='[data-pane="rewards"]'?panes[1]:null;
 const ownerButton=new El(),pendingButton=new El();let owner=false,cashier=false,loads=0,offers=0,resumes=0,cancels=0,notices=[];
 const context={document:{body,activeElement:focus,getElementById:id=>els[id],querySelector:s=>s==='main'?main:head,querySelectorAll:s=>s.includes('pending')?[pendingButton]:[ownerButton],addEventListener(){}},createFactoryReset:()=>({cancel:()=>cancels++,resume:async()=>resumes++,busy:false}),console};vm.createContext(context);
 const source=fs.readFileSync(path.join(root,'play/pos/console.js'),'utf8').replace(/^import .*;\n/gm,'').replace(/export /g,'');vm.runInContext(source+'\nglobalThis.create=createConsole;',context);
 const ui=context.create({db:{},work(){},isOwner:()=>owner,isCashier:()=>cashier,loadAdmin:async()=>loads++,loadOffers:async()=>offers++,loadRights(){},notice:m=>notices.push(m),onReset(){}});
 ui.roleChanged();assert(ownerButton.flags.has('hidden'));assert(pendingButton.flags.has('hidden'));await ui.open('factory');assert(overlay.flags.has('hidden'));assert.equal(resumes,0);
 await ui.open('pin');assert(main.inert);assert(!overlay.flags.has('hidden'));assert(!els['tab-reset'].flags.has('hidden'));ui.close();assert(!main.inert);assert(focus.focused);
 owner=true;cashier=true;ui.roleChanged();assert(!ownerButton.flags.has('hidden'));await ui.open('rewards','rules');assert.equal(loads,1);assert.equal(offers,1);assert(subs[0].flags.has('hidden'));assert(!subs[2].flags.has('hidden'));assert(buttons[2].flags.has('active'));ui.close();await ui.open('factory');assert.equal(resumes,1);ui.close();
 console.log('PASS: all four entry points retain complete unique DOM, integrated tools, role guards, same-window reward subpanes, PIN drawer, focus restoration and reset resume.');
})().catch(e=>{console.error(e);process.exitCode=1;});
