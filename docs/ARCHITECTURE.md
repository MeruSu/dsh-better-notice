# 热表架构（维护者文档）

目标读者：下一个要改这份代码的人。看完应该能回答三件事——状态从哪来、三种显示位置各自怎么挂、哪些地方看起来"脏"但**换干净写法会更糟**。

所有行号对 `client.js`（**7914 行，v5.3.1**）。**行号是起点不是真理**：文件一改就漂，按符号名搜（`grep -n 'function classify' client.js`）才准。

这批 `client.js:N` 在 **v5.3.1 又整体重钉过一次**，做法是拿**上一版快照**（`git show HEAD:client.js`，7167 行）当基准：对每个旧行号先找出它落在旧文件的哪个定义符号里，再定位新文件（7914 行）里同名符号的定义行，最后按原偏移平移（区间保持原长度，符号消失就报出来不猜）。所以每条引用都仍然落在**同一个符号内部**，只是绝对行号变了。`test:N` 的 **121 条**同样按测试名从源码行号重新对齐（`docs/TESTING.md` §1.2 的行号就是真值）。

**核对方式**：拿符号名 `grep -n` 一遍，行号应当紧挨着那个符号的定义；维护者机器上有个 refcheck 小脚本就是干这件事的（把每条 `client.js:N` 与同行提到的符号名对齐，越界即 FAIL）。

## 1. 分层与真实名字

```
                 ┌────────────────────────────────────────┐
数据源  ────────►│ 纯判定层（无 DOM，可单测）             │
sessions.list    │ sanitizeSettings        client.js:1741  │
uiSession.       │ classify                client.js:2646 │
  sessionStatus  │ sortSeats               client.js:2712 │
workspaces.list  │ buildSeatPlan           client.js:2735 │
api-session/error│ sidebarStateOf          client.js:3519 │
                 │ findRowTitle            client.js:3499 │
                 │ shortenTitle            client.js:2566 │
                 │ labelOf                 client.js:3152 │
                 └───────────┬────────────────────────────┘
                            │ plan / row 判定
        ┌───────────────────┼────────────────────────┐
        ▼                   ▼                        ▼
  tab 座位适配器        侧栏 glyph 适配器         设置页
  mountTabSeats         createSidebarAdapter      HotlistSettingsPage
  client.js:6391        client.js:6391             client.js:6391
  disposeTabSeats       start/refresh/stop/misses
  client.js:6542
```

**与任务书用词的差异（别按旧名字找函数）**：代码里没有 `buildMarkerPlan()`、`createTabSeatsAdapter()`。

- 判定拆成两步纯函数：`classify()` 判类别与 token，`sortSeats()` 同级排序，`buildSeatPlan()` 再套上限并给出 `order`。三步都不碰 DOM，可以单独喂假数据测。
- tab 适配器不是独立工厂，而是 `apply()` 内的 `mountTabSeats()` / `disposeTabSeats()`；它需要一个活着的 `ctx`（注册 slot、读写 store），抽成工厂反而要传一堆依赖。
- 侧栏适配器是真正的工厂 `createSidebarAdapter(options)`，接口为 `start() / refresh() / stop() / misses()`（不是 `mount/update/dispose`）。它自己遍历宿主 DOM，不接收 plan——因为一行一行读宿主更简单，而 tab 必须先把 plan 算好再看能放几个。

新增一个显示位置时，照 `createSidebarAdapter` 的形状写一个工厂：**只读 store、只写自己的节点、提供 `stop()` 全量还原、带 `misses()` 自检**，然后像 `sync()`（`client.js:7370`）那样由位置开关驱动 start/stop。不要改 `classify`/`buildSeatPlan`/`sidebarStateOf`。

## 2. 数据源（唯一权威，全部只读）

| 来源 | 取法与语义 | 官方依据 |
| --- | --- | --- |
| `ctx.get('sessions').list.getSnapshot()` | `{ids, byId, phase, projectionsBySession}`。`byId[id]` = `{id, displayTitle, running, retainedBy, blank, updatedAt, formatStatus, projectionValues, title?, cwd?, parentId?, origin?}` | `dsh-api-session-controller/lib/client.js:3830-3835`，字段 `:4169-4182`，子代理补行 `:4192-4235` |
| `updatedAt` | 最近活动（ms），= `max(summary.updatedAt, lastPromptAt)`；**子代理行恒 0** | `:3610` |
| `projectionsBySession[id].values.subagentCatalog` | 子代理清单；子会话在 `sessionStatus` 里 running 就算父会话"在干活"（`mode === 'external'` 的行跳过） | `runningChildren()`，`client.js:2623`；跳外部的 `:2063` |
| `ctx.get('uiSession').sessionStatus.getSnapshot()` | `Map<id, {running, pendingInteraction:{kind}|null, completionUnread}>`；唯一的状态权威 | `dsh-client-ui-session/lib/client.js:782-790`，快照 `:999-1004`，`completionUnread` 置/清 `:964-981` |
| `ctx.get('uiWorkspace').workspaces.list.getSnapshot()` | `{items:[{workspaceId, sessionIds,…}], pinnedSessionIds, archivedSessionIds}`；用于"只列当前工作区"、置顶与归档 | `dsh-client-ui-workspace/lib/client.js:1553` |
| 当前会话 | `byId[*].retainedBy.mainView > 0`（不读 `selection`，避免和持久化快照时序打架） | 侧栏同一规则 `dsh-client-ui-workspace/lib/client.js:877-879`（`mainSessionId`）；热表读法 `client.js:6245` |
| 运行失败 | `ctx.remote.$on('api-session/error', (sessionId, message))`（live-only）+ 已打开会话 `sessions.binding(id)?.session.getSnapshot()` 的 `promptError.error.message` / `lastAgentError` | relay `dsh-api-session-controller:4294`，快照 `:2913-2937`，`promptError` 形状 `:2372-2375` |
| 切会话 | `ctx.get('uiWorkspace').openSession(sessionId)` | `dsh-client-ui-workspace/lib/client.js:1473-1475`，热表封装 `client.js:6245` |

`pendingInteraction.kind` 只有三种：`approval` / `question` / `plan-review`（审批 `dsh-client-ui-approval/lib/client.js:225`，提问与计划审批 `dsh-client-ui-user-questions/lib/client.js:185`：`this.kind = planReviewOf(questions) === void 0 ? "question" : "plan-review"`）。没有独立的 `subagents` 信号，v4 把"子代理在跑"并进 `running`。

## 3. 座位 id、`heal`、`repair` —— 三件互相配套的事

- 座位是 `conversation.view` 的一条注册，id 为 `hotlist-seat-<sid>`（`SEAT_PREFIX`，`client.js:84`；历史前缀 `seat-` 见 `SEAT_PREFIXES`，`client.js:86`）。
- **为什么必须是前缀 id**：宿主把"每个会话当前选中的 view id"持久化进 `localStorage['dsh.conversation.<sessionId>']`（`dsh-client-ui-conversation:4560-4571`）。如果座位 id 就是裸 sessionId，用户点一次座位，源会话的偏好被写成"我的座位页"；座位注销后该 view 不存在，宿主 `resolveActiveView`/`restoreView` 互相激活 → React #185（Maximum update depth）直到人肉清 localStorage。真机事故记录：`cangku/261111_cr8_react185_crash.png`。
- `healViewPreferences()`（`client.js:3197`）在模块加载时扫所有 `dsh.conversation.*`，把指向 `hotlist-seat-*` / `seat-*` / `session-switcher` / `hotlist` 的偏好改回 `chat`（`isSeatViewId`，`client.js:3189`），其它字段原样保留。它是在模块顶层直接调用的（`client.js:3189`），不是 effect。
- `repairSourcePreference()`（`client.js:3224`）补一个更细的竞态：宿主会在我们 `openSession(target)` 之前先写源会话偏好，所以"离开时 activate chat"仍可能被覆盖；在 `settle()` 的开头、250ms、1200ms 三处再修一次源会话的偏好（`client.js:5326-5346`）。**这是补偿宿主时序，不是绕过 API**（没有"设置某会话 view"的公开 API）。

## 4. 座位顺序：类别 order + 类内序号

- v3 的"tier + 进入戳"已随 v4 判定层一起删掉。现在顺序完全由设置决定：跨类别按 `categories[<id>].order` 升序（`orderedCategories()`，`client.js:2579`；同 order 时按 `CATEGORY_RANK` 兜底稳定，`client.js:187`），类内按 `sortBy` 排（`sortSeats()`，`client.js:2712`）：`time` = `updatedAt` 倒序，`manual` = 按 `pinLevel`（只 `pinned` 用它，`pinLevel` 是判定时现算的 `pinIndex + 1`，`client.js:2669`）。
- 座位 `order = categories[<id>].order * 100 + 类内序号 + 1`（`client.js:2713`）。因此**只要一个座位没换类别、且前面没人增删，它的 order 就不变**——宿主不会因为 30s 的 `sync()` 重排而抖动。
- **不要把 `updatedAt` 直接映射成 order**：宿主每次注册/注销都会 `ctx.emit('slots/changed')`（`dsh-client-ui-renderer:1349-1351`）→ conversation 的 `refreshViews` 遍历所有 binding 做 `restoreView`（`:22633-22660`）。频繁重排 → 反复注销/重注册 → 每次都有机会把某个刚释放的 session 喂进 `binding()`，抛 `uiConversation.binding: unknown session`，并且 active view 会短暂落回 chat。`updatedAt` 只用于类内 `sortBy:'time'` 的排序键；同一批里并列时用 `sessionId` 兜底，保证两次计算结果一致。
- 用户在设置里改某类的 `order`，该类所有座位会一次性换 base（一次重注册），这是预期代价。
- **三层语义在 tab 面上仍然成立**：tier1 = `error` / `pending`（等你处理）+ `pinned` + `completed`（刚刚产出），tier2 = `running`，tier3 = `idle`（最后活动在全局「最近对话展示时间」内的普通会话，`collect.recentWindowMinutes`）。因此 `CATEGORY_SURFACES.idle.tab` 默认是 **true**（`client.js:915`）——用户原话是"五分钟内的会话都加入到那个列表，位于第3级"，把第三级从 tab 面默认关掉等于删掉他明确要的东西。想降噪的用户可以只关 `idle.surfaces.tab`（侧栏保留），这是**可选**手段，不能当默认。

## 5. 上限：物理宽度 ∩ `maxSeats`，紧急类另有硬顶

官方规则：可见 tab 数 = `max(1, floor((rowWidth - 48) / 120))`，超出折叠进一个**点不到**的溢出菜单（`dsh-client-ui-conversation:20814-20831`）。所以上限必须自己算（`seatLimit()`，`client.js:6215`）：

