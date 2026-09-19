YETIPSY Tonight V2.4.4
=======================

这版重点
--------
1. Table Match 改成“全场 Match Window”，不再绑死每一桌自己的 After Dark / Event 进度。
2. Match Window 到时间后，所有桌在下一次同步时都会看到 TABLE MATCH OPEN。
3. 老板可以在 Google Sheet 的 CONTROL 页提前开启：
   - TABLE_MATCH_MODE = AUTO   按设定时间自动开放
   - TABLE_MATCH_MODE = OPEN   立即全场开放
   - TABLE_MATCH_MODE = CLOSED 强制关闭
4. TABLE_MATCH_DAILY_TIME 可选，例如 21:00。
   - 留空时：默认从今晚第一位活跃客人开始算 25 分钟后开放。
   - TABLE_MATCH_AUTO_AFTER_MIN 可修改这个 25 分钟。
5. 一个人也可以玩：Lobby 会显示 SOLO CARD；Table Match 开放后可直接去匹配其他桌。
6. 任何玩家在 Table Question / After Dark / Break / Event 时，只要 Match Window 已开放，都可直接 TABLE MATCH。
7. 去 Match 的玩家会暂时从桌内 READY 人数中移除，不会卡住整桌。
8. Match 完成后不再调用 completeEvent，不会因为一个人完成 Match 而把整桌状态一起推进。
9. index.html 加 v=2.4.4 cache-busting，降低手机继续使用旧 JS 的情况。

部署顺序
--------
A. Apps Script
1. 覆盖 Code.gs
2. 保存
3. 运行 setup()
4. 确认出现 PLAYERS / MATCHES / TABLES / CONTROL 四个 Sheet
5. 部署 -> 管理部署 -> 编辑 -> 新版本 -> 部署
6. 打开 /exec，确认 version = 2.4.4

B. GitHub
覆盖：
- index.html
- app.js
- content.js
- styles.css
- backend.js
- audio.js

backend.js / audio.js 此版逻辑无重大变化，但建议整包一起覆盖，确保版本一致。

CONTROL 推荐设置
----------------
TABLE_MATCH_MODE            AUTO
TABLE_MATCH_DAILY_TIME      （留空）
TABLE_MATCH_AUTO_AFTER_MIN  25
SOLO_MATCH_ALLOWED          TRUE

如果今晚客人突然很多，想提前开：
把 TABLE_MATCH_MODE 从 AUTO 改成 OPEN。
所有还开着网页的客人会在下一次同步时看到 TABLE MATCH OPEN。

如果想固定每天 9:00pm 开：
TABLE_MATCH_MODE = AUTO
TABLE_MATCH_DAILY_TIME = 21:00

测试建议
--------
1. 两台手机在不同桌号，例如 A1 / B1。
2. CONTROL 设 OPEN。
3. 两台都应在数秒内看到 TABLE MATCH OPEN。
4. A1 去 Match 后，A1 如果原本还有其他人，他们的 READY 总人数不应继续把 A1 算进去。
5. A1 与 B1 完成 Match 后，双方回去都应恢复各自桌子的当前状态，不会推进整桌 Event。
6. 单独一台手机进入 C1，也应看到 SOLO CARD，并能在 Match Window 开放后排队匹配。
