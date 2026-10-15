const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.join(__dirname,'..');
const html=fs.readFileSync(path.join(root,'play/admin/pos/index.html'),'utf8');
const consoleJs=fs.readFileSync(path.join(root,'play/pos/console.js'),'utf8');
const posJs=fs.readFileSync(path.join(root,'play/pos/pos.js'),'utf8');

assert.match(html,/data-pane="campaign"[\\s\\S]*?data-subpane="activity"[\\s\\S]*?id="ops_ownerCampaign"/);
assert.match(html,/data-subpane="pool"[\\s\\S]*?id="ops_poolGame"[\\s\\S]*?id="ops_poolEditor"/);
assert.match(consoleJs,/page\\.toggleAttribute\\('hidden',!visible\\)/);
assert.match(consoleJs,/p\\.toggleAttribute\\('hidden',!visible\\)/);
assert.match(consoleJs,/sub\\.toggleAttribute\\('hidden',!visible\\)/);
assert.match(consoleJs,/if\\(!selectedPane\\)[\\s\\S]*?找不到/);
assert.match(consoleJs,/owner-tools\\.js\\?v=20261015-tool-pane-visibility-fix-v1/);
assert.match(posJs,/console\\.js\\?v=20261015-tool-pane-visibility-fix-v1/);
assert.match(html,/pos\\.js\\?v=20261015-tool-pane-visibility-fix-v1/);
console.log('PASS: Owner campaign and prize pool panes are explicitly revealed, and missing panes report visibly.');
