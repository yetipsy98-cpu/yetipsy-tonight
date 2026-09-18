YETIPSY TONIGHT V2.4
====================

需要覆盖：

Google Apps Script
1. Code.gs

GitHub repo
2. backend.js
3. app.js
4. content.js
5. styles.css

index.html / audio.js 不需要改。

部署顺序
--------
1. Apps Script：把旧 Code.gs 全部替换成 V2.4 Code.gs。
2. 保存。
3. 顶部函数选择 setup，运行一次。
   - setup 会保留旧表，并自动把 MATCHES / TABLES 缺少的新栏位补上。
4. 部署 -> 管理部署 -> 当前 Web App -> 编辑 -> 版本选“新版本” -> 部署。
5. 打开现有 /exec URL。
   正确应显示：version 2.4 / connected true。
6. GitHub 覆盖 backend.js / app.js / content.js / styles.css。
7. 等 GitHub Pages 更新后，用两台以上手机测试。

建议测试流程
------------
A. 两台手机用相同桌号加入，例如 A1。
B. Lobby 应显示 2 PEOPLE HERE 和两个昵称。
C. 一台按“大家都进来了 · 开桌”。
D. 两台应看到同一题。
E. 两台几乎同时按 I'M READY：只有最先到服务器的一台成为 Lead。
F. 只有 Lead 手机播放 READY / 3 / 2 / 1 / POINT；另一台显示 GAME IN PROGRESS。
G. Lead 按 NEXT QUESTION；下一题重新抢 READY。
H. 初始 3 题后进入 Tonight Lobby，第一次约 12 分钟后解锁 Social Event；可按 PLAY NOW 提早测试。
I. 两个不同桌的 OPEN 玩家进入 Social Event，应该可 Match，并看到相同 Mission。
J. 双方完成 Mission -> 互换验证码 -> 自己先确认后仍能继续看到自己的码 -> 双方确认后显示成功。
K. 完成后回 Tonight Lobby。之后约 15 分钟交替出现 Social Event 与 After Dark 同桌题。

提醒说明
--------
REMIND ME 会在浏览器支持且用户允许时使用 Web Notification。
网页仍在后台/前台时，也会用声音、震动、Toast 提醒。
如果浏览器已经把网页完全关闭，普通 GitHub Pages 无法保证定时系统 Push；重新打开网页会自动恢复服务器当前桌局。

V2.4 主要机制
-------------
- Table Lobby：等所有人进来再开桌。
- 在线人数 + 昵称显示。
- First READY = 本题 Lead Phone。
- 每题重新抢 READY，不固定主持人。
- 只有 Lead Phone 播放倒数，避免多手机延迟乱叫。
- Lead 倒数异常/断线约 15 秒后自动进入讨论状态，避免卡桌。
- Lead 超过约 60 秒没开下一题，其他手机可接管。
- 初始 3 个同桌 Warm-up。
- 约 12 分钟后第一次 Social Event。
- 后续约每 15 分钟交替 Social Event / After Dark 同桌题。
- 可 PLAY NOW 提早开启，不强迫等待。
- OPEN / SURPRISE 可跨桌 Match；CHILL 可留桌。
- Match 双方共享相同 Mission。
- TABLE VS TABLE 周期会优先抽桌与桌互动 Mission。
- 双向 4 位验证码。
- 等对方确认时持续显示自己的验证码。
- Match 可取消。
- Match 完成后写入 history，避免当晚马上重复配到同一个人。
- Bartender Pick 变成 Tonight Lobby 的可选功能，不再作为“通关终点”。
- 没有 100% 完成页；整晚可持续循环。
- 旧桌局超过约 8 小时自动视为新一晚。
