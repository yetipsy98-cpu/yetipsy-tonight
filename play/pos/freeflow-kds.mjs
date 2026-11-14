// Session identity defines a group; table labels are delivery snapshots, never identities.
export function groupFreeflowQueue(rows){
 const groups=new Map(),ordered=[...rows].sort((a,b)=>(Date.parse(a.requested_at)||0)-(Date.parse(b.requested_at)||0)||String(a.id).localeCompare(String(b.id)));
 for(const row of ordered){const key=row.session_id?'session:'+row.session_id:row.order_id?'order:'+row.order_id:row.order_no?'number:'+row.order_no:'request:'+row.id;
  if(!groups.has(key))groups.set(key,{key,session_id:row.session_id||null,order_no:row.order_no,requested_at:row.requested_at,rows:[],lines:[]});groups.get(key).rows.push(row);
 }
 return [...groups.values()].map(group=>{const lines=new Map();for(const row of group.rows){const key=JSON.stringify([row.product_id||row.name,row.name,row.note||'',row.table_label||'']);if(!lines.has(key))lines.set(key,{name:row.name,note:row.note||'',table_label:row.table_label||'',rows:[]});lines.get(key).rows.push(row);}
  return {...group,quantity:group.rows.length,tables:[...new Set(group.rows.map(r=>r.table_label||'待填桌号'))],lines:[...lines.values()].map(line=>({...line,quantity:line.rows.length,proxy:line.rows.some(r=>r.proxy),members:[...new Set(line.rows.map(r=>r.member_name||'会员'))]}))};
 });
}
