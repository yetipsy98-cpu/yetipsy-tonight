const {test}=require('node:test'),assert=require('node:assert/strict');
test('session dates use Malaysia time and history totals exclude pending cups',async()=>{
 const {sessionDay,sessionHours,freeflowHistory}=await import('../play/freeflow-view.mjs');
 assert.equal(sessionDay('2026-10-31T18:00:00Z'),'2026-11-01');assert.equal(sessionDay(null),'');
 const row={starts_at:'2026-10-31T15:00:00Z',ends_at:'2026-10-31T18:00:00Z',cups:2,drinks:[{name:'A',quantity:2}],pending:{name:'B'}};
 assert.equal(sessionHours(row,'en'),'23:00 – 02:00 · next day');
 const h=freeflowHistory([row,{starts_at:'2026-11-01T18:00:00Z',cups:1,drinks:[{name:'A',quantity:1}]}],'2026-10');
 assert.equal(h.cups,2);assert.equal(h.sessions,1);assert.equal(h.varieties,1);assert.deepEqual(h.months,['2026-11','2026-10']);
});
test('English FreeFlow errors do not show untranslated server messages',async()=>{
 const {ffError}=await import('../play/freeflow-core.mjs');assert.match(ffError(Error('freeflow_wait_for_cup'),'en'),/Wait for your current drink/);assert.match(ffError(Error('freeflow_wait_for_cup')),/等待/);assert.equal(/[\u4e00-\u9fff]/.test(ffError(Error('unknown'),'en')),false);
});
