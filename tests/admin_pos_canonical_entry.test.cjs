const assert=require('node:assert/strict'),fs=require('node:fs');
const canonical=fs.readFileSync('play/admin/pos/index.html','utf8'),pos=fs.readFileSync('play/pos/pos.js','utf8');
assert.match(canonical,/id="signinForm"/);
assert.match(canonical,/id="orderTabs"/);
for(const [file,target] of Object.entries({
 'play/admin/index.html':'./pos/',
 'play/admin/owner/index.html':'../pos/',
 'play/admin/staff/index.html':'../pos/',
 'play/admin/cashier/index.html':'../pos/',
 'play/pos/index.html':'../admin/pos/',
 'play/owner/index.html':'../admin/pos/',
 'play/staff/index.html':'../admin/pos/',
 'play/cashier/index.html':'../admin/pos/'
})){
 const html=fs.readFileSync(file,'utf8');
 assert(html.includes(`location.replace("${target}"+location.search+location.hash)`),`${file} redirects to the canonical POS route`);
}
assert.match(fs.readFileSync('play/admin/admin.webmanifest','utf8'),/"start_url": "\.\/pos\/"/);
assert.match(fs.readFileSync('play/admin/admin-sw.js','utf8'),/const SHELL=\['\.\/pos\//);
assert.match(fs.readFileSync('play/admin-sw.js','utf8'),/\.\/admin\/pos\//);
assert.match(pos,/isOwner\(\)[\s\S]*?\[\['admin','管理'\]/);
assert.match(pos,/\[\['create','点单'\]/);
console.log('PASS: the admin POS is canonical; all work routes redirect and the app chooses available tabs from the signed-in role.');
