# dsh-better-notice · 开发记录点

> 规则：只记用户纠正过我什么、我改了什么、怎么改的，以及**已经定稿、不许再动**的部分。
> 目的只有一个：同一件事不要被优化第二遍。每条都带日期，新的写在上方。

## 2026-11-15 13:10 · 出厂 surfaces 与「全开」旧存档

**用户的纠正**：「这个热表的这个默认值也有问题」「你告诉我哪一版的默认设置是我目前这个环境里面这样的」

**查出的事实**（git tag 里 client.js 原文，可复核）：

| 版本 | 报错 / 待处理 / 已完成 | 进行中 | 闲置 | 置顶 |
|---|---|---|---|---|
| v4.3.0 | tab 开 · 顶栏关 | tab 开 · 顶栏关 | tab 开 · 顶栏关 | tab 开 · 顶栏关 |
| 5.0.0-alpha.1 → 5.3.0 | tab 关 · 顶栏开 | tab 关 · 顶栏关 | tab 开 · 顶栏关 | tab 开 · 顶栏关 |
| 5.3.1 / 5.3.2（现版） | tab 关 · 顶栏开 | tab 开 · 顶栏关 | tab 开 · 顶栏关 | tab 开 · 顶栏关 |

用户桌面上的实际状态是「六类 Tab 全开 + 顶栏除置顶外全开」，**不存在于任何一版出厂**；置顶 order 是 70（出厂 60），其余五类 order 与出厂一致。根因是 `LEGACY_VALUES` 只给 `categories.running.surfaces.tab: [false]` 开了换代口子，其余几格的旧「开」被当成用户选择永久保留。

**已做**：清空桌面端 WebView2 存储（备份在 `cangku/261115_r5t_desktop-plugin-store.bak`），让出厂 B 生效。

**不许再动**：5.3.2 出厂 surfaces 表 = 用户选定的 B 方案——
`pinned {tab:true, topbar:false}`、`error/pending/completed {tab:false, topbar:true}`、`running {tab:true, topbar:false}`、`idle {tab:true, topbar:false}`。
这是用户在 A/B/C 三选项里拍板的 B，不要再以「更自动」为理由改。

## 2026-11-15 上午 · 超级提醒从「立刻弹」改成「等 n 分钟 + 可重复」

**用户的纠正**：「报错状态或者是待处理状态或者是已完成状态超过 n 分钟未改变的情况下才会弹…根据客户选择会有第二个第三个 n 分钟未改变的情况」

**怎么改的**：`createRingPlayer` 整段重写成锁存状态机（`markStore` 记 `{category, since, fired, acked}`），新增 `ring.afterMinutes`（1–60，默认 7）与 `ring.repeatTimes`（1–99，默认 1）两个设置项；打开一个**报错**会话视为确认（pending/completed 不设确认）；长睡不补弹；同刻只弹一个。

**不许再动**：这套锁存语义是用户逐条确认过的（m19476「OK 我觉得可以」），包括「error 才有 acked」「错过只响一次」「试听不走门禁」。

## 记录格式

```
## YYYY-MM-DD HH:MM · 一句话标题
**用户的纠正**：「原话摘录」
**查出的事实**：可复核的证据（行号 / 哈希 / 版本）
**已做**：落地的改动
**不许再动**：已定稿、再优化就是倒退的部分
```

## 5.3.4 — tab 座位的沙漏不转（回退 5.3.2 的 motionTarget 改动）

- **用户的纠正原话**：「Tab栏和置顶栏它的沙漏都没有旋转…在我之前验收的那一版 在Tab栏的沙漏是旋转的 但是置顶栏不旋转」「我之前验收的那一版好歹Tab栏是对的 现在错的地方更多了」。
- **查出的事实**：5.3.2 为了实现「顶栏与 tab 同相位」顺手让 tab 座位也吃 `motionTarget`；而各类默认 `motionTarget:'row'`（`client.js:859`）→ `decorateTabSeat` 里 `glyphMotion = moveTitle ? 'none' : moved.motion`（旧 `client.js:6767`）把图标停在 `none`，并去包住宿主 tab 的标题。真机 5.3.4 取证：`⏳` + `data-hotlist-motion="spin"` + `animation-name: hl-spin` + 两次采样 `transform` 从 `matrix(-0.93,0.37,…)` 变到 `matrix(0.43,-0.90,…)`。
- **已做**：tab 座位只动图标，`moveTitle` 恒假、`[data-hotlist-tab-title]` 只在清理旧 DOM 时出现（`client.js:6712-6772`）；第 97 组测试改名 `tab seats always move the glyph and never wrap the host title`（`test:5159`），第 98 组相位断言改读图标；文档同步（`docs/TESTING.md:155`、`docs/ARCHITECTURE.md:125`、`docs/EXTENDING.md:192`、CHANGELOG）。
- **不许再动**：不要把 `motionTarget` 接回 tab 座位。宿主 tab 的 label 是宿主渲染并复用的字符串，包住它会打乱宿主布局，还会让图标停在 `none`。`motionTarget` 只属于侧栏行与顶栏胶囊。

