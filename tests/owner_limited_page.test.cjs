const assert=require('node:assert/strict');
const fs=require('node:fs');
const pos=fs.readFileSync('play/pos/pos.js','utf8');
const home=pos.slice(pos.indexOf('function ensureLimitedHome'),pos.indexOf('async function loadLimitedReports'));

assert.match(home,/limitedReportsRoot/,'Owner Limited renders reports directly inside its page');
assert.match(pos,/createOwnerReports\(\{db,root,isOwner:isOwnerLimited,allowExport:false/,'limited reports are read-only and use the full-page root');
assert.match(pos,/\?\[\['limited','报表'\],\['ambassador','发 Pass'\]\]/,'Owner Limited has one report tab and one Pass tab');
assert.match(pos,/state\.ambassadorAccess&&!limitedRole\(\)\)tabs\.push/,'the Ambassador access callback cannot add a duplicate Owner Limited tab');
assert.doesNotMatch(home,/consoleUI|data-limited-action/,'reports do not open in the small tool drawer and the shortcut card is removed');
console.log('PASS Owner Limited has a full-page report view and a single Ambassador Pass entry.');
