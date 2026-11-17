# dsh-better-notice · 开发记录点

> 规则：只记用户纠正过我什么、我改了什么、怎么改的，以及**已经定稿、不许再动**的部分。
> 目的只有一个：同一件事不要被优化第二遍。每条都带日期，新的写在上方。

## 2026-11-17 · 频率语义改回「多久播一次」+ reduceMotion 单源 + tab 行 row 目标（5.3.6）

**用户的纠正**：「动作频率又变成了动作速度？？？为什么老是改老代码还改错？？」

**改之前的现状**：5.3.5 把 `frequency` 实现成速度倍率——`motionDurationOf` 直接 `return base / max(frequency, 0.05)`，设置页文案也改成了「节奏倍率 / 0% 停；100% 原速；越低越慢」。于是滑块往左拖是**把每一下的动作拉长**，用户要的是「更稀」。4.4 起这个字段的定义一直是**频次**（`CATEGORY_FREQUENCY` 的注释「`1` = every tick, `0` = never」还在，注释和实现已经对不上）。同一轮还欠着两件：`display.reduceMotion` 被五段 `@media (prefers-reduced-motion)` + `!important` 硬压，用户设 `off` 也压不过系统；`motionTarget: 'row'` 在 tab 行从来只动图标，设置承诺没兑现。

**怎么改的**：
1. 频率回到频次、单次时长恒定：`motionDutyStep(frequency)`（`round(f/0.05)` 夹 1–20）、`motionPlayMs(motion)`（= `MOTION_MS`，**一个数都没改**）、`motionDurationOf` 改为返回**周期** `round(play * 20 / step)`、`motionRestMs = 周期 - play`。`f=1` 连着播、`f=0` 不播、`f=0.3` + `bounce` = 播 1200ms 停 2800ms。
2. keyframes 从三张表里提出来做成共享表：`motionKeyframeRules()` 按占空档生成 8 动作 × 20 档 = 160 个 `@keyframes`，注入 `<style data-hotlist-style="motion">`；三张表面表只剩 timing + iteration，`animation-name` 由 JS 内联写。`f=1` 那档与 5.3.5 手写表**逐停点等价**，被 `f=1 keyframes are the published 5.3.5 table` 当基线钉住；保持段一律显式停**末帧**（`rotate(360deg)` 不能停在半圈）。`PREVIEW_FRAMES` 的 10 处 `transform:` 前缀一字未动，只补了守卫测试。
3. reduceMotion 收成一个判据：`motionAllowed(settings, win)`（`on` 停 / `off` 强制动 / `auto` 跟 `matchMedia`），`applyReduceMotionAttr()` 把它写成 `html[data-hotlist-reduce-motion]`，删掉四段媒体查询与它们的 `!important`，`VIEW_CSS` 那条纯 CSS 保护保留、触发源换根属性。**顺序是先让 JS 在停用时不再写内联 `animation-name`，再删 `!important`**——反过来中间态会让动画漏出来。
4. tab 行 `row` 目标：真机先验过宿主 `<span class="…tabLabel">` 持裸文本节点，于是 `paintTabLabel()` 给它打 `data-hotlist-tab-label` 并内联写文字动画，glyph 记 `none`（同一节点骑同一趟位移，不叠两趟）。**不包 wrapper、不 clone、不改宿主 `display`**；把 glyph 搬出 span 会让 tab 高度 35 → 38 px（实测），所以不搬。宿主没有 label 元素的旧形态退回只动图标。
5. 文案回频次口径（zh「播放频率 · 0% 不播；100% 一直播；越往左越稀。每一下的动作速度不变」/ en「Playback frequency …」），「节奏倍率 / Tempo / 越低越慢」清干净。`VERSION` → 5.3.6，`SETTINGS_VERSION` 仍 4（字段名与范围没变，不需要迁移）。测试 126 → 132 组。

**已定稿，不许再动**：
- `frequency` 是**频次**，不是速度。任何人想把 `duration` 再除一次频率，先看 `frequency is a duty cycle, not a speed` 这条测试。
- `MOTION_MS` 的四个数值是当前节奏，属于已发布语义，不得借「调手感」之名改。
- 三处表面**同 keyframes、同单次时长、同相位种子**（`fnv1a(sessionId|category)`）；「侧栏恢复随机脉冲」「各处独立调频」都是倒退。
- `display.reduceMotion` 的适用范围 = **侧栏 / tab 行 / 顶栏 / 缺失分组**，**永不含设置页预览**。预览是用户唯一能看见所选动作的地方，冻掉等于盲选。
- tab 行只许给宿主现成元素打属性，**不许包 wrapper**（5.3.4 就是这么被回退的），也不许为「图标静止」去改宿主布局（会 +3 px）。