1. 量 `[data-conversation-tabs]` 的**父元素**（`div.an3WzG_tabs`）。tablist 自己是内容宽（实测恒 204px），量它必得 1。
2. `visible = max(1, floor((width - TAB_ROW_PADDING) / TAB_WIDTH))`，常量 `TAB_WIDTH`/`TAB_ROW_PADDING`（`client.js:100-101）。
3. 给 chat + trajectory 留 2 个位置，返回 `max(1, visible - 2)`。
4. 量不到（0）时回退 6（`FALLBACK_LIMIT`，`client.js:98`）。
5. 最终上限 = `min(settings.maxSeats, seatLimit())`，`maxSeats === 'auto'` 时取 `seatLimit()`（`client.js:6215-6217`）。

`buildSeatPlan()` 的裁剪（`client.js:2735-2775`）：`pinned` / `pending` / `error` 是"要人处理"的类别，**不按 `limit` 裁**，但受硬顶 `limit + ALWAYS_OVERFLOW`（= `limit + 4`，常量 `ALWAYS_OVERFLOW` `client.js:314`）约束；`pinned` 另外受用户自己的 `pinned.maxSeats` 限制（`client.js:3016`）；其余类别（`completed` / `running` / `idle`）填到 `limit` 为止。被裁掉多少记在 `plan.overflow`（`client.js:2757`；v4.4 起设置页不再显示这个数字，字段仍在）。宁可挤一点，也不把要人处理的会话藏起来；但 10 个待审全出座位会把 tab 行挤爆，所以硬顶必须有。

除了上面这套跟用户设置挂钩的规则，还有一刀**与设置无关的绝对硬闸** `PLAN_MAX_ROWS = 37`（`client.js:312`）：plan 排好之后统一 `kept.slice(0, PLAN_MAX_ROWS)`（`client.js:312`）。取值的理由写在常量注释里（`client.js:312-313`）：「Hard ceiling 37: the plan is sorted by priority, so the tail is exactly what a crowded workspace should lose」。注意 `plan.overflow` 记的是**被上面那些规则挡掉**的条数（`client.js:2757`），不含这 37 条这一刀——两者别混。

## 6. 刷新与订阅的分工

| 触发 | 频率 | 干什么 | 位置 |
| --- | --- | --- | --- |
| `sessions.list.subscribe(sync)` | 数据变即触发 | 会话增删、标题、updatedAt | `client.js:2659` |
| `uiSession.sessionStatus.subscribe(sync)` | 数据变即触发 | 三状态字段变化 | `client.js:7370` |
| `workspaces.list.subscribe(sync)` | 数据变即触发 | 工作区归属、归档、置顶 | `client.js:7370` |
| `setInterval(sync, 30s)` | 30s | `collect.recentWindowMinutes` 滑出窗口、`collect.completedTtlMs` 过期、失败标记过期 | `REFRESH_MS` `client.js:95`，定时器 `client.js:95` |
| `window resize`（防抖 200ms） | — | 重算 `seatLimit()` | `seatLimit` `client.js:6215`，监听/防抖 `client.js:6215-6221`（`RESIZE_DEBOUNCE_MS` `client.js:96`） |
| `onSettingsChange` | 写入即触发 | 座位与图标立刻反映设置页 | `client.js:2423`，effect `client.js:2423-2428` |
| 侧栏内部 1s tick / 30s 全量刷新 | — | `document.hidden` 暂停动效；缓慢兜底 DOM 抖动 | `SIDEBAR_TICK_MS`/`SIDEBAR_REFRESH_MS` `client.js:3291`/`client.js:3291` |

`sync()` 是唯一的收敛点（`client.js:7370`）：读快照 → 记完成态 → 清失败标记 → 读设置 → 按位置开关 start/stop → 算 plan → 挂座位 → 刷侧栏。不要在别处直接改座位。

### 6.1 短读保护（shrink guard）与座位记忆

真机 bug：切换后约 70 秒座位从 5 掉到 2 且不回来——宿主的列表快照短时间缺行。处理（`restoreRecentSeats` `client.js:6626-6642`，调用点 `client.js:6626`）：

- 只有"已注册座位的会话从 `list.ids` 消失"才算真的要撤；先记 250ms（`SHRINK_CONFIRM_MS`，`client.js:105`）后二读，两次都缺才撤。
- 撤下的座位进 `recentSeats`：60 秒内（`RECENT_SEAT_MS`，`client.js:107`）会话回来，用**原来的 order/label** 直接恢复，不必重新排队。
- 由我们自己的规则导致的撤座（当前会话、掉出窗口、`maxSeats`、类别 `surfaces` 关、工作区、归档）仍然立即撤。

## 7. `takeOverStatusDot` 为什么是两层

另一插件（dsm）的状态点不在我们的 slot 里，也没有"禁用某插件"的 API。所以：

1. **CSS 层**：只在开关打开时注入 `<style data-hotlist-style="takeover">`（`TAKEOVER_STYLE`，`client.js:3342`；注入/移除 `ensureTakeover`，`client.js:3602`）。
2. **inline 兜底**：如果点仍可见（对方的 MutationObserver 重建、或 CSS 被覆盖），对点写 `display:none!important` 并记下原值；关开关时先移除 style 再逐点回填原 inline 值（`restoreDots`，`client.js:3635`）——**不删对方节点、不卸载对方插件**。

同理 `hideNativeDot` 不写 inline，而是给行加 `data-hotlist-hide-native` 属性（`client.js:3799-3800`），由我们自己的样式表隐藏 `[data-state]` 本体（`SIDEBAR_STYLE`，`client.js:3311`，规则在 `:2760`）；卸载时删属性即还原。

拼接选择器时**只用 `ROW_SELECTOR` 常量原样插入**（它自带方括号）。曾经写成 `[${ROW_SELECTOR}]` → 生成 `[[…]]`，浏览器整条丢弃，两个开关同时失效（v3.0 真机 bug）。测试里有一条断言扫描所有 style 文本不含 `[[`。

## 8. 侧栏 DOM 增强的边界

- 只插入一个 `span[data-hotlist-glyph]` 到**标题 span 之前**（`findRowTitle`，`client.js:3499`：`_title` 类名 → 文本等于 `displayTitle` → 非时间文本 → 第二个 span；找不到就只动图标并 debug 一行，绝不抛）。
- 我们自己的节点**绝不带 `data-state`**，也不放文本节点（emoji 用 `::before{content:attr(data-hotlist-char)}`，方图用 `<img alt="">`），避免被宿主的选择器或无障碍树误认。
- `motionTarget:'row'` 时对**宿主标题**写 inline `animation`（同 keyframes、同相位），停用/换状态/卸载时还原原值（`applyMotion`，`client.js:3778`）。文字动效只许 `opacity`/`translate`，禁 `scale`（字会糊）。
- `MAX_MISSES=60`（`client.js:3285`）：连续找不到行/标题就整块停用（删自己的节点与样式），30 秒后再试，避免在 DOM 大改后继续乱贴。
- **tab label 是字符串管线**：`dsh-client-ui-conversation:20767-20776` 用 `{label}` 画文本，所以 tab 上只有 emoji，不能放图片（图片只能进我们自己的 React 树：设置页预览、未来的顶栏/浮层）。

## 9. 注销为什么延迟

注册/注销都会触发宿主的同步刷新链（见 §4）。会话**离开集合**时：

- 不立即 dispose：`scheduleDisposals()`（`client.js:6364`）= `setTimeout(0)` → `requestAnimationFrame` → `setTimeout(0)` 才真正卸载，让宿主先跑完自己的 unmount 清理。
- 同一个 id 要重建时**同步**先 dispose 旧句柄（否则 duplicate id）；插件卸载/`disposeTabSeats()` 也同步 flush（`flushDisposals`，`client.js:6345`）。
- 收益：真机上我们自己不再成片刷屏。**这是缓解竞态，不是修复宿主**——注释里已写明。
- **宿主自己会抛一次，别去兜**：座位指向的会话被点进去之后用户拒绝审批 / 会话结束，宿主 `refreshViews` 会在会话释放后抛 `Uncaught Error: uiConversation.binding: unknown session "<id>"`（真机 4 次拒绝各 1 条；栈 `UiConversation.binding → activateView → restoreView → refreshViews → OI.flush`，`dsh-api-session-controller/lib/client.js:4067-4074` 的 borrow 语义）。触发条件是「会话已释放、宿主还没清自己的座位表」。**不要加 `window.onerror` 全局吞**：它会盖掉我们以后真出的错，而且这个异常不在我们的调用栈里。我们只负责延后注销 + `phase === 'ready'` 闸门。

## 10. 设置模型与版本

- 形状（`defaultSettings()`，`client.js:882-910`）：`version / maxSeats / scope / positions{tab,topbar,sidebar} / topbar{mode,titleMode,maxSeats,previewInWeb,rightReservePx,chipWidthPct,customScope} / takeOverStatusDot / hideNativeDot / display{reduceMotion} / shortcuts{jumpEnabled,overlayEnabled,overlayKey} / overlay{side,sizeMin,sizeMax,fallbackImage} / collect{completedTtlMs,recentWindowMinutes} / sound{volume} / ring{pending,error,completed} / audio{smart} / pinned{maxSeats} / choices{} / categories{6 类 × 8 字段}`。
  - `pins{<sid>:level}` **已废弃但读时兼容**：v4.6 起置顶改读宿主的 `workspaces.list.pinnedSessionIds`（`pinnedIdsOf()`，`client.js:6566-6569`），手写 pin 表不再使用（注释「v4.6 dropped the hand-written pin list」，`client.js:3758`）；旧表仍在已知路径表里被读取接受、随即忽略（`client.js:3758`），不会当成"未知字段"反复搬进 preserved 层。
  - 新增 `pinned{maxSeats}`：置顶座位另有自己的上限（`PINNED_SEATS`，`client.js:309`；设置页行 `data-hotlist-row="pinned.maxSeats"`，`client.js:3016`）。
- 每类字段（`defaultCategory()`，`client.js:847-870`）：`enabled / order / sortBy / surfaces{tab,sidebar,topbar} / glyph{kind,value,source,motion,motionTarget,frequency,uploads[]} / glyphSecondary（只有 pending 有值：❓ + blink） / popout{enabled,builtin,images[],displayMs,entrance,ambient,exit,side} / sound{enabled,builtin,uploads[]}` —— **8 个顶层键**。v4.6 删掉了 `reserved` / `pinLevel` / `within` 三个字段：类别不再有"保留位"概念（`favorite` 整类删除，见 `RETIRED_PATHS`，`client.js:201`），`pinLevel` 改成判定时现算（`classify()` 里 `pinIndex + 1`，`client.js:2669`），`within` 早在 v4.4 就搬成全局 `collect.recentWindowMinutes`。`glyph.frequency` 是 0–1（`motionIntervalMs` 读时换算），`glyph.size` 读时忽略。音效音量是**全局** `sound.volume`，类别里只剩开关与素材池。
- `SETTINGS_VERSION = 4`（`client.js:174`；`107` 现在是 `PRESERVED_KEY`）。v4.1 只改字段形状、没有升版本号（旧记录经 `sanitizeSettings` 逐字段回落即可）：`display.motionWhenNativeVisible` / `display.maxAnimated` / `overlay.scale` 已删，新增 `glyph.source`、`glyph.motionIntervalMs`、`overlay.sizeMin/sizeMax`、顶层 `sound.volume`。v4.4 同样没升版本号：`glyph.motionIntervalMs` → `glyph.frequency`（0–1）、每类 `within` → 全局 `collect.recentWindowMinutes`、`glyph.size` 读时忽略、`settings.overflow` 提示通道删除；旧 `motionIntervalMs` 仍按 `f = 1 − (ms − 2000) / 58000` 单调换算，`0` 依旧表示「不播」。同理 v3 的 `overlay.scale` 倍数在迁移里直接丢弃（只读 `overlay['scale']` 做兼容分支已删），尺寸回落到 260/520。v4.6 也没升版本号：删一个类别、删三个类字段、加 `pinned.maxSeats`，同样靠 `sanitizeSettings` 回落 + `RETIRED_PATHS` 丢弃。v5.2（`ring.*`）与 v5.3（`audio.smart`）也都只是**加一个布尔、能给默认值**，所以 `SETTINGS_VERSION` 仍是 `4`：`sanitizeSettings` 从默认值起算，旧记录里没有这个键就是这个键的默认值，不需要迁移代码。
- 迁移链：
  - **v1（2.x，「会话 tab」时代）**：`{completedTtlMs, maxSeats}`，键 `dsh.session-switcher.settings`（`LEGACY_SETTINGS_KEY`，`client.js:173`）。
  - **v2（2.5 更名「热表」）**：同形状，新键（`SETTINGS_KEY`，`client.js:167`）；读旧键后写新键并删旧键。
  - **v3（3.0 / 3.1）**：`states.<state>.{kind,value,motion,motionTarget,follow,reserved}`、`positions` 三布尔、`display`，删 `placement`。
  - **v4（4.0 / 4.1）**：8 个 `states` 收成 7 个 `categories`，新增 `pins`/`collect`/`sortBy`/`within`/`glyph.size`/`popout`/`sound`/`surfaces`；`overlay.enabled` 分发到各类 `popout.enabled`；`maxSeats` 上限 20 → 12。4.1 / 4.4 / 4.6 也都在同一版本号内换形状（见上）。
- 迁移实现：`migrateSettings()`（`client.js:1925-1934`）。`version === SETTINGS_VERSION` 走 `sanitizeSettings`；**其它任何版本一律按 v3 表迁移**（`migrateFromV3`，`client.js:1878`），因为用户真实数据只有 v3 一种形态。曾经的 alpha 工件把 `version: 5` 写在 v4 形状上，所以迁移里额外把 `categories/collect/pinned` 三张表浅合并过去（`client.js:3016-3018`）——这不是一条迁移链，只是兼容那个中间态；4→5 那种"只改版本号"的幽灵迁移已删。
- `sanitizeSettings()`（`client.js:1741`）是纯函数，从默认值起算，逐字段独立回落：非法值只回落该项，不整份作废。类别级同理 `sanitizeCategory()`（`client.js:1660`）。**没有"用户改不动"的保留类别**：`favorite` 是历史类别，v4.6 整类删除并记进 `RETIRED_PATHS`（`client.js:201`），读旧记录时直接丢弃、不再保留成"未来字段"（`collectUnknown` 的短路，`client.js:2232`）。
- 旧键只读兼容：`states` / 扁平 `glyphs` / `motion` / `showIdle` / 顶层 `completedTtlMs` / 旧 `overlay.*`。写入侧由 `upgradePatch()`（`client.js:2432`）把旧键映射回 v4 字段，再 `mergePatch()`（`client.js:2481`）逐类合并；读取侧不再有 v3 投影（设置页已经直接读 v4）。
- 对外 API：`window.__HOTLIST_SETTINGS__`（`client.js:5973`，旧名 `__SESSION_SWITCHER_SETTINGS__` 同对象 `client.js:5973`）。方法集是 `get / set / reset / subscribe / override / defaults / glyphOf / emojiOf / lastError`（`client.js:3251-3262`）——**有 `defaults`，没有 `backups/restore`**；备份环只在 `window.__HOTLIST__.settings.backups()/restore(i)` 上（见 §10.2）。`override()` 是测试缝（注入内存 patch），生产不要用。
- 同页写入靠 `notify()`（`client.js:2413`）广播；`watchStorage()`（`client.js:2547`）只负责**跨窗口**（`storage` 事件同页不触发）。

### 10.1 "用户设置永不覆盖"：preserved 层

用户在更新版本里"凭空消失"的选择必须能回来，所以任何一次写盘之前都先把**当前实现表达不了的东西**存到独立的保留键（`PRESERVED_KEY`，`client.js:169`）：

- `notePreserved(previous)`（`client.js:2371-2380`）= `collectUnknown(previous)` ∪ `outOfRangeOf(previous)`，非空才写。`collectUnknown`（`client.js:2232-2253）走 schema 的已知叶子/容器表，`RETIRED_PATHS` 里的路径直接跳过（`:1678`）；`outOfRangeOf`（`client.js:2256-2286）把被边界拒掉的数字连同 `{raw, clamped}` 一起留下。
- 读回用 `revivePreserved()`（`client.js:2347-2350`）= `reviveOutOfRange(reviveUnknown(...))`。两条复活判据都很保守：`reviveUnknown` 只在**当前值仍等于默认值**（= 用户没选过，`client.js:2315`）时才写回；`reviveOutOfRange` 只在**当前值仍等于当初被夹到的 `clamped`**（= 用户没改过，`client.js:2331`）且原始值已落在放宽后的范围内时才写回。
- `writePreserved` 自己吞 quota 异常（`client.js:2294-2300`）：注释写明「a full quota costs the preserved copy, never the live settings」。
- 顺序很关键：`persist()`（`client.js:2369-2379`）= 先 `pushBackup(previous)` → 再写 `SETTINGS_KEY` → **写成功才** `notePreserved(previous)`。写失败时 `lastWriteError` 记 `'quota'`（`QuotaExceededError`）或 `'storage'`，设置页据此提示（`client.js:2367`），并且这一轮不做保留。

### 10.2 备份环

`pushBackup(previous)`（`client.js:2371-2375`）把**上一份完整设置**塞进环形数组 `[{at, settings}, …].slice(0, BACKUP_LIMIT)`（`BACKUP_LIMIT = 5`，`client.js:172`，键 `BACKUP_KEY` `client.js:171`）。所以每次写盘都自动留一手，最多 5 步可回退。`readBackups()`（`client.js:2352-2356`）过滤坏项。对外只有 `window.__HOTLIST__` 暴露：

- `settings.backups()` → `[{at, version}]`（`client.js:2954`，不返回内容）
- `settings.restore(index)` → `sanitizeSettings(entry.settings)` → `persist` → `notify()`（`client.js:2413-2420`），失败返回 `warning`

`settings` 的其余方法是 `get / set / reset / subscribe`（`client.js:5978-5981`）——**没有 `defaults`**。

### 10.3 出厂预设不是用户选择（`LEGACY_VALUES`，v4.6.4）

§10.1/§10.2 管的是「实现暂时表达不了的值」和「写坏了的整份记录」；它们都不处理另一种情况：**盘上的值是我们自己某一代发的默认值，用户从来没动过**。这种值不该被当成用户选择——否则我们改默认参数（v4.6.3 把闲置图标换成 `🧊`、动效表整体重排）对老安装永远不生效，用户只能自己去设置页重设一遍。

分界线：**存值恰好等于某一代出厂预设 → 跟随当前默认；否则是用户选择，一字不动**（用户 `m08181` 原话：「如果老用户未变更的情况下 我们应该更新成新的 因为那不是老用户的自定义，那是属于我们的预设」）。表在 `LEGACY_VALUES`（`client.js:214-221`），第一列是 v4.3.0 那一代：`glyph.value: ['💤']`、`glyph.motion: ['none','blink']`、`glyph.motionTarget: ['glyph']`、`glyph.frequency: [1]`、`glyphSecondary.motion: ['blink']`、`sound.enabled: [false]`。逐字段查表走 `legacyValuesOf(sub, key)` / `isLegacyValue()`（`client.js:1532-1534`）——`sub` 是 `'glyph'` / `'glyphSecondary'` / `'sound'`，两个 glyph 槽各有自己的表，不串味。

三条实现要点，改这块之前先看：

- **闸门要盖住 `own.value`，不只是 legacy 的 `oldEmoji`**（`client.js:1606-1612`）。v4 记录里 emoji 存在 `own.value`，💤 就在那里；只让 `oldEmoji` 过闸门则 v4.6.4 的目标根本不生效。
- **`sound.enabled` 别写反**（`client.js:4639-4640`）：`next.sound.enabled` 此刻已经是当前默认，所以命中旧默认 `false` 时保留 `next`（而不是保留存值）。
- **与 order 的 `LEGACY_DEFAULTS`（`client.js:194-199`）同一条规则、两套表**：那边是「命中就用 `CATEGORY_ORDER`」，这里是逐字段回落，语义一致所以没合并。

它和另外两层是互补的，不是重复：`outOfRangeOf`/`reviveOutOfRange` 救「被夹掉的值」，`collectUnknown`/`reviveUnknown` 救「当前 schema 不认识的字段」，`LEGACY_VALUES` 管「认识、合法、但等于老默认」。三条都对同一个 `sanitizeSettings` 起作用，顺序是「回落（含 `LEGACY_VALUES` 让位）→ 读 preserved → 复活」。

### 10.4 「用户真选过吗」：`choices` 标记（v5.0.0-alpha.1）

§10.3 只看**值**：等于老默认就当预设。这会把控件砸死——用户在设置页里主动选 `none` / `blink` / 「仅图标」/ 频率 100% / 关音效，这些**恰好就是旧默认值**，选完立刻被闸门改回去（界面回弹）。v5.0.0-alpha.1 加一层显式标记：

- `settings.choices = { "categories.<类别>.<槽>.<字段>": true }`，默认 `{}`（`defaultSettings()` `client.js:882`）。只有**用户自己写过**的字段在里面。
- 埋点在唯一写入口 `writeSettings(patch)`（`client.js:4335`）：先 `choicesFromPatch(upgraded, base)`（`client.js:1886-1904`）再 `mergePatch`。**必须看传进来的 patch，不能看合并后的整体**——预设规则在 sanitize 阶段改写值，被它改写的不算选择。
- 闸门是 `旧预设 && choices[path] !== true`：`sanitizeGlyph` 四处（`client.js:1600-1640`）与 `sanitizeCategory` 的 `sound.enabled`（`client.js:4639-4650`）；`sub`/`category` 都在手边，路径直接拼。
- 清洗走 `sanitizeChoices()`（`client.js:1537`）：只留 `true`、只认 `/^categories\.[a-z]+\.[a-zA-Z]+(\.[a-zA-Z]+)?$/`、键长 ≤80、上限 256；它是 `knownLeaves`（`client.js:2157`）里的叶子，所以不会掉进 preserved 副本。
- `resetSettings()`（`client.js:2519`）连 `choices` 一起清空：恢复默认 = 重新认可出厂预设，之后新版预设又能覆盖。
- **不升 `SETTINGS_VERSION`、没有迁移**：缺字段补 `{}` 即可；老记录没有标记，语义仍等于「全是预设」，与 §10.3 完全一致。

配套的必要改动：`mergePatch` 对 `categories.<id>.<字段>` 多合一层（`client.js:877`）。以前设置页必须把整个 `glyph` 对象摊平进 patch（否则上传池被冲掉），那样 `hasOwnProperty` 会看到四个键全在，等于每次编辑把所有字段都标成选择；现在 patch 只带真正改动的键，`{glyph: {motion}}` 不碰 `uploads`。

## 11. 扩展点

**加一个类别**：`CATEGORY_IDS`/`CATEGORY_ORDER`/`CATEGORY_RANK`（`client.js:187-190`）、`CATEGORY_GLYPHS`（`client.js:204`）、`CATEGORY_MOTION`（`client.js:205`）、`CATEGORY_SURFACES`（`client.js:278`）、`CATEGORY_OF_TOKEN`（`client.js:822`）、`classify()` 的判定分支（`client.js:2646`）、`sidebarStateOf`（`client.js:3519`）、`buildSeatPlan` 的 `always` 集（`client.js:2739`）、ZH/EN 字典（`ZH` `client.js:987-1185`、`EN` `client.js:1205-1401`）、设置页卡片渲染（`card` `client.js:4637`，遍历 `client.js:4637`）；再加单测。加类别时记得 `CATEGORY_RANK` 要给同级 order 一个稳定的兜底位次。

**加一个显示位置**：`defaultSettings().positions` 加键（`client.js:914`）、`positionsOf`（`client.js:913-924）加派生、`sanitizeSettings` 里保留布尔（`client.js:1741-1749`）、写一个适配器工厂并让 `sync()` 开关它（`client.js:7370-7371`）、设置页加卡片。不要动 plan。

**改快捷键**：已接线，实现在 `ctx.inject(['shortcuts'], …)` 块里（`client.js:7635`）。**不要**自己 `window.addEventListener('keydown')`——官方有 `ctx.shortcuts`（`@deepseek-ai/dsh-client-shortcuts`）：`register`（可被用户改键）/ `registerFixed`（固键）/ `observeFixedInput`（自己分派），都返回幂等 disposer，用 `ctx.effect` 交给 Cordis 回收。注意 `Alt+1..9` 在 web 端被 `isWebBindingAllowed` 拒（裸 Alt+数字），第三方 `dsh-session-hotkeys` 又会在 capture 阶段抢键；`Alt+Shift+[` / `]` 与 `Alt+Shift+S` 可行。`registerFixed` 只负责显示（它不做 region/modal/repeat 过滤），所以全部守卫写在 `observeFixedInput` 里：`gesture.repeat/composing/defaultPrevented/control/meta` 任一成立就放行原事件；`context.region !== 'page'` 让位给输入框；`context.modal !== null` 让位给菜单/对话框（`modalSelector` 含 `role=menu`）；两条都过了才 `input.consume()`。`S` 还要求 `shortcuts.overlayEnabled === true`（默认关）。

**暴露成客户端服务**（让别的插件 `ctx.get('hotlist')`）：本插件目前**没有** provide 任何 Cordis 服务；官方服务的写法是 `class X extends Service { constructor(ctx){ super(ctx,'uiWorkspace') } }`（`dsh-client-ui-workspace/lib/client.js:1361/1382`）。照此加一个 `Service` 子类并在 `apply()` 里实例化即可；建议只暴露只读的 `classify`/`snapshot()`，不要暴露 adapters。

## 12. 版本与标记（验收脚本依赖）

- `VERSION`（`client.js:82`）→ `window.__HOTLIST_VERSION__`（`client.js:6020`，旧名别名 `window.__SESSION_SWITCHER_VERSION__` 下一行 `client.js:6021`）、座位 body 的 `data-hotlist-seat` / `data-hotlist-version`（`client.js:6317-6318`）、设置页根 `data-hotlist-settings="v5.3.1"`（`client.js:4985`）。
- 设置页行选择器 `[data-hotlist-row]`；侧栏 marker `span[data-hotlist-glyph]`；我们注入的样式都带 `data-hotlist-style`（`sidebar` / `takeover` / `page`）。浮层 kit 的样式块是唯一例外：`id="hotlist-popout-kit-style"` + `data-hotlist-kit="style"`（`injectKitStyle`，`client.js:5138-5145`），见 §14。

## 13. v4.6 已落地与还没接的行为

设置页是 **6 张**折叠卡（`data-category`，可多开）+ 全局区，紧凑多列排版（真机折叠 44px、展开 514/466px，目标 ≤520px）；浮层已接线（§14）+ 完成时间已落盘（§15）；动效按类抽签（§16）；音效与素材池（v4.2）、两条循环热键（v4.3）都已接上。侧栏与 tab 现在读同一份事实：`refresh()` 把 `readSession` 算好的 `pinned` 与 `children` 一路传进 `sidebarStateOf`（`sidebarStateOf` 定义 `client.js:3519`，侧栏侧调用 `client.js:3519-3530`，tab 侧调用 `client.js:3519-3533`），所以置顶会话在侧栏也出 📌、子会话在跑时父会话在侧栏也出 ⏳——v4.4 之前这两个参数在侧栏路径上漏传，两边会对同一会话给出不同状态。

v4.4 是维护批：设置页删掉 `hideNativeDot` / 快捷键 / 恢复默认三块，收录窗口搬成全局「最近对话展示时间」，动效间隔换成 0–100% 的播放频率滑块，预览改成按频率常驻循环，`plan.overflow` 提示条删除（字段仍在）。**注意"删"的是 UI 行**：`hideNativeDot` 与 `shortcuts{jumpEnabled,overlayEnabled,overlayKey}` 字段仍在设置记录里（`client.js:7635`、`client.js:7635`），`sanitizeSettings` 仍认它们（`client.js:1741-1759`），`nativeDotVisible` 仍由 `hideNativeDot` 派生（`client.js:3799`），侧栏仍照它加 `data-hotlist-hide-native`（`client.js:3799`）。v4.5 再删「弹出图尺寸」一行：`overlay.sizeMin/sizeMax` 字段与 `show()` 取中值的算法都保留，只能走 API；内置音效从「每类 7 条 mp3 随机」改成两个 wav 一对一映射（`pending` / `error` → `attention.wav`，`completed` → `complete.wav`，其它类别没有声音，常量 `BUILTIN_SOUND` 见 `client.js:345`）。

v4.6 是结构批：①类别 7 → 6，`favorite` 整类删除（`RETIRED_PATHS`，`client.js:201`），类别形状同时去掉 `reserved`/`pinLevel`/`within`（§10）；②手写 `pins` 表废弃，改读宿主 `pinnedSessionIds`，并新增 `pinned.maxSeats`；③判定优先级定为 `error > pending > completed > running > pinned > idle`（`classify()` `client.js:2646-2668`，侧栏同序 `client.js:2646-2659`）；④新增"用户设置永不覆盖"的 preserved + backup 两层（§10.1 / §10.2）与 plan 的 37 行绝对硬闸（§5）。

v4.6.4 只补了 §10.3 那一块：出厂预设（`💤` / `blink` / `none` / `motionTarget: 'glyph'` / 频率 `1` / 音效关）不再当成用户选择，老安装因此真正拿到 v4.6.3 的新默认；用户改过的值一个不动。**没有新 UI、没有升 `SETTINGS_VERSION`、没有迁移**。

v5.0.0-alpha.1 只补 §10.4：`choices` 记录用户真正动过的字段，闸门改成「等于旧预设 **且** 没被选过」，于是 `none` / `blink` / 「仅图标」/ 频率 100% / 关音效这些和旧默认同值的选项终于能落地，没动过的字段照旧跟随新预设。**没有新 UI、没有升 `SETTINGS_VERSION`、没有迁移**；4.6.4 未发布，对外是「4.6.3 → 5.0.0-alpha.1」。

v5.2 加超级提醒（`ring.*` 三开关 + `index.js` 的 `/hotlist-ring` 路由 + `tools/attn-ring/`），v5.3 加耳机门禁（`audio.smart` + `/hotlist-audio` 路由 + `tools/audio-endpoint/`，链路见 §21）；两次都只是加字段加路由，**没有升 `SETTINGS_VERSION`、没有迁移**。

仍是「只存值不接行为」的：`shortcuts.jumpEnabled`（`Alt+1–9` 被占用）、`shortcuts.overlayEnabled`（热键照常工作，设置页没有这一行）、`overlay.fallbackImage`（没有 UI）、`hideNativeDot`（没有 UI 行，值有效）。**`surfaces.topbar` 与 `positions.topbar` 从 v5.0.0-alpha.1 起已接上行为**（§18）；反过来 `topbar.mode` 与 `topbar.rightReservePx` 变成「只有 API、没有 UI 行」的两个字段。

## 15. 「刚完成」为什么要持久化

`✅ completed` 是热表自己算出来的：宿主只把 `completionUnread` 维护 1–3 分钟、打开会话立刻清（`dsh-client-ui-session/lib/client.js:964-981`），不够用。所以热表自己记 `running true→false` 与 `completionUnread false→true` 两个跳变（`observeCompletion`，`client.js:6176`），时间放 `completedAt` Map。

- **拒绝 / 中断也算「完成」**：判定只看 `running true→false`（`observeCompletion`，`client.js:6176`），与「为什么结束」无关。用户拒绝审批导致会话结束时，该会话进 ✅（我们的自记 `completedAt`），**不是** ⛔；⛔ 只覆盖自采的 `api-session/error`（agent 级错误）。语义是对的：用户处理完了，就该从 tier1「等你」掉下来。

**只在内存里放会丢一个真问题**：页面一重载（改设置、刷新、端口重启）所有 ✅ 都变回 idle，用户看到的"刚跑完"列表凭空消失——这正是 v4.1 之前的行为，验收里被判为缺陷。于是：

- 键名常量 `COMPLETED_AT_KEY`（`client.js:4020`），值 `{version, entries: {<sessionId>: <ms>}}`；该常量写成正则字面量并取 `.source` 落盘——预重启闸门会先抹掉字符串再搜键名，写成普通字符串它就看不见（RegExp 直接当 key 用会把两侧斜杠带进 localStorage）。
- 读（`readCompletedAt`，`client.js:2124`）：按 `collect.completedTtlMs` 剪掉过期、丢掉非字符串 id / 非有限时间戳、坏 JSON 整体回落空表，**永不抛**。
- 写（`persistCompletedAt`，`client.js:2137`）：500ms 合并（`COMPLETED_FLUSH_MS`，`client.js:4022`），一批跳变只落一次盘；`forgetFinished(id, true)` 是"用户已经打开这个会话"的路径，**同步落盘**，不能让 ✅ 在盘上多留一秒；插件卸载时 `flushCompletedAt()` 兜底。
- 剪枝还看工作区：`snapshot.workspaceIds` 里没有的 id 一律 `forgetFinished`——别的窗口的完成表不属于这个窗口。
- **列表没拉完就不许剪枝**：`sessions.list` 快照带 `phase`（`dsh-api-session-controller/lib/client.js:2995` 构造时 `'pending'`，`:3283` 首拉 `session.list` 成功才 `'ready'`）。`observeCompletion` 开头 `if (snapshot.list.phase !== 'ready') return;`（`client.js:3768`）——否则 reload 后首轮 sync 拿着"只到了几行"的快照，把刚从盘上读回来的时间戳全判成"会话不存在"删掉。真机日志：1201ms 时 `rowN=8 / tabN=0` 就写回了 `{}`。单测 `completedAt persistence` 覆盖三条：pending 不剪、ready 才剪、当前会话同步删。
- 只持久化 completed。`error` 是 live-only（重连不补发），`idle` 是时间窗口，都不该落盘。

## 16. 动效为什么是"抽签"而不是"常亮"

旧做法是给每个座位加 CSS 无限动画并按 `maxAnimated` 截断，结果是整屏图标一起转、看不出重点。现在：

- 每个类别有自己的 `glyph.frequency`（0–1、步进 0.05、默认按类：置顶 0.3 / 报错 0.9 / 待处理 0.9 / 已完成 1 / 进行中 1 / 闲置 0；1 = 每个节拍都播、0 = 该类永不动）。侧栏适配器仍是 1s ticker，但不再按时间记账：**每个类别每 tick 掷一次**骰子 —— `roll = Math.random()`，`roll >= frequency` 就跳过，命中后用同一个 `roll` 从该类里挑**一个**座位播一遍单程动画（`MOTION_MS{spin:2400,pulse:1600,bounce:1200,blink:1200}`，`client.js:3289`）。所以单测能精确断言「每类每 tick 恰好一次随机调用」；`frequency` 为 0 的类连骰子都不掷。
- 并发上限 `MOTION_CONCURRENCY=4`（`client.js:325`）：四个座位正在动时，后来的类跳过（它已经掷过骰子，只是不再 `startBurst`）。
- `reduceMotion: 'on'` 一次全停且不再掷；`display:hidden` 时 ticker 只切暂停属性；卸载/`stop()` 清掉所有 burst 定时器。
- 动画本身仍是纯 CSS（`hl-spin` 等 + 单程变体 `hl-spin 2.4s linear 1`）。`row` 目标用 `hl-text-*`：只改 `opacity` 与 1–2px 的 `translate`，**不加 `scale`**（文字放大会发虚）。v4.3 之前这里只动 `opacity`，真机上看起来「标题根本没动」，v4.4 加了小位移才看得出；这也是 `motionTarget` 设为 `row` 时一直保留这个选项、没有被藏进 API 的原因。
- 键名 `data-hotlist-burst` 标记"这一轮正在动"，验收脚本与单测都靠它数并发；标题上的 `data-hotlist-text-motion` 标记文字动效。
- **预览**是同一套频率的可视化：`previewStyle()`（`client.js:4050`）在 `previewKeyframes()`（`client.js:4033`）生成的 20 档 `@keyframes hl-pv-<motion>-<step>` 之间选一档（`PREVIEW_STEPS=20`，`client.js:4024`）——`step = round(frequency * 20)`，动画时长按 `20 / step` 拉长，于是「动作时间 ÷ 周期」正好等于频率；`frequency = 0` 时 `glyphNode` 直接不给 animation（`previewStyle` 自身会把 0 夹到 1 档，无法表示"不播"）。它用 `linear infinite` 常驻循环，所以设置页一打开就能看到频率的实际感觉，滚出视口/卸载即随节点消失。

## 14. 浮层（popout）：素材、kit 与调用方分工

素材与 kit 的权威副本都在 cangku（不属于发布物）：设计稿 `cangku/tmp/hotlist-art/popout-kit.js`，接线契约 `cangku/tmp/hotlist-art/v4-popout-integration.md`。进插件的是**内联副本**（`client.js:848-1317`，kit 段横幅注释在 `client.js:5509-5522`）：`TIERS` / `SCALES` / `KIT_TIMING` / `KIT_CSS` / `mountPopout` 等逐字照抄，只加了一个选项 `isReduced`（产品级 `display.reduceMotion` 推导不出系统偏好，由调用方算完传进来）。改动画常量要两边一起改，并同步 `assets/manifest.json`。

- **素材**：`assets/<category>-<tier>.webp`（`TIERS=[64,320,780,1560]` `client.js:5017`，选档由 `tierFor(cssPx,dpr)` 算）；离线或缺档回落到 `assets/<category>.svg`（`fallbackRef`，`client.js:5077`），再回落 emoji（`KIT_EMOJI`，`client.js:5023`；回落链 `client.js:5023-5045`）。`assetRef`（`client.js:5072`）拼的是 `plugins/dsh-better-notice/assets/…`，由 `makeResolveAsset`（`client.js:5477`）区分三种输入：`data:` 原样、`builtin:<cat>` 或空串走内置、其余当 asset id；**任何分支都不抛**。实际加载走模块 loader 的 `require.asset`（`@deepseek-ai/dsh-client-modules/lib/client.js:844`），热表在 popout effect 里注入（`client.js:848`）。
- **尺寸**：v4.1 起由全局 `overlay.sizeMin/sizeMax` 决定——`show()` 取两者中值传给 kit（`size`），不再有 `overlay.scale` 倍数；`resolvePopoutSide` 决定左右。v4.5 起设置页删掉了「弹出图尺寸」这一行（用户当场否掉这个设置），字段与算法都保留，只能走 API 改。
- **谁决定什么**：kit 只画一只「人」，不管时机。调用方 `createPopoutController`（`client.js:5502`）负责——`resolvePopoutSide`（`client.js:5483`）把 `auto` 解析成左右（量左侧会话栏 `.mP3x-q_sidebarCol` 的 `getBoundingClientRect().width > 40`，量不到就 left）；单槽 + 优先级 `POPOUT_PRIORITY{error:3,pending:2,completed:1}`（`client.js:5495`，高优先抢占、低优先**直接丢弃不排队**）；同会话同类别 10 秒冷却 `POPOUT_COOLDOWN_MS`（`client.js:5496`）；只有会话**首次进入**某类别才触发（`seen` Map 记住上一轮，离开即清）；`displayMs` 由调用方 `setTimeout` 收，回调先比单调 `seq` 再关（旧定时器绝不能关掉新浮层）；`document.hidden` 时不弹，只 log。
- **关闭只有一条路**：`dismiss(exit)` → `kit.close(exit)` → kit 播完退场动画后调 `onDone`；`onDone` 里清 timer、置 `showing=null`。手动点图（`onActivate`）与超时共用这条；点图先 `openSession(showing.sessionId)` 再 `dismiss()`。设置一改就 `settingsChanged()`（`client.js:5673`）：开着就关，且**不自动重开**。
- **DOM 契约（验收脚本依赖）**：外壳节点永远带 `data-hotlist-popout` 与 `data-hotlist-popout-cat="<类别>"`，另有 `data-side`（left/right）与 `data-reduce-motion`（0/1）（写入点 `client.js:1882-1890`，外壳 `client.js:1882-1907`）；图片再带 `data-hotlist-fallback`（`webp`/`svg`/`emoji`）；样式块 `id="hotlist-popout-kit-style"` + `data-hotlist-kit="style"`（`KIT_STYLE_ID`，`client.js:5031`；注入 `injectKitStyle`，`client.js:5138-5145`）；`onDone` 之后节点必须真的从 DOM 移除（`client.js:5539-5540` 连样式一起删），否则会留一块透明可点区域。挂载根 `document.body`，`z-index:2147483000`（`client.js:2761`）。
- **降级**：`display.reduceMotion === 'on'` 或系统 `prefers-reduced-motion` 任一成立 → 入场只走 `--hl-enter-ms:120ms` 的淡入、退场固定 `fade`，粒子不生成。所以 `isReduced` 是「系统 OR 产品」的合并结果，而不是二选一。粒子仍按 `size >= 520` 判定（不是按乘法器）。
- **已知边界**：`popout.entrance` 只读（固定 clip 揭示，设置页显示灰字「固定为探出」）；弹出图出自每类多素材池（v4.2 起），每次事件**随机**取一张（`pickPopoutArt`）。


## 17. 图标定种、弹出图与音效随机

三条取用规则不一样，改的时候别混：

- **图标是身份 → 稳定**：座位 / 侧栏的图标来自 `glyph.uploads[]`，种子是 `"<sessionId>|<category>"`（`resolveStateGlyph`，`client.js:2003`；`fnv1a`/`pickIndex`，`client.js:1963/1403`）。同一会话在同一类别里反复渲染永远是同一张，刷新也不换——**不要**把时间锚塞回种子（v4.2 曾经是 `|<enteredAt>`，结果是每次进类别都换图，真机看到"闪"）。
- **弹出图是事件 → 每次随机**：一次弹层 = 一次事件，`pickPopoutArt`（`client.js:1974`）用 `randomIndex` 从 `popout.images[]` 里取；`builtin:true` 时走内置 `assets/<cat>.svg`，池空且非内置才回落 emoji。
- **音效是事件 → 固定映射**：`pickSoundUrl`（`client.js:1987`）在 `pending/error` 返回 `/hotlist-sound/attention.wav`、`completed` 返回 `/hotlist-sound/complete.wav`（映射 `BUILTIN_SOUND`，`client.js:345`；`SOUND_URL` `client.js:344`；路由在 host `index.js`）；空池回落内置，其它类别直接返回空串（不制造 404）。

配额与去重：每类池上限 `ASSET_POOL_MAX=6`（`client.js:330`）、弹出图 64KB（`POPOUT_MAX_BYTES` `client.js:332`）、音效 128KB（`SOUND_MAX_BYTES` `client.js:333`）、图标 16KB（`GLYPH_MAX_BYTES` `client.js:306`）、总预算 2MB（`ASSET_TOTAL_MAX_BYTES` `client.js:335`）（裁剪 `trimAssetBudget`，`client.js:1507`，按类别从 sound→popout→glyphSecondary→glyph 的尾部裁剪）。音效另有冷启动首轮只记不播（armed）与 1500ms 全局节流（`SOUND_THROTTLE_MS`，`client.js:349`），写在 `createSoundPlayer`（`client.js:5735`）。

## 18. 窗口顶栏（`shell.overlay`）：命中测试 + 分层，而不是固定 left

顶栏不是一个面板，是往宿主窗口那条 40px 标题带里塞一排胶囊。它挂在宿主的 `shell.overlay` slot 上（`TOPBAR_SLOT`，`client.js:115`；条目 id `hotlist.topbar`，`client.js:7724`；`order:-10`，`client.js:2713`，要抢在宿主自己的顶栏内容之前）。

三条硬约束决定了实现形状：

1. **不能挡住拖拽。** 那 40px 是窗口原生拖动区。band 自己是 `pointer-events:none` 的透明层，只有胶囊接收事件并标 `-webkit-app-region:no-drag`。**给 band 加背景 = 用户拖不动窗口**，属于「看起来更精致但更糟」。
2. **左边界不能靠猜。** 宿主菜单/工具栏的宽度随平台与窗口宽度变，任何写死的 `left` 都会在某台机器上盖住菜单。`occupiedLeft()`（`client.js:3406`）用 `elementsFromPoint` 在 `TOPBAR_PROBES`（`client.js:149`，`[0, 60, 250, 700]`）几个点上做命中测试：**只有贴左边缘、且宽度 ≤ `OCCUPIED_MAX_WIDTH`（`client.js:145`，480）的元素才算占位**——全宽布局容器也会命中，但那不是「菜单占了我的位置」。`bandLeft()` = `occupiedLeft() ?? measuredLeft() ?? fallbackLeft()`（`client.js:3383`），`leftSource()`（`client.js:3442`）报告来源是 `occupied` / `menu` / `fallback`，验收脚本看的就是这个字段。
3. **右侧给窗控让路，且写死。** `WINDOW_CONTROLS_GUARD = 138`（`client.js:133`）是最小化/最大化/关闭那一簇的宽度，**不做成设置项**：用户调错了按钮就被盖住，且不同 DPI 下这簇宽度不由我们决定。可用宽度算式是 `width - model.left - model.reserve - WINDOW_CONTROLS_GUARD - 8`（`client.js:133`）。

**胶囊宽度是算出来的，不是排出来的。** `chipWidthOf()`（`client.js:950`）= `CHIP_PAD*2 + 码点数*CHIP_CHAR`，夹在 `CHIP_MIN 72` / `CHIP_MAX 140`（`client.js:155-156`）；`fitChipCount()`（`client.js:964`）拿到一串宽度与可用宽度后，**先预留 `+N` 那颗**（`MORE_WIDTH`，`client.js:159`）再决定能放几颗，所以放不下时是折叠而不是挤爆。`topbar.chipWidthPct`（`-30…+30`）只缩放这两个界，**0% 必须与旧版逐字节一致**（单测 `pill width follows the setting` 守这条）。

**两个面并存、互不顶替。** `surface` 参数走的是 `buildSeatPlan({surface})` → `classify({surface})`（`client.js:2647` `input.surface ?? 'tab'`，逐类用 `categoryVisible(settings, category, surface)` 把关，`client.js:2647`）：`'topbar'` 只收 `error/pending/completed`，`'tab'` 只收 `pinned/idle`，`running` 在两面 `surfaces.topbar`/`surfaces.tab` 都是 `false` 所以哪面都不去。顶栏开着时 tab 行**不是消失**，而是只剩它该显示的那几类——这就是「同一会话不会在两个面各画一次」的实现方式。

**浏览器里的预览。** `positions.topbar` 默认 `true`，但真正挂载还要 `html[data-windows-titlebar]`；浏览器里只有当 `topbar.previewInWeb` 为真才挂。macOS 没有这条带，将来也不会有。

**标签三档与「只出现一颗 emoji」。** `topbar.titleMode` ∈ `text|icon|custom`（`TOPBAR_TITLE_MODES`，`client.js:121`；旧名映射 `TITLE_MODE_ALIASES`，`client.js:123`）。`leadingEmoji()`（`client.js:2057`）只取标题开头那颗（`\p{Extended_Pictographic}` + 变体选择符/ZWJ/肤色/区域指示符），`stripLeadingEmoji()`（`client.js:2103`）把它剥掉；`customIconWins()`（`client.js:2051`）是「这一类是否允许用标题自带 emoji」的闸门。三者组合的结果是：**无论哪一档、哪一类，一个名字前面永远只有一颗 emoji**（三处调用点：座位标签 `labelOf`、侧栏 marker、胶囊 `chipLabelOf`）。

**验收探针**：`window.__HOTLIST__.topbar()`（`client.js:7724` 起）把 `mounted / mode / titleMode / left / leftSource / measured / reserve / currentId / capacity / chips` 一次交出来，不用去 DOM 里猜。

## 19. 超级提醒（原名全屏提醒）：为什么要单开一个进程

界面上叫**超级提醒**，内部仍叫 ring / `/hotlist-ring`，因为它的祖先是一圈琥珀色光环——名字换了，字段名、路由名与脚本参数都没有换，读代码时别把两者当成两个功能。

需求是「有待处理 / 有报错 / 有会话跑完时，整块屏幕提醒我一下」。网页里的元素做不到这件事：宿主 UI 是浏览器视图里的一个 div，任务栏、别的窗口、别的显示器都在它外面。所以提醒**不是 DOM**，是一个独立进程画的 WPF 窗口。

**两种长相，默认是动画。** v5.2.1 起默认 `-Anim Gif`：播一段 320×320、透明底的循环片段——`error` 与 `pending` 共用 `smack.gif`（拍击，10 帧），`completed` 用 `wave.gif`（挥手，11 帧），30 ms 一帧，画在屏幕正中、高度约屏幕的三分之一（`$artD = Round(Min($dipMin*0.34, 340))`），**不铺暗底也不画光圈**。`Expand` / `Breathe` / `None` 三档原样保留，画的还是那圈带光晕的琥珀色光环。素材缺失或解不开时脚本把 `$Anim` 改回 `Expand` 并在 stderr 记一行，所以坏的安装退回光环，而不是什么都不显示。两份 GIF 在 `tools/attn-ring/media/`（合计 ~780 KB），由 `tools/attn-ring/build-media.py` 生成，**随 npm 包发**。

**三段式，边界清楚：**

1. **浏览器半边只发一个请求**（`createRingPlayer()`，`client.js:5884`）。它复用声音播放器的边缘检测：同一个 `RING_CATEGORIES`（`client.js:259`）三方集合、同样的「跳过空会话与子代理」、同样的优先级 `error > pending > completed`、同样的 1500 ms 节流（`RING_THROTTLE_MS`，`client.js:270`）。命中就 `fetch('/hotlist-ring?…')`。
2. **宿主半边只管起进程**（`index.js:167` `serveRing`）。它不判断状态——那个判断在浏览器那边已经做完了，宿主只看「这条请求该不该真的弹窗」。
3. **脚本只管画**（`tools/attn-ring/Show-AttnRing.ps1`）。378 行、零依赖、四个参数：`-Seconds` / `-Scope Primary|All` / `-Anim Expand|Breathe|None|Gif` / `-GifCategory error|pending|completed`（只有 `Gif` 档用得上，用来挑片段；非法值由 `ringArgs()` 在宿主半边回落成 `pending`），点一下或 Esc 自己关。

**三道闸，每一道都对应一条真实风险：**

1. **必须带 `x-hotlist-ring: 1` 头**，否则 403。没有这一条，任何网页只要写一个 `<img src="http://127.0.0.1:<port>/hotlist-ring">` 就能弹一个全屏窗口出来——本机所有浏览器上下文都能这么做，因为静态路由不鉴权。
2. **2.5 秒冷却**（`RING_COOLDOWN_MS`，`index.js:46`），连发返回 429。多个会话同时进错态时，不该叠十个提醒窗口。
3. **脚本缺失就 503**（`spawnRing` 里 `existsSync` 先判）。装了插件但包里没带脚本 = 静默什么都不发生，而不是抛异常。

**`spawn` 的两个必写项（踩过，别再删）：**

- **`stdio: 'ignore'`**：Windows 沙箱禁命名管道，`'pipe'` 会 EPERM。
- **必须挂 `child.on('error')`**：spawn 失败（pwsh 不在 PATH）时没有监听器会**直接打死 host 进程**，整个 GUI 消失。
- **不要 `detached: true`**：Windows 上 detach 之后 pwsh 约 200 ms 静默退出、脚本一行没跑、exit code 还是 0（实测）。

**三个开关走 `choices`。** `ring.*` 与图形界面里其他开关一样，用户点过就写进 `choices`（`choicesFromPatch`），所以「出厂预设覆盖」规则不会把用户打开的开关关回去。出厂三个全 `false`：**默认不打扰**是这条功能的前提，全套九处提醒（座标 / 图标 / 声音 / 弹出图 / 光圈）里只有它盖住整块屏幕。

**平台边界：** 只有 Windows 能用（PowerShell + WPF）。其他平台点了开关也不会响，代码里不做假动作去模拟。多显示器时只盖主屏（`-Scope Primary`）——这一点与档位无关，动画档也一样。

**节流是两份，不是共用。** `RING_THROTTLE_MS`（`client.js:270`）与 `SOUND_THROTTLE_MS`（`client.js:349`）都是 1500 ms，但它们是两个常量、各有一份 `lastAt`。共用一份会让「刚响过声音」把光圈压掉，而那正是最该弹的时候。

## 20. 顶栏胶囊的动效：常驻一层 + 抽签一层

侧栏图标和 tab 座位的动效是**抽签**的：每类按 `glyph.frequency` 掷一次，命中才播一遍（见 §16）。顶栏胶囊不是——**它只要挂在屏幕上就一直在动**，频率命中时再**多补一次**。这不是漏改，是刻意的：一条静止的胶囊带挨着会动的侧栏图标，用户会以为顶栏坏了。

**两层写在同一个样式表里**（`CHIP_CSS`，`client.js:6995-7022`，注释在 `:6175-6195`）：

```css
/* 第一层：常驻。属性在创建时就写上，不需要 JS 每帧参与 */
[data-hotlist-chip][data-hotlist-chip-target="emoji"][data-hotlist-chip-motion="spin"] [data-hotlist-chip-emoji] { animation: hl-spin 2.4s linear infinite; }
/* … 四个 motion × 两个 target = 八条 … */

/* 第二层：抽签命中时的一次性爆发。多一个 [data-hotlist-chip-burst] 就够 */
[data-hotlist-chip][data-hotlist-chip-burst][data-hotlist-chip-target="emoji"][data-hotlist-chip-motion="spin"] [data-hotlist-chip-emoji] { animation: hl-spin 2.4s linear 1; }
/* … 同样八条 … */
```

三个决定，都是踩过之后定下来的：

1. **两层之间不用 `!important`。** 靠**特异性**分开：爆发那层多一个 `[data-hotlist-chip-burst]`，自然盖住同一条属性上的常驻规则。整套里唯一用 `!important` 的是最后那行减动效盖子——它必须盖过一切，这一点与 `SIDEBAR_STYLE`、设置页预览的减动效行写法一致。
2. **`data-hotlist-chip-motion` / `-target` 在创建时就写**（`client.js:6867-6868`），不是等动画要播了才写。CSS 选择器要能命中「静止的那一帧」，否则第一次渲染是没动效的，用户会看到一下顿帧。
3. **`data-hotlist-chip-burst` 只写在真的在播的那一颗上**（`client.js:6870`），播完由渲染自然摘掉。写在容器上会让整排一起爆发。
4. **keyframes 跟着 band 自己的样式表走**（`injectChipCss()` `client.js:7024`，`removeChipCss()` `client.js:7033`），所以侧栏适配器关掉时顶栏照动；`@keyframes hl-spin/hl-pulse/hl-bounce/hl-blink` 与 `hl-text-*` 各八条都在 `CHIP_CSS` 里自带，**不依赖 `SIDEBAR_STYLE` 是否注入**。
5. **减动效两条盖子、都盖到子节点**：`html[data-hotlist-reduce-motion] [data-hotlist-chip], html[data-hotlist-reduce-motion] [data-hotlist-chip] *`（`:6221`）与 `@media (prefers-reduced-motion:reduce)`（`:6222`）各一条，同时管住胶囊本身、图标 span 与标题 span——只写容器会漏掉真正在动的子节点。

**`hl-chip-nudge` 已删除**：它是早期「只播一次」方案的产物，与常驻层叠在一起会互相打断。现在只有常驻与爆发两层。

**验收**：单测 `pills keep their class animation, and a burst plays it once`（`test:4101` 附近）查两层都在、`hl-chip-nudge` 不存在、减动效覆盖到子节点。

## 21. 耳机门禁（`audio.smart`）：一条链路，六个可能断的地方

`audio.smart` 打开后，提示音**只在默认输出设备真是耳机时**才响。链路是六段（最后一段的用户清单见 §22），每段都能独立坏掉，且**坏掉的默认结果统一是静音**：

```
设置 audio.smart ──► 客户端门禁 audioGateAllowed ──► 宿主路由 /hotlist-audio
                         （:5712）                      （index.js:serveAudio）
                                                                │
                                          宿主持 60 秒缓存 ◄──┤ TTL（AUDIO_PROBE_TTL_MS = 60 * 1000）
                                                                ▼
                                              PowerShell + Core Audio（tools/audio-endpoint/）
                                                                │
                                                                ▼
                                     { state, kindGuess, name, error } ──► 回填 audioProbe
```

**1. 设置**（`client.js:904` `audio: { smart: false }`）出厂关。开关走 `choices`（`CHOICE_KEY` 多了 `audio\.smart` 一支），所以用户自己开的就是「用户的选择」，出厂预设覆盖规则不会把它关回去。

**2. 客户端门禁**（`audioGateAllowed(settings, probe, at, config)` `client.js:5712-5733`，六个判据依次判，任一不满足就拒）：

| 顺序 | 条件 | 拒绝理由 `reason` |
|---|---|---|
| 0 | `settings.audio.smart !== true` | 放行，`reason: null`（开关关着，门禁不存在） |
| 1 | `probe === null \|\| at - probe.at > AUDIO_PROBE_TTL_MS` | `'audio-unknown'`（没探测过，或探测结果超过 60 秒） |
| 2 | `probe.state !== 'measured' \|\| probe.error != null` | `'audio-unknown'`（探测跑了但没测出来，或脚本报错） |
| 3 | 清单可用且清单里点了耳机 → 当前设备名必须命中清单（§22.4） | `'not-headphones'`（不在白名单里） |
| 4 | `probe.kindGuess !== 'headphones'`（只有清单不可用时才走到这一步） | `'not-headphones'` |

**3. 门禁在节流之前**（`play()` `client.js:5792`）：先判每类的 `sound.enabled`，再判门禁，**最后**才判 `at - lastAt < SOUND_THROTTLE_MS`。所以被门禁拒掉的那次**不写 `lastAt`、不消耗 1500 ms 窗口**——用户戴上耳机后第一次状态变化立刻就能响，不用等节流窗口过期。

**4. 宿主路由**（`index.js:295-312`）：`GET /hotlist-audio`，必须带 `x-hotlist-audio: 1`（`:297` 否则 403 `no-marker`）；缓存新鲜（`AUDIO_TTL_MS = 60 * 1000`）就直接返回 `{ ok: true, cached: true, ... }`；否则起一次探测，**并把旧值（或 `unknownAudioPayload('measuring')`）立刻返回**——播放路径永远不等探测，宁可这一声按「未知」处理成静音。

**5. 探测**（`spawnAudioProbe()` `index.js:228-278`）：`spawn(resolvePwsh(), [...], { stdio: ['ignore', fd, 'ignore'], windowsHide: true })`，**stdout 走临时文件的 fd 而不是管道**——受限沙箱禁止命名管道，用 `stdio: 'pipe'` 会直接失败。脚本缺失时缓存 `error: 'script-missing'` 而不是每次重试。

**为什么「不知道」也算拒绝。** 会误判的场景恰好是插件对着会议室外放的场景，所以宁可静音：`kindGuess: 'speakers'` 与 `state: 'unknown'` 在门禁眼里都是「不许响」，用户能通过 `window.__HOTLIST__.audio()` 看出是哪一种。

**试听不走门禁。** `preview(category)`（`client.js:5857-5871`）只查 `pickSoundUrl`，**不调用** `audioGateAllowed`——它本来就绕过冷启动闸和 1500 ms 节流，现在也绕过耳机门禁。理由：那是用户自己按下的按钮，用来确认素材能出声；门禁也拦它的话，用户在扬声器下就没法验证音效是否正常。**门禁只作用于自动播放。**

**四种日志名，用来自查**（`log()` 的第一参数，`createSoundPlayer` 里）：

| 日志 | 行 | 含义 |
|---|---|---|
| `off` | `:5795` | 该类的 `sound.enabled` 关着，连门禁都不问 |
| `skip` | `:5802` | 门禁拒播，第二参数是 `'audio-unknown'` 或 `'not-headphones'` |
| `throttle` | `:5808` | 1500 ms 节流窗口内，丢弃（第三参数是距上次的毫秒数） |
| `mute` | `:5813` | 没解析出可播 URL |
| `play` | `:5817` | 真的播了，第三参数是 URL |
| `preview` / `preview-mute` | `:5864` / `:5861` | 设置页试听：已播 / 该池没 URL |
| `armed` | `:5848` | 冷启动首轮只记录不播（避免打开页面就响一串） |
| `failed` / `blocked` | `:5821` / `:5787` | `<audio>` 播放失败 / 浏览器拒绝自动播放 |
| `audio-probe-failed` | `:5758` | 探测请求本身失败（网络/宿主没回） |

**验收**：单测 `the audio gate is off by default and only lets headphones through`（`test:4749` 起）覆盖六种判定组合与「被拒时不消耗节流」；`the audio probe is scriptable and answers before any probe has run`（`test:4863` 起）覆盖 `audio()` 在探测前也返回结构完整的对象。

## 22. 音频配置链路（设备清单）：一个文件，六个派生状态

门禁的第六步（§21 第 2 节判据 3）会先读一份**用户自己的设备清单**：清单里写着哪些是耳机，默认输出就必须**按名字命中**清单里的耳机才放行。这份清单**不是设置项**，是一个文件——它由用户自己的 AI 在插件之外生成，结构、体积和更新频率都不适合塞进 `localStorage`（`PRESERVED_KEY` + `BACKUP_KEY` 会把几十台设备名抄五份进每一次写盘）。

### 22.1 文件在哪、谁写、谁读

```
<DSH_HOME>\hotlist-audio.json        ← 用户自己的 AI 写
        │                              （设置页「{配置}」复制提示词，AI 跑脚本后写）
        ▼
宿主 readAudioConfig()（index.js:365）──► GET /hotlist-audio/config（index.js:425）
        │                                   ▲
        │  按 mtime 缓存（index.js:87）      │ 必须带 x-hotlist-audio: 1，否则 403
        ▼                                   │
客户端 refreshAudioConfig()（client.js:484）──► audioConfig（模块级，:372）
                                                    │
                          ┌─────────────────────────┴─────────────────────────┐
                          ▼                                                   ▼
          设置页那一行 audioConfigRow()（:4777）              门禁第六步 listedHeadphones()（:5725）
          「未初始化 / 已配置 N 个（耳机 M 个）」                有清单就按名字做白名单
```

- 目录解析 `dshHomeDir()`（`index.js:76`）：`process.env.DSH_HOME`（**trim 后非空**）优先，否则 `join(homedir(), '.dsh')`。和宿主 `@deepseek-ai/dsh-home-paths` 同序；空白字符串按「未设置」处理——只判 `!== ''` 会让 `'   '` 拼出一个相对路径。
- 文件名 `audioConfigFile()`（`index.js:82`）= `<dshHomeDir()>/hotlist-audio.json`。
- **插件永远不写这个文件**：不创建、不改写、不删除、不备份。它只读，并且只把「读到了什么」回给页面。
- 枚举脚本 `tools/audio-devices/audio-devices.ps1`（`index.js:63`）**只属于提示词那一侧**，宿主自己从不执行它；宿主只做两件事——读文件、把脚本的绝对路径经响应里的 `script` 字段告诉页面，页面再把它填进提示词。

### 22.2 文件形状与八条容错

```json
{
  "version": 1,
  "updatedAt": 1731561600000,
  "devices": [
    { "name": "耳机 (Baseus Bass BC2 Stereo)", "direction": "render", "group": "headphones", "kindGuess": "headphones", "guess": false },
    { "name": "扬声器 (Realtek(R) Audio)", "direction": "render", "group": "speakers", "kindGuess": "speakers", "guess": false }
  ]
}
```

| 字段 | 取值 | 说明 |
|---|---|---|
| `version` | 必须是 `1` | 不是 `1` 就是 `invalid`（`index.js:397`），不猜未来格式 |
| `devices` | 数组 | 单个对象也收（当一条，`index.js:403`） |
| `devices[].name` | 非空字符串 | 名字是**唯一**用于匹配的东西（`index.js:348`） |
| `devices[].direction` | `render` / `capture` | 宽容映射：`output`/`playback` 等 → `render`，其余 → `render`（`normalizeDirection` `index.js:330`） |
| `devices[].group` | `headphones` / `speakers` / `capture` / `other` | **不在四值里一律 `other`**，绝不猜成耳机（`normalizeGroup` `index.js:339`） |
| `devices[].kindGuess` | 字符串 | 原样保留，只做诊断 |
| `devices[].guess` | 布尔 | 页面用它显示「其中 N 个是推断的」 |

`readAudioConfig()`（`index.js:365-422`）的**八条容错**，没有一条会抛：①文件不存在 → `exists:false`（不是错误）②UTF-8 BOM 剥掉（`index.js:386`）③JSON 解析失败 → `valid:false` + `error` 首行前 200 字符（`index.js:389`）④不是对象 / 是数组 → `invalid` ⑤`version !== 1` → `invalid` ⑥`devices` 不是数组（且不是单对象）→ `invalid` ⑦单条坏行丢掉、其余照收（`index.js:409`）⑧方向/分组拼错名 → 规范化到四值。

**除真正的运行时异常外，一律 `ok: true`**——"文件坏了"和"宿主挂了"是两件事，客户端不该把前者当后者。

### 22.3 六个状态是派生出来的，从不存储

`audioConfigStateOf(config)`（`client.js:438-445`）是**纯函数**，`state = f(一次响应)`：

| 顺序 | 条件 | 状态 | 页面说的是 | 门禁怎么做 |
|---|---|---|---|---|
| 1 | 还没有任何响应（`config === null`） | `hostDown` | 「读不到状态」 | 不拦（只有非 Windows 才拦，见下） |
| 2 | `config.platform !== 'win32'` | `unsupported` | 「仅 Windows 可用」 | 直接 `audio-unknown`（不播） |
| 3 | `exists !== true` | `missing` | 「未初始化 · 按系统类型判断」 | 退回 `kindGuess` 分支 |
| 4 | `valid !== true` | `invalid` | 「文件格式不对」 | 退回 `kindGuess` 分支 |
| 5 | `headphoneCount > 0` | `ready` | 「已配置 {devices} 个（耳机 {headphones} 个）」 | **白名单**：名字没命中就不播 |
| 6 | 其余（有耳机字段但没有一条是耳机） | `empty` | 「已配置，但没标出耳机」 | 退回 `kindGuess` 分支 |

状态**不进设置、不落盘、不缓存到下一次**：每次响应重算，所以删掉文件后下一次自动重读就会回到 `missing`，不会留着一条已经不成立的「已配置」。页面那一行也用同一个函数（`audioStatusText()` `client.js:4725`），因此页面显示和门禁判断永远同源。

### 22.4 名字三级匹配：精确 → 归一相等 → 双向包含，短边至少 6 个字符

`deviceNameMatches(left, right)`（`client.js:408-420`）配合 `normDeviceName`（`client.js:393-401`）：

1. **精确**：两边 `trim()` 后完全相等。
2. **归一相等**：`normDeviceName` 去掉括号里的内容（ASCII `()` 与全角 `（）`，最多四层嵌套，`client.js:395`）、把连续空白压成一个空格、`trim()`、转小写，然后比较。
3. **双向包含**：归一后长的一边包含短的一边，**且短的一边长度 ≥ `AUDIO_DEVICE_MIN_MATCH`（6）**（`client.js:363`、`:418`）。

门槛的理由写在常量注释里：Windows 真有一台设备就叫「耳机」，`"耳机"` 去包含 `"耳机 (Baseus Bass BC2 Stereo)"` 永远是 `true`；没有下限的话，一个类名词就能给任何设备开绿灯。反过来 `"Baseus Bass BC2 Stereo"` 与 `"耳机 (Baseus Bass BC2 Stereo)"` 也**不**匹配——括号里的型号是系统加的尾巴，不是设备身份。

`listedHeadphones(config)`（`client.js:423-435`）只认 `direction === 'render' && group === 'headphones' && name.trim() !== ''`；清单 `valid` 但不是数组时返回 `null`（=「清单不能回答」，退回类型判断，而不是「没有耳机」）。

### 22.5 刷新机制：3 秒超时的一次性请求 + 60 秒的暖循环

**客户端**（`refreshAudioConfig()` `client.js:484-518`）：

- `audioConfigBusy` 去重（`:485`）：同一时刻只有一次在飞，重复调用直接返回。
- `AbortController` + `setTimeout(AUDIO_CONFIG_TIMEOUT_MS = 3000)`（`client.js:365`、`:488-498`）：3 秒不回就当失败——设置页那一行**永远不转圈等人**。
- 请求带 `?ts=Date.now()` 与 `x-hotlist-audio: 1`（`:502-503`）：前者绕开 HTTP 缓存，后者是宿主那道闸。
- 任何失败（非 2xx、解析失败、abort）都把 `audioConfig` 置 `null`（`:508-512`）→ 状态变 `hostDown`。**刻意不保留旧值**：留一条上次的「已配置」比说「读不到」更糟。
- `finally` 里 `notifyAudioConfig()`（`:516`）→ 订阅者（`audioConfigListeners`，设置页在 `:4328` 订阅）重渲染。

**暖循环**：`warm()`（`client.js:7589-7592`）每 `AUDIO_PROBE_TTL_MS`（60 秒）跑一次，既 `prefetch()` 探测、也 `refreshAudioConfig()`（`:7592`），`setInterval(warm, AUDIO_PROBE_TTL_MS)`（`:7595`），卸载时 `clearInterval`（`:7597`）。所以 AI 在背后写完文件，**最迟 60 秒**页面自己变；不用关设置页，也不用重启。

**手动**：那一行的「重新读取」按钮就是调 `refreshAudioConfig()`（定义在 `client.js:484`，按钮接线 `:4803-4805`）；`invalid` 状态下点「{重新配置}」也会顺手再读一次（`:4761`）——提示词刚被复制走，文件可能正要变。

### 22.6 宿主响应与客户端摘要

`serveAudioConfig()`（`index.js:425-453`）返回：

```js
{ ok, exists, valid, path, directory, script, platform, updatedAt,
  deviceCount, headphoneCount, guessCount, devices,
  ...(reason), ...(error) }
```

- `path` / `directory` 是**解析后的绝对路径**（`index.js:436-437`）：页面不自己拼路径（浏览器读不到 `DSH_HOME`，也拿不到本地绝对路径）。
- `script` = `existsSync(AUDIO_DEVICES_SCRIPT) ? 绝对路径 : null`（`:431`）：找不到脚本时给 `null`，绝不把空串塞进提示词。
- `platform` = `process.platform`（`:439`）：**客户端不用 `html[data-windows-titlebar]` 判平台**——那只说明「顶栏能不能画」。
- 无 `x-hotlist-audio: 1` 头 → `403 no-marker`（`:427`）；处理过程中抛异常 → `500` + `reason: "error"`（`:451`）。
- 路由用**一个前缀两个答案**：`/hotlist-audio` 与 `/hotlist-audio/config` 共用一个 prefix 注册（`index.js:516-524`），`serveAudioRequest()` 按 pathname 分派（`index.js:461-470`）——不用 `prefix` 的匹配顺序来裁决。

客户端对外的只读摘要 `audioConfigSummary()`（`client.js:448-477`）就是 `window.__HOTLIST__.audio().config`：`{ status, exists, valid, path, script, platform, deviceCount, headphoneCount, guessCount, updatedAt }`。**排障先读它**：`status` 一句话说明「文件那侧看到了什么」，比猜「为什么没响」准。

### 22.7 配置是叠加，不是前置

没有文件、文件坏了、清单里一台耳机都没标——**一律退回原本的类型判断**（`audioGateAllowed` 的兜底分支 `:5731`），提示音照旧会响。清单只做两件事：把「类型猜错」的情况纠正过来，以及在清单明确的情况下把白名单收紧。所以「不配置就哑巴」是一个**不存在**的失败模式。

提示词里的两个占位符由宿主给值，客户端只做替换（`audioPromptText()` `client.js:521-541`）：`{{CONFIG_PATH}}` → `config.path`，`{{SCRIPT_PATH}}` → `config.script`；`script` 为 `null` 时换成一整句「插件没找到脚本，请按下面的搜索片段自己找」，**不留下 `{{` 或半截路径**。宿主完全不可用时才退回 `%USERPROFILE%\.dsh\hotlist-audio.json`，并加一句「以你实际的 DSH 目录为准」。复制走两级兜底（`copyPromptText()` `client.js:548`）：`navigator.clipboard`（需要安全上下文，LAN 地址不是）→ 临时 `textarea` + `execCommand`，两级都失败就把文本展开成只读 `textarea` 让用户自己复制。

### 22.8 验收

- `audio config: the six states are derived, never stored`（`test:4937` 起）：六态逐个喂进去，含 `null` / 非 win32 / `headphoneCount` 0 与 >0。
- `audio config: device names match in three levels, and short names never match`（`test:4953` 起）：三级匹配与 6 字符下限，含 `耳机` vs `耳机 (Baseus)` 与括号尾巴不算身份。
- `audio config: a configured headphone list becomes a whitelist for the gate`（`test:4980` 起）：清单命中放行、清单里的扬声器即使探针猜成耳机也拒、空清单退回探针、非 win32 拒、开关关着放行。
- `audio config: the prompt never leaks a placeholder or a home directory`（`test:5017` 起）：中英两版都不留 `{{`、有绝对路径时不出现 `%USERPROFILE%`、`script:null` 时整句替换。
- 真机：改文件 → 不点任何按钮 → 最迟一个 `AUDIO_PROBE_TTL_MS` 周期后那一行自己变；点「重新读取」立即变；删掉文件 → 变回「未初始化」而不是留着旧状态。

