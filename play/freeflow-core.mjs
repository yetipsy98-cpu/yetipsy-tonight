export const freeflowErrors={guest_token_invalid:'访客资格已更新，请联系店员恢复',guest_restore_invalid:'恢复码已失效，请联系 Cashier 刷新',guest_storage_unavailable:'浏览器无法保存访客资格，请允许网站存储后重试',freeflow_session_missing:'找不到这场 FreeFlow，请联系 Cashier。',freeflow_order_invalid:'请先完成有效 Amba 挂单或结账。',freeflow_unavailable:'FreeFlow 尚未开始、已暂停或已到期。',freeflow_already_bound:'此会员已有一场尚未结束的 FreeFlow。',freeflow_full:'这张配套的绑定名额已满。',freeflow_menu_empty:'请至少选择一款饮品。',freeflow_menu_missing:'请先由 Owner 设置可用菜单。',freeflow_token_expired:'绑定码已到期，请让 Cashier 刷新。',freeflow_member_missing:'找不到你的 FreeFlow 资格。',freeflow_wait_for_cup:'请等待上一杯确认出品后再点。',freeflow_request_completed:'这杯已处理，请刷新查看。',outside_service_area:'请在店内重新定位后点单。',location_required:'请允许定位，然后重新尝试。',bell_disabled:'场地定位尚未设置，请联系店员。',product_unavailable:'这款饮品暂时无法供应，请重新选择。',token_invalid:'会员码已过期，请顾客重新打开会员码。',owner_only:'只有 Owner 可以设置菜单。',cashier_only:'需要 Cashier 或 Owner 权限。'};
export const ffError=e=>freeflowErrors[e?.message]||e?.message||'操作失败，请重试。';
export function parseMemberToken(raw){let value=String(raw||'').trim().replace(/^member:/i,'');try{value=new URL(value).searchParams.get('member')||value;}catch{}if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value))throw Error('请扫描顾客动态会员码。');return value;}
export function freezeFreeflowRequest(storage,key,member_id,product_id,makeId=()=>crypto.randomUUID()){
 let saved;try{saved=JSON.parse(storage.getItem(key)||'null');}catch{}
 if(saved&&saved.member_id===member_id&&saved.product_id===product_id&&saved.request_id)return saved;
 const draft={member_id,product_id,request_id:makeId()};storage.setItem(key,JSON.stringify(draft));return draft;
}
export const freeflowLabels={active:'使用中',paused:'已暂停',closed:'已关闭',expired:'已到期',upcoming:'尚未开始',pending:'待出品',served:'已出品',cancelled:'已取消'};
