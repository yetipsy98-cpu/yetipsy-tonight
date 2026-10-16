const assert=require('node:assert/strict'),fs=require('node:fs');
(async()=>{
 const {isRefreshWindowOpen}=await import('../play/pos/refresh-schedule.mjs');
 const hours={enabled:true,start_time:'18:30',end_time:'00:30'};
 const at=iso=>new Date(iso);
 assert.equal(isRefreshWindowOpen(hours,at('2026-10-16T10:30:00Z')),true,'business window starts inclusively in Kuala Lumpur');
 assert.equal(isRefreshWindowOpen(hours,at('2026-10-16T16:29:00Z')),true,'overnight part remains active before closing');
 assert.equal(isRefreshWindowOpen(hours,at('2026-10-16T16:30:00Z')),false,'business window ends exclusively');
 assert.equal(isRefreshWindowOpen(hours,at('2026-10-16T10:29:00Z')),false,'before opening is manual-only');
 assert.equal(isRefreshWindowOpen({...hours,enabled:false},at('2026-10-16T12:00:00Z')),false,'disabled polling stays manual-only');
 assert.equal(isRefreshWindowOpen({...hours,start_time:'bad'},at('2026-10-16T12:00:00Z')),false,'invalid schedule safely disables polling');
 const pos=fs.readFileSync('play/pos/pos.js','utf8');
 assert.match(pos,/if\(!schedule\|\|!isRefreshWindowOpen\(schedule,new Date\(\)\)\)return/,'all background POS polling is gated by the saved schedule');
 assert.match(pos,/POLL_CLOCK_TICK_MS=5000/,'clock ticks locally without a request every tick');
 console.log('PASS owner refresh window, overnight boundaries and manual-only safety');
})().catch(error=>{console.error(error);process.exitCode=1;});
