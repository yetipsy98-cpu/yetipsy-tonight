YETIPSY Tonight V2.4.2

本次修复重点：READY 机制

正确流程：
1. 全桌进入 Lobby，人数齐后开桌。
2. 所有人看到同一道题。
3. 每个人看完题后各自按 I'M READY。
4. 第一个 READY 的玩家只取得本题 Lead 权，不会立即倒数。
5. 页面实时显示 READY 人数，例如 1/4、2/4、3/4、4/4。
6. 所有仍在线的同桌玩家都 READY 后：
   - Lead Phone 自动播放 READY / 3 / 2 / 1 / POINT。
   - 其他手机显示 ALL READY / 跟着 Lead Phone。
7. 下一题所有 READY 状态清空，重新准备、重新抢 Lead。
8. 如果最早 READY 的 Lead 在开局前离线，Lead 自动转交给仍在线的最早 READY 玩家。

安装：
A. Apps Script
- 用 Code.gs 覆盖旧 Code.gs
- 保存
- 运行 setup() 一次
- 部署 -> 管理部署 -> 编辑 -> 新版本 -> 部署
- 打开 /exec，确认 version 为 2.4.2

B. GitHub Pages
- 覆盖 app.js
- backend.js / content.js / styles.css 本次没有逻辑变化，可保持 V2.4.1；整包内也附上当前版本。
- 等 GitHub Pages 更新后，两台/多台手机强制刷新测试。

测试建议：
- A、B、C 三台手机进入同一桌。
- 开桌后 A 先 READY：此时绝对不能倒数，只应显示 1/3 READY，A 是 Lead。
- B READY：显示 2/3，仍然不能倒数。
- C READY：显示 3/3；此时只有 A 手机开始 READY/3/2/1/POINT，B/C 显示跟随 Lead。
