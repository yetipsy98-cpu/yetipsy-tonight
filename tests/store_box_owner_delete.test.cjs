const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs');
const box=fs.readFileSync('play/pos/store-box.js','utf8');
const migration=fs.readFileSync('supabase/migrations/20261017100000_owner_delete_store_boxes.sql','utf8');

test('Owner can remove a Store Box while preserving history and preventing Staff deletion',()=>{
 assert.match(box,/if\(isOwner\?\.\(\)\)actions\.push\(.*data-box-progress="delete"/);
 assert.match(box,/if\(action==='delete'\)\{if\(!isOwner\?\.\(\)\)throw Error\('owner_only'\)/);
 assert.match(box,/status!=='cancelled'/);
 assert.match(box,/box_deleted:'Owner 删除存酒箱'/);
 assert.match(migration,/if p_action='delete' and not private\.yt_work_owner\(\) then raise exception 'owner_only';end if;/);
 assert.match(migration,/status='cancelled',cancelled_by=auth\.uid\(\)/);
 assert.match(migration,/status='cancelled',claim_token=null,cancelled_by=auth\.uid\(\)/);
 assert.match(migration,/insert into public\.yt_store_box_events\(box_id,event_type,actor_id,note,metadata\)/);
});
