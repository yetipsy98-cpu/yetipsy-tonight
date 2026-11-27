import {test} from 'node:test';
import assert from 'node:assert/strict';
import {reasonOptions,reasonKind} from '../play/pos/reason-picker.mjs';
test('common reasons are tailored to each operation and satisfy existing minimum lengths',()=>{
 for(const options of Object.values(reasonOptions)){assert(options.length>=4);assert(options.every(s=>s.length>=3&&s.length<=160));assert.equal(new Set(options).size,options.length);}
 for(const [label,kind] of [['修改原因','edit'],['更改本场有效时间','time'],['积分调整原因','points'],['奖励延期原因','reward'],['拒绝营业日回填','reject'],['FOC 申请原因','discount'],['取消领取码','code'],['重新打开 Closing','closing'],['加单原因','append'],['取消待出品杯','cancel']])assert.equal(reasonKind(label),kind,label);
});