## 2026-11-17 · 三处动效统一成一份共享计划（5.3.5）

**用户的纠正**：「顶栏 / Tab 栏 / 侧栏动画统一：只有前两个统一，侧栏不是，不管三个都统一成什么样，都得统一成设置里用户调的样式」

**改之前的现状**（三套模型）：顶栏胶囊与 tab 座各写各的常驻循环（delay 算式各算一遍），侧栏 glyph 走 burst 抽签（`motionBursts` 每 tick 掷 `Math.random()`、`MOTION_CONCURRENCY=4` 限并发）——同一个会话在三个表面上是三段各跑各的动画，且 `frequency` 在侧栏是「抽中的概率」、在另两处另有语义。

**怎么改的**：新增四个纯函数 `motionTempoOf` / `motionDurationOf` / `motionDelayCss` / `motionPlanOf(settings, sessionId, category, motion, motionTarget)`，三处（侧栏 `applyMotion`、tab `decorateTabSeat`、顶栏 `topbarChips`+`topbarChipNode`）全部改从 `motionPlanOf` 取 `{motion, motionTarget, durationMs, delayMs, delayCss, animation, textAnimation}`；`frequency` 统一成节奏倍率 `duration = base / max(freq, 0.05)`；burst 全家（`motionBursts`/`startBurst`/`stopBurst`/`bandBursts`/`chipBursts`/`MOTION_CONCURRENCY`/`data-hotlist-burst`/`data-hotlist-chip-burst`）删除，`Math.random` 不再参与动效；`previewStyle` 改 tempo 语义；设置页文案「播放频率」→「节奏倍率」，写明三处一起变。`VERSION`→5.3.5，`SETTINGS_VERSION` 仍 4。

**已统一，不许再动**：三处同 keyframes、同 duration、同相位种子（`fnv1a(sessionId|category)`）是 5.3.5 的定稿口径；「侧栏想恢复随机脉冲」「三处各自独立调频」「频率恢复成抽签概率」都属于倒退，不要再以「更热闹」为理由改。

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


## 5.3.6 — 频率回归语义 + reduce 单一判据 + tab 行也动宿主标题

- **用户的纠正原话**：「动作频率又变成了动作速度？？？为什么老是改老代码还改错？？」「设置页的图标的动效预览功能也没了，之前还有」「不然你就派一个人专门去审代码 看看是不是会有什么功能性回退」。
- **查出的事实**：5.3.5 把 `glyph.frequency` 直接除进 `animation-duration`（`client.js:2079` 旧行 `durationMs = motionDurationOf(motionName, glyph.frequency)`），标签也改成「节奏倍率 / 越低越慢」；而 4.4 的原始语义是「0% 不播；100% 每个节拍都播」。同一轮里设置页预览的关键帧是 `0% { } 100% { }` 空块（`PREVIEW_FRAMES` 写成裸值 `rotate(0deg)` 缺属性名，被 CSS 解析器丢弃），所以「预览不动」真实存在，`animationName` 有值不等于在动。另 `display.reduceMotion` 三档压不过一条无条件的 `@media (prefers-reduced-motion: reduce)` 覆盖。
- **已做**：f 只买静默、单次动作时长恒定（`motionDutyStep`/`motionPlayMs`/`motionDurationOf`/`motionRestMs`，`client.js:2041-2064`），20 档 `@keyframes` 由 `motionKeyframeRules` 统一生成（`:4205`）；reduce 收敛成 `motionAllowed()` 一处判据 + `html[data-hotlist-reduce-motion]`（`:5345`/`:5362`），删掉 5 处媒体查询；预览关键帧补 `transform:` 并加结构性回归；tab 行在「作用于=图标+标题」时**给宿主标题元素加类**来动文字（`TAB_LABEL_ATTR`/`findTabLabelTextNode`/`paintTabLabel`，`:6853-6933`），零 wrapper。
- **不许再动**：`glyph.frequency` 不许再影响单次动画时长（只影响频次）；`f=1` 的关键帧与 5.3.5 逐停点相等已有基线测试钉住（`test:2477`）；reduce 判定只许走 `motionAllowed()`，不许再写媒体查询；tab 标题只能加类，不许包 wrapper / clone 节点。

## 2026-11-17 · 闲置图标不做动效（用户拍板）

- **用户的原话**：「行 不错 不需要给闲置的加动作」。
- **查出的事实**：闲置类出厂就是 `categories.idle.glyph.motion = 'none'`、`frequency = 0`，所以卡片标题那颗 🧊 预览不动，`getComputedStyle().animationName === 'none'` 是正确的出厂行为，不是预览坏了。
- **已做**：不改任何默认值。
- **不许再动**：不要给闲置类加动效，也不要把「预览不动」当成缺陷去修。
