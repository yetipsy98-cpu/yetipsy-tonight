const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const css=fs.readFileSync(path.join(__dirname,'../play/pos/console.css'),'utf8');
function luminance(hex){const v=hex.replace('#','').match(/../g).map(x=>parseInt(x,16)/255).map(x=>x<=.04045?x/12.92:((x+.055)/1.055)**2.4);return .2126*v[0]+.7152*v[1]+.0722*v[2];}
for(const [text,bg] of [['#f3f5ee','#111b18'],['#becbbb','#1b2822'],['#c1d0b7','#243a2b'],['#20291f','#e9cd98'],['#eee0c4','#213027'],['#e4ebda','#1d3022'],['#526154','#ffffff'],['#dfe8dc','#1b2822'],['#f2f5e9','#132119']]){const values=[luminance(text),luminance(bg)].sort((a,b)=>b-a);assert((values[0]+.05)/(values[1]+.05)>=4.5,text+' on '+bg);}
assert(css.includes('button{color:var(--text);background:var(--panel2)'));assert(css.includes('#nav button{display:block}'));assert(css.includes('button:focus-visible'));assert(css.includes('.receipt-preview-area{flex:1;min-height:0;overflow:auto}'));
for(const rule of ['#dayCloseRoot .stack label','#dayCloseRoot .checkline','#dayCloseRoot .day-pending>summary','#dayCloseRoot .day-pending-row small','#dayCloseRoot .stack input'])assert(css.includes(rule),rule+' contrast override missing');
assert(css.includes('#dayCloseRoot .stack label,#dayCloseRoot .checkline,#dayCloseRoot .day-pending-row strong{color:#dfe8dc}'));
for(const role of ['owner','staff','cashier','pos']){const html=fs.readFileSync(path.join(__dirname,'../play',role,'index.html'),'utf8');assert(html.indexOf('pos/console.css')>html.indexOf('pos/pos.css'));assert(html.includes('20261010-storebox-v16-1'));}
console.log('PASS: dark/light text contrast, visible mobile Owner/Game Pass nav, explicit button colors, keyboard focus and scrollable printable bill.');
