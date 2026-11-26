const assert=require('node:assert/strict'),check=require('./helpers/versioned_entry.cjs');
const page=(entry,preload=entry)=>`<link rel="modulepreload" href="${preload}"><script type="module" src="${entry}"></script>`;
for(const version of ['old-v1','20261126-next-release-v999'])assert.equal(check(page('./pos.js?v='+version),'pos.js'),'./pos.js?v='+version);
assert.throws(()=>check(page('./pos.js'),'pos.js'),/cache version/);
assert.throws(()=>check(page('./pos.js?v=new','./pos.js?v=old'),'pos.js'),/preload matches/);
assert.throws(()=>check(page('./other.js?v=v1'),'pos.js'),/module entry exists/);
console.log('PASS entry versions may advance; missing versions, stale preloads and missing modules fail.');
