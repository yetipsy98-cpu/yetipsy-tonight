import {test} from 'node:test';
import assert from 'node:assert/strict';
import {multiKdsGroups} from '../play/pos/kds-multi.mjs';
const unit=(cup,state='pending',owner=null)=>({cup,state,owner,detail:{name:'Lychee'}});
const target=(id,parent,time,units)=>({kind:'freeflow',target:id,parent,created_at:time,table_label:'A1',name:'Lychee',note:'少冰',units});
test('minute batches stay distinct and ownership splits the same liquor into independent rows',()=>{
 const cards=multiKdsGroups({targets:[target('r1','batch1','2026-11-27T10:00:00Z',[unit(1,'claimed','a')]),target('r2','batch1','2026-11-27T10:00:20Z',[unit(1)]),target('r3','batch2','2026-11-27T10:02:00Z',[unit(1)]),target('r4','batch1','2026-11-27T10:00:30Z',[unit(1)])]});
 assert.equal(cards.length,2);assert.equal(cards[0].rows.length,2);assert.equal(cards[0].rows.find(r=>r.state==='pending').cups.length,2);assert.equal(cards[0].rows.find(r=>r.owner==='a').cups.length,1);assert.equal(cards[1].rows[0].cups[0].target,'r3');
});
test('served cups disappear and original ordinary items stay independently addressable',()=>{
 const cards=multiKdsGroups({targets:[{...target('i1','order1','2026-11-27T11:00:00Z',[unit(1,'served','a'),unit(2,'claimed','a'),unit(3,'claimed','b')]),kind:'order'},{...target('i2','order1','2026-11-27T11:00:00Z',[unit(1)]),kind:'order'}]});
 assert.equal(cards.length,1);assert.equal(cards[0].rows.length,3);assert.equal(cards[0].rows.flatMap(r=>r.cups).length,3);assert.equal(cards[0].rows.find(r=>r.owner==='b').cups[0].cup,3);
});
