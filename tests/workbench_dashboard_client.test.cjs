const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const root=path.join(__dirname,'..'),src=fs.readFileSync(path.join(root,'play/pos/pos.js'),'utf8'),css=fs.readFileSync(path.join(root,'play/pos/console.css'),'utf8');
for(const role of ['owner','staff','cashier','pos']){
 const html=fs.readFileSync(path.join(root,'play',role,'index.html'),'utf8');
 for(const id of ['workspaceSubtitle','ownerDashboardStats','ownerDashboardAlerts','ownerDashboardRefresh'])assert(html.includes(`id="${id}"`),`${role} missing ${id}`);
 assert(!html.includes('id="shiftSummary"'),`${role} still has duplicated shift summary`);
 assert(html.includes('20261010-copy-v15-4'));
 assert(html.includes('经营报表')&&html.includes('营业日结')&&!html.includes('所有设置都在同一个抽屉中完成'));
 assert(html.includes('data-owner-tool="pin"')&&html.includes('活动与游戏'));
}
assert(src.includes("db.rpc('yt_owner_report_v8',{p_start:day,p_end:day,p_member_page:1,p_search:''})"));
assert(src.includes("if(!isOwner()||!$('ownerDashboardStats'))return"));
assert(!src.includes('renderShiftSummary'));
for(const selector of ['.owner-overview-grid','.owner-priority-actions','.owner-alert-strip'])assert(css.includes(selector),`missing ${selector}`);
console.log('PASS: compact Owner overview and same-window tools without the duplicated cashier status strip.');
