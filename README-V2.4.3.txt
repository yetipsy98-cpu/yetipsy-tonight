YETIPSY Tonight V2.4.3
======================

本版主要更新
------------
1. 倒数语音完整播放：READY / THREE / TWO / ONE / POINT 每一句念完才进入下一句，不再用固定 850ms 切断语音。
2. 右上角实时显示 Apps Script 往返延迟（ms）。
3. 顶部 TABLE 按钮新增桌子控制：
   - CHANGE TABLE 换桌
   - LEAVE THIS TABLE 离桌
   - 离桌会即时从旧桌在线人数、READY、Lead 中移除
   - 未验证完成的 Match 会取消，已完成双向验证的 Match 要先完成互动再离桌
4. 题库扩大：
   - Warm: 48
   - Table/Chill: 24
   - Cross-table Missions: 24
   - After Dark: 24
   - Deep: 24
5. 新增“这题不适合 · 换一题”：只有还没人 READY 时可以换；一旦有人 READY 就锁题。
6. Table VS Table 专属 Mission 扩到 6 种。

覆盖文件
--------
Apps Script:
- Code.gs

GitHub:
- app.js
- backend.js
- content.js
- styles.css
- audio.js  （本次必须覆盖，因为语音逻辑有更新）

部署顺序
--------
1. Apps Script 覆盖 Code.gs
2. 保存
3. 运行 setup()
4. 部署 -> 管理部署 -> 编辑 -> 新版本 -> 部署
5. 打开 /exec，确认 version = 2.4.3
6. GitHub 覆盖 app.js / backend.js / content.js / styles.css / audio.js
7. 等 GitHub Pages 更新后，手机强制刷新网页

建议测试
--------
A. 两台/三台手机进入同一桌，确认人数约 2 秒更新。
B. 第一人 READY 后不应开始；所有在线玩家 READY 后，第一位 READY 的手机才倒数。
C. 听完整 READY / THREE / TWO / ONE / POINT，不应被下一句切断。
D. 右上角应出现例如 420 ms / 980 ms；这是浏览器到 Apps Script 的一次请求往返时间，不是手机之间的直接 ping。
E. 在还没人 READY 时点“换一题”，所有手机应同步出现新题；有人 READY 后应禁止换题。
F. 点右上角 TABLE A1 -> CHANGE TABLE，旧桌人数应自动减少，新桌人数增加。
G. LEAVE THIS TABLE 后，应退出旧桌且旧桌 READY 统计马上减少。
