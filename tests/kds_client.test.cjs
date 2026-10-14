const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.join(__dirname,'..');
const js=fs.readFileSync(path.join(root,'play/pos/pos.js'),'utf8');

test('all work entry points expose one KDS and one open-tab window',()=>{
 for(const role of ['pos','owner','staff','cashier']){
  const html=fs.readFileSync(path.join(root,`play/${role}/index.html`),'utf8');
  for(const id of ['tab-orders','kdsBoard','storeBoxOrderQueue','activeList','tab-unpaid','unpaidList','checkoutPayNow','checkoutPayLater'])assert.match(html,new RegExp(`id="${id}"`),`${role}:${id}`);
  assert.match(html,/吧台 KDS/);
  assert.match(html,/后付 \/ 挂单/);
 }
});

test('KDS and settlement queues are separated by order state',()=>{
 assert.match(js,/row\.status==='confirmed'&&!row\.store_box_only/);
 assert.match(js,/row\.payment_status==='unpaid'&&\(row\.status==='fulfilled'\|\|row\.status==='confirmed'\)/);
 assert.match(js,/renderKdsOrder/);
 assert.match(js,/目前没有待付款挂单/);
 assert.match(js,/yt_pos_create_order_with_rewards_v2/);
 assert.match(js,/p_checkout_mode:/);
});

test('Cashier-created orders are silent while staff approval and KDS arrivals announce',()=>{
 assert.match(js,/created_channel!=='cashier'/);
 assert.match(js,/Staff 待审核订单/);
 assert.match(js,/吧台新增/);
 assert.match(js,/ping\('approval'\)/);
 assert.match(js,/ping\('kds'\)/);
});
