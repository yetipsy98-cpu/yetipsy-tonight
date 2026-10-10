const assert=require('node:assert/strict');
const fs=require('node:fs');

const client=fs.readFileSync('play/index.html','utf8')+fs.readFileSync('play/app.js','utf8');
for(const text of [
 '不发送短信验证码',
 '手机号目前不通过短信验证',
 '欢迎礼和好友礼是否叠加由店主决定',
 '不会公开生日',
 '实际结果以系统结算',
 '此处不公开概率',
 '不保证对应奖品'
])assert(!client.includes(text),`customer copy still exposes internal note: ${text}`);

for(const role of ['pos','owner','staff','cashier']){
 const html=fs.readFileSync(`play/${role}/index.html`,'utf8');
 for(const text of [
  '所有设置都在同一个抽屉中完成',
  '员工不能公开注册工作账号',
  '当前没有手机 OTP 验证',
  '顾客和 Staff 都无法获取权重数据',
  '真正扫码并结账时才会标记为已使用'
 ])assert(!html.includes(text),`${role} still contains note-like copy: ${text}`);
 assert(html.includes('所选数据清空后无法撤销'),'destructive reset warning must remain');
}

console.log('PASS: customer and workbench surfaces hide internal notes while destructive-action warnings remain.');
