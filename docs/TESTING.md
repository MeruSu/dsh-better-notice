# 热表测试指南

分两层：能在 Node 里跑的（单测，快、必须过），和只能在真机 GUI 上看的（单测替代不了）。

## 1. 单测

```powershell
cd <你的克隆目录>            # 含 client.js / index.js / test/ 的那一层
node --check client.js
node --check index.js
node --check test/classify.test.mjs
node test/classify.test.mjs       # 期望最后一行: PASS — 126 groups，exit 0
```

`node --check` 是必须的：`client.js` 是包在 `window.__ModuleLoader__.load({factory})` 里的单文件脚本，语法错只在真机 boot 时才炸。

patch 校验（js-yaml 从本机 profile 借，把 `<profile 目录>` 换成你自己的，例如 `~/.dsh/profiles/desktop/node_modules/noop.js`）：

```powershell
node --input-type=module -e "import {createRequire} from 'node:module';import fs from 'node:fs';const r=createRequire('<profile 目录>/node_modules/noop.js');console.log(JSON.stringify(r('js-yaml').load(fs.readFileSync('cordis.patch.yml','utf8'))))"
```

期望 `[{"insert":[{"id":"hotlist","name":"dsh-better-notice"}]}]`。

### 1.1 测试怎么加载真代码

`test/classify.test.mjs` 不用 import：它 stub 一个 `window.__ModuleLoader__.load` 抓住 factory，再 `new Function(source)()` 执行**真实的 client.js 源文件**，拿回模块的导出（`classify`、`sortSeats`、`buildSeatPlan`、`sanitizeSettings`、`migrateSettings`、`createSidebarAdapter`…）。所以测的是真代码，假的是浏览器环境：`document` / `localStorage` / `React` / cordis `ctx`。

### 1.2 126 组各测什么

| 组 | 位置 | 覆盖 |
| --- | --- | --- |
| heal view preferences | `test:546` | 加载时把遗留座位 id（`hotlist-seat-*` / `seat-*` / `session-switcher` / `hotlist`）的 view 偏好改回 `chat`，用户自己选的 `trajectory` 与无关键原样保留 |
| settings read/write | `test:556` | 默认值形状（`version:4`、**没有** `states`/`showIdle`/`placement`、`positions` 三键、`overlay{side,sizeMin:260,sizeMax:520,fallbackImage}` 无 `enabled`、`sound.volume`、`pinned.maxSeats:3`、`categories` 恰好 **6 个键**、`idle.surfaces.tab` **true**）；越界归一（`maxSeats:40→12`、`pinned.maxSeats:99→12`）；v3 扁平补丁（`showIdle` / `completedTtlMs` / `states.approval` / `states.question`）落到对应类别；`resetSettings()` 回默认 |
| migrate v3 to v4 | `test:595` | v3 逐项迁移：`approval→pending.glyph`、`question→pending.glyphSecondary`、`plan-review`/`subagents` 丢弃、`running.motion` 保留；v3 内联图 → `glyph.uploads[0]`（名 `legacy`）且 `source:'upload'`、`value` 回类别默认 `✅`；`overlay.scale:4` 倍数 → `sizeMin:260`/`sizeMax:900`、`customImage→fallbackImage`、`shortcut→shortcuts.overlayKey`、`overlay.enabled:true` → `pending/error/running` 三类 `popout.enabled`；写回后 `states`/`glyphs`/`motion`/`placement` 一个不留，二次读与首次一致 |
| current version keeps custom order | `test:659` | 已是 v4 的记录原样保留用户改过的 `categories.error.order:5` 与 `idle.enabled`，不再走迁移 |
| alpha version 5 normalizes safely | `test:675` | alpha 工件的 `version:5` 安全归一成 `4`，保留它写下的 `categories.error.order`，其余回默认 |
| bad data falls back | `test:690` | 逐字段回落：`version:'five'→4`、`maxSeats:'many'→6`、`positions.tab:'yes'→true`、`overlay.side:'up'→auto`、`scale:99→sizeMax:900`、svg `fallbackImage→''`、TTL `-5→60000`、`pinned.maxSeats:400→12`、`pending.order:500→99`、`kind:'animated'→emoji`（`value` 保留 `x.gif`、`uploads` 清空）、超 8 字 emoji → `''`；未知类 `nope` 与已退役的 `favorite` 都不进 `settings.categories`，保留键里也不留 `categories.favorite` |
| seven categories | `test:731` | **6 类**各出一行（`pinned:pinned`/`pending:approval`/`error:error`/`completed:completed`/`running:running`/`idle:idle`），置顶来自宿主 `pinnedSessionIds`；`idle` 是窗口：正好 5 分钟收、多 1ms 不收 |
| pending merge and subagents | `test:793` | `approval`/`question`/`plan-review` 三态归 `pending`（token 分别 `approval`/`question`/`question`）；父会话有子代理在跑 → `running:running`；pending 共 3 行 |
| pinned follows the configured order | `test:824` | 在 `surface:'sidebar'` 下用宿主置顶列表 `['s1','s3']`：**默认** `pinned.order=60` 排在 `idle(50)` 之后，所以两个置顶会话都判成 `idle`（座位 order `5001/5002`、token `idle`），只有 running 的 `s2` 是 `3001`；把 `categories.pinned.order` 调成 5 后同一批会话变成 `pinned`（order `501/502`，按置顶列表顺序），`s2` 仍是 `3001 running` |
| category order | `test:856` | `error.order=5`、`pending.order=20` → 座位 order 变 `501`/`2001`，展示顺序跟着 `categories.<id>.order` 走 |
| plan limit and current session | `test:878` | 非紧急类按 `limit` 截断、紧急类（`error`/`pending`）照常出座：`limit:2` → 类别序列 `error,error,pending,running,running`、`plan.overflow===1`；`currentId` 指定的当前会话不占座位 |
| urgent overflow hard cap | `test:910` | 紧急类不受 `limit` 限但受 `limit + ALWAYS_OVERFLOW(4)` 硬顶：`limit:1` + 7 个 pending → 5 座（`p1`…`p5`）、`plan.overflow===2` |
| surface gating | `test:928` | 每类 `surfaces.tab`/`surfaces.sidebar` 单独生效（`idle.surfaces.tab:false` 后 tab 只剩 running，侧栏仍有 idle）；`positions` 全关 → `allPositionsOff===true` 且 `surfaceVisible===false` |
| idle third tier on the tab row | `test:971` | 默认 `idle.surfaces.tab===true` + `collect.recentWindowMinutes===5`：窗口内普通会话在 `surface:'tab'` 下产出 `idle` 行；窗口 0 不产出；`idle.surfaces.tab:false` 不产出 |
| labels | `test:989` | `labelOf`：token 的 emoji + 标题（`🔐 写入工作区外审批` / `❓ 选一个`），无标题用「未命名会话」；`glyph.kind:'img'` 时 tab label 回落该类别 emoji |
| sidebar priority | `test:1000` | `sidebarStateOf` 优先级：`approval`/`question`（`plan-review` 折成 question）/`running`/`completed`/`error` 都压过 `pinned`，**只有 `idle` 排在置顶之后**；`running.surfaces.sidebar:false` 时退回 `idle`；超窗口的老会话 → `null` |
| settings sanitizing | `test:1033` | `sanitizeSettings` 纯函数容错：`maxSeats:'auto'` 保留、gif 收、svg 拒（回落 emoji 且 `value:''`）、`popout.displayMs:123456→20000`、`entrance:'nope'→slide`、`sound.kind` 不保留（只留 `enabled`/`builtin`/`uploads`）、`sound.volume:400→100`、`recentWindowMinutes:500→120`、`motion:'wiggle'→bounce`、v3 `overlay.scale` 无对应（`sizeMin/sizeMax` 回默认）、`overlay` 里没有 `enabled`、`categories.pinned.order` 默认 **15**（不再是强制的 0） |
| settings surface | `test:1077` | `window.__HOTLIST_SETTINGS__.get()` 可用、`override()` 测试缝（9 / 恢复 6 回默认）；旧的 `dsh.session-switcher.settings`（`version:3`）被读走且旧键删除，`resetSettings()` 也会清掉它 |
| adapter plan | `test:1097` | tab 适配器整体（async）：座位 order `[['s2',3001],['s1',5001]]`、通过公开 settings 面关掉 `running.surfaces.tab` 两轮内少一座、再开回来恢复；点座位切会话（mount 与 pointer 双路径，`opened` 去重后只有 `s1`、视图回 `chat`）；`openSession` 拒收时把消息写进 state 而不抛 |
| adapter sidebar markers | `test:1159` | marker 插在标题前、`data-hotlist-char` 是当前状态图标（🔐 / ⏳）、`data-hotlist-hide-native` 落在行上、`refresh()` 后仍只有一个 marker、`stop()` 把 marker 与行属性全还原 |
| adapter sidebar pinned and children | `test:1196` | 侧栏看到与 tab 一样的信息：置顶会话出 📌、有子会话在跑时父会话出 ⏳ |
| takeover gate | `test:1228` | `takeOverStatusDot:true` 时 `[data-hotlist-style="takeover"]` 恰好 1 个且 dsm 点 `display:none`；改成 `false` 后 style 块被移除、点的 inline `display` 还原成 `''` |
| styles stay valid | `test:1259` | 所有注入的样式文本不含 `[[`（二次包裹的选择器），`stop()` 后 `[data-hotlist-style]` 一个不剩 |
| settings page | `test:1295` | section 注册 `[['hotlist',30]]`、label「热表」、页根 `data-hotlist-settings="v5.3.5"`；全局区行键齐（`maxSeats`/`pinned.maxSeats`/`collect.completedTtlMs`/`sound.volume`/`recentWindow`/`positions.tab`/`positions.topbar`/`takeOverStatusDot`）；**6 张卡**按 order 排 `error,pending,pinned,completed,running,idle`；折叠态 **30 个 chip**（6×5，其中 6 个是 topbar 位：`data-disabled="true"` + `data-on="false"`，位置 chip 的 `title` 是 `settings.chip.positionHint`）；`hideNativeDot`/`shortcuts.*`/`reset`/`within`/`overlay.size` 五类行**不存在**；`categories.favorite` **不存在**；`window.__HOTLIST__.assets.add(...,'nope',...)` 返回 `reason:'invalid'` |
| settings page card order | `test:1365` | 改 `categories.error.order = 5` 后卡片顺序是 `error,pending,pinned…`（error 与 pending 同为 10，按 `CATEGORY_ORDER` 兜底），末位 `idle` |
| settings page overflow notice | `test:1379` | v4.4 删掉了提示条：`publishOverflow`/`currentOverflow`/`onOverflowChange` 都不再导出、页面无 `[data-hotlist-overflow]`、文案里没有 `settings.overflow`；但 `plan.overflow` 的数字仍在（`limit:1` + 3 行 → `overflow===2`） |
| settings upload gate | `test:1400` | `glyphUploadReject`：`null`→`missing`、svg→`type`、**gif 放行**、webp 5 MB→`size`；超限 data URL 在 `sanitizeSettings` 里回落 `emoji` 且 `value:''`。上传是**两道闸**：源文件大小与产物（重编码后）大小 |
| settings reset drops legacy keys | `test:1413` | 盘上写入带 `states`/`glyphs`/`motion`/`placement`/`showIdle` 的记录后 `resetSettings()`：存储是 `version:4`、`maxSeats:6`，旧键一个不留 |
| settings maxSeats applies at once | `test:1435` | （async）`writeSettings({maxSeats:2})` 后两轮 `tick()` 座位数 3 → 2，改回 6 恢复 3（两级延迟注销） |
| popout side resolution | `test:1481` | `resolvePopoutSide`：`left`/`right` 直通；`auto` 量左侧会话栏（量不到或塌陷 → `left`，够宽 → `right`）；配套 `tierFor`（260→320、780→1560）、`assetRef`/`fallbackRef`（`plugins/dsh-better-notice/assets/error-320.webp` 与 `error.svg`）、`dropDistance` |
| popout priority arbitration | `test:1508` | 单槽抢占：`completed` 弹后 `pending` 抢占、`error` 再抢占；低优先遇到高优先**直接丢弃不排队**；同级换会话 |
| popout seq guard | `test:1524` | 旧 `displayMs` 定时器回调不能关掉新浮层（单调 `seq` 比对） |
| popout reduce merge | `test:1557` | `display.reduceMotion:'on'` 与系统偏好合并成 `isReduced`：`data-reduce-motion="1"`、`--hl-enter-ms:120ms`、退场固定 `fade`（`exit-fade` 有、`exit-drop` 无）；系统偏好为假时 `data-reduce-motion="0"` |
| popout cooldown | `test:1579` | 同会话同类别 10 s 冷却（9999 ms 拒、10001 ms 放行）；另一个会话是不同的键，不受冷却 |
| popout first entry only | `test:1591` | 只在会话**首次进入**类别时弹：一直 `pending` 不重弹；当前会话不弹；换类别且冷却已过才弹；`error` 压过它替换掉的 `pending` |
| overlay size sanitising | `test:1624` | `overlay.sizeMin/sizeMax`：越界夹到 120–900、`min>max` 自动交换（200/900）、缺省回落默认。**v4.5 只删了设置页那一行，schema 与算法照旧，这一组仍要跑** |
| playback frequency sanitising | `test:1639` | `glyph.frequency`：`0→0`、`0.42→0.4`（0.05 步进）、`0.65` 原样（不是预设就是选择）；**`1` 与越界的 `9` 都落回 `pending` 的当前默认 `0.9`**（`1` 是 v4.4 出厂预设）；旧 `motionIntervalMs` 换算（`2000→1`、`8000→0.9`、`60000→0`，**`0` 仍是 0 而不是 1**）且换算后旧字段不写回；旧的全局 interval 分发到各含该字段的位置（`0.5`） |
| glyph source resolution | `test:1673` | `glyph.source` 三态：`upload` 用 data URL、`popout` 用该类别弹出图（`builtin:<cat>` 解析成打包素材）、`emoji` 用文本；空 emoji 回落类别内置图标 |
| sidebar motion is the shared continuous plan | `test:1709` | 5.3.5 起三处同走 `motionPlanOf`：3 行侧栏 glyph 的 `data-hotlist-motion` 按类别（pending=bounce / running=spin / error=bounce）、内联 `animation-duration`（1200/2400ms）与 `animation-delay`（`calc(-1 * motionPhaseOf(...))`）；**`Math.random` 零调用**（burst 已删，无 `[data-hotlist-burst]`）；`reduceMotion:on` → 全 `none` + 空；`frequency:0` → 全 `none` + 空；`frequency:0.05` → spin 48000ms 且仍零随机 |
| settings page multiple open cards | `test:1794` | `sessionStorage['dsh.hotlist.open']` 存 JSON 数组：多张卡同开、未知 id 被过滤、旧版本写的裸字符串按单元素数组读 |
| settings page densified rows | `test:1821` | 展开态排版：`.hl-rowMulti` 的 `--hl-cols` 同时出现 `3`（弹出/动效组）与 `2`（图标来源/尺寸）、`.hl-cell` ≥10；全局区有 `recentWindow` 且**没有** `within`；**没有** `overlay.size`、**没有** `positions.sidebar`、**没有** `categories.favorite`；`popout.entrance` 是只读文本，6 张卡各一条 `settings.popout.entranceFixed` 提示 |
| settings page has no reset row | `test:1855` | v4.4 删掉「恢复默认」行：没有 `reset` 行、没有 `[data-hotlist-reset]`；但 `__HOTLIST_SETTINGS__.reset()` 仍能写回默认（API 保留） |
| completedAt persistence | `test:1874` | （async）`✅` 时间落盘：同一轮两个会话完成只写一次、成为主视图立刻删除并落盘（第二次写不等节流）、重启后按 TTL 与工作区剪枝；列表 `phase` 还是 `pending` 时一律不剪枝（reload 不得把读回的条目写成空），`ready` 后不存在的会话才剪 |
| no undefined constants | `test:1968` | 静态扫描：剥掉注释/字符串后，任何 `[A-Z][A-Z0-9_]{2,}` 引用都必须有声明（`node --check` 抓不到的整类崩溃，2026-11-11 真出过一次） |
| module boot smoke | `test:1990` | 模块 id 是 `dsh-better-notice`；`readSettings()` 在坏 JSON 上回落默认（`version:4`、`maxSeats` 默认）、v3 记录上安全迁移（`overlay.sizeMin/sizeMax` 260/520）都不抛 |
| sound player dedupe | `test:2012` | 冷启动首轮只记不播（armed）、同会话同类是重绘不响、离开再进入响一次（`/hotlist-sound/attention.wav`、`volume 0.6` 来自全局 60）、1.5 s 内第二声静音并记日志、试听绕过前两闸、`enabled:false` 的类不响、无内置也无上传时 `pickSoundUrl` 返回 `''` |
| seeded and random asset picks | `test:2075` | 图标定种哈希（同 seed 同下标、不同 seed 分散）、`randomIndex` 边界（1→0、5→4）、`pickSoundUrl` 只对 pending/error/completed 拼 URL（`BUILTIN_SOUND` 形状）、`pickPopoutArt` 三态（内置/上传 data/emoji） |
| asset quotas | `test:2110` | 每池 6 份（第 7 份被拒、保留最早的）、图标 16 KB、弹出图 64 KB、音效 128 KB、2 MB 总预算按类别顺序裁剪（先删音效再动图片）；图片冒充音效被拒；空名补成 `glyph-1` |
| asset migration | `test:2145` | v4.1 单图 → `glyph.uploads[0]` 并 `source:'upload'`、`popout.image` → `images[0]` 且 `builtin:false`、`sound.kind:'builtin'` → `builtin:true`、旧每类 `volume` → 顶层 `sound.volume` |
| shortcut cycle and guards | `test:2169` | 三条热键按 `registerFixed` 登记（`{code, modifiers:['alt','shift']}`、`group:'application'`）；循环只走当前 plan、当前会话不占座位；`region`/`modal`/`repeat`/`control`/`defaultPrevented` 全部放行原事件；`shortcuts.overlayEnabled` 关时 `KeyS` 不被吞 |
| glyph seed ignores time | `test:2236` | 上传图标定种只依赖 `sessionId|category`：同一 seed 连渲染 5 次同图、`kind` 仍是 `img`；源码里不再出现 `enteredAt` |
| shortcut edges | `test:2252` | 空 plan 不消费任何键；单座环绕自身；多座 `a→b→c→a` 回绕；缺 shift 或缺 alt 不消费、无关 code 忽略；没有 `shortcuts` 服务时热键注册数为 0 而座位照常注册 |
| shortcut labels are thunks | `test:2315` | 三条 `registerFixed` 命令的 `label` 是**惰性 thunk**（`typeof label === 'function'`、调用返回非空字符串），id 与 `bindings[0].code` 是 `hotlist.cycle.prev/next/overlay.once` ↔ `BracketLeft`/`BracketRight`/`KeyS` |
| recent window migration and clamping | `test:2340` | 全局 `collect.recentWindowMinutes`：旧每类 `within:30` 迁到顶层且类字段不再存在、旧默认 `5` 走 5、显式值优先、`500` 夹到 120、`-4` 夹到 0；0 时 idle 一行都不产出 |
| preview loop lifecycle | `test:2366` | 预览按频率常驻循环。这一组用 `completed`（`blink` 与频率 `1` 是 v4.4 出厂预设，v5.0.0-alpha.1 会替换它们，拿 `pending`+`blink` 测不出常驻）：100% → `hl-pv-spin-20 2400ms linear infinite`、50% → `hl-pv-spin-10 4800ms linear infinite`、0 或 `reduceMotion:on` → 没有 `animation` |
| motion target row reaches the title | `test:2406` | `motionTarget:'row'` 真的动到标题：标题拿到 `hl-text-blink 1.2s ease-in-out 1` 与 `data-hotlist-text-motion`，行上同时有 1 个 `[data-hotlist-burst]`；样式表里 `@keyframes hl-text-bounce` 含 `translateY`（不再只动 opacity） |
| settings page writes land immediately | `test:2445` | 页面控件写的是同一个 store：数字框/复选框 `onChange` 后 `readSettings()` 立刻反映（`recentWindow:30`、`maxSeats:1`、`positions.tab:false`），座位类改动两轮 `tick()` 内 tab 行跟着变（3 → 1 → 0） |
| plan hard ceiling keeps the priority head | `test:2500` | 硬顶 37 行（`PLAN_MAX_ROWS`）：60 个 idle + `limit:40` → 恰好 37 行、`overflow===20`；加入 1 个 error 后 `plan[0].category==='error'`、被挤掉的是尾部 `idle-36`、头部 `idle-0` 还在 |
| defaults never overwrite stored values | `test:2532` | 改默认值不等于改用户设置：所有类别默认 `glyph.motionTarget` 是 `'row'`；盘上存了 `pulse` + `frequency:0.35` 时 sanitize 原样保留（两者都不是任何一代预设；`'glyph'` 与 `1` 属于旧预设，归下一组管） |
| user settings are never overwritten | `test:2561` | 本版表示不了的也保留：`maxSeats:40` 活动值夹到 12，但**原始 40 与未知键 `experimental` 都留在保留键里**（`outOfRange.maxSeats={raw:40,clamped:12}`）；写入旧整块进 backup 环（1 条、`version:4`） |
| legacy default order is adopted, real choices are kept | `test:2595` | 逐类判断「等于历史默认就算没选过」：`pinned 1→15`、`pending 20→10`、`completed 30→20`、`running 40→30`；用户真填的 `42`/`7`/`60` 一概不动（`idle` 从没有旧默认，60 就是用户输入）；整块老 blob 里 `pinned 0→15`、`error 10` 不变 |
| recent window UI bounds match the API | `test:2624` | 两层范围且 UI 不再收窄：设置页 recentWindow 数字框 `min===1`、`max===120`（与存储层同界）；随后 `writeSettings({collect:{recentWindowMinutes:90}})` 之后 `readSettings()` 与盘上都是 **90** —— 页面只是入口，不是数据上限 |
| defaults for v4.6.3 | `test:2651` | 六类出厂预设表：`pinned/error/pending` 动效 `bounce`、`completed/running` `spin`、`idle` `none`；频率 `0.3 / 0.9 / 0.9 / 1 / 1 / 0`；`motionTarget` 六类全 `'row'`；音效默认 `error/pending/pinned/completed` 开、`running/idle` 关；`idle` 图标是 `🧊`、`sound.volume` 60 |
| factory presets are replaced, user choices are kept | `test:2680` | 另一半规则（出厂预设不是选择）：一份 v4.6.3 写出的存档里 `💤`→`🧊`、`blink`/`none`→`bounce`/`spin`、`motionTarget` 的 `glyph`→`row`、`frequency:1`→该类默认、音效 `false`→四个响类的默认 `true`；用户真改的值（`🌙`、`pulse`、`0.15`、`true`、order `7`）一个都不动；两个 glyph 槽各有自己的表（`none` 只在主槽是预设，在副槽是选择）；同一份输入再喂一遍结果逐字节相等 |
| user picks survive the preset rule | `test:2766` | v5.0.0-alpha.1 的 `choices` 标记：`writeSettings({categories:{error:{sound:{enabled:false}}}})` 之后读回来仍是 `false`（旧版会回弹成 `true`），`choices` 里正好一条 `categories.error.sound.enabled`；`none` / `blink` / `glyph` / 频率 `1` / `💤` 这些与旧预设同值的选项都能落地；只标了 `motion` 时邻居 `motionTarget` 仍跟随 `row`；`backups()`/`restore(0)` 连标记一起回滚；`resetSettings()` 后 `choices` 为空且预设重新生效；二次 sanitize 逐字节相等；`sanitizeChoices` 丢弃 `false`、非法形状与超长键 |
| topbar band coexists with the tab row | `test:2894` | 顶栏与 tab 行**并存**：同一个 ctx 里 `hotlist.topbar` 与 `hotlist-seat-*` 同时注册，谁都不顶替谁；顺带验证模块加载时把遗留座位 id 的 view 修回 `chat` |
| topbar needs the desktop strip or an explicit preview | `test:2967` | `positions.topbar` 默认 `true` 但浏览器里不画：没 `data-windows-titlebar` 又不给 `topbar.previewInWeb` 时 band 不挂载；`mode:'chips'`、`rightReservePx:0` 是默认 |
| topbar overflow counts pills and +N walks the hidden ones | `test:3022` | 胶囊量宽与折叠：`chipWidthOf('')===72`（下限）、`'abcd'===72`（24+4×12 恰好）、`'abcdefgh'===120`、40 字符与 10 个 emoji 都封顶 `140`；`fitChipCount([72,72],100)===1`（要给 `+N` 留 44）、`([72,72,72,72,72],400)===5`、`(…,300)===3` |
| topbar settings are clamped | `test:3109` | `topbar` 归一化：未知 `mode`、非布尔 `previewInWeb`、`rightReservePx:9999→400`、`-20→0` 全部回落；`mode:'count'` 保留 |
| topbar pills have no frame and skip the current session | `test:3135` | 胶囊不画外框（背景与边框留空，只有文字与图标），且当前会话不占胶囊——顶栏只提示「别的会话」 |
| category topbar switch decides who shows | `test:3184` | 每类 `surfaces.topbar` 单独开关：关掉某类，它立刻从 band 消失但 tab 行不受影响；`running` 无论如何都不进 band |
| pill width follows the setting | `test:3217` | `topbar.chipWidthPct` 是百分比不是像素：`0` 与旧版逐字节一致（72/140 两界不变）；`-30` → `72*0.7=50`、40 字符 `140*0.7=98`；`+30` 反向变宽 |
| icon can be emptied and each category resets on its own | `test:3244` | 图标可清空：`kind:'emoji'` 值 1/2 码点收、**3 码点拒成 `''`**；`kind:'none'`+`value:''` 是「明确清空」，读图标时任何来源都不再回落；每类「重置这一类」只回滚该类 |
| four new settings fields default and clamp | `test:3309` | 四个新字段：`scope:'smart'`、`positions.topbar:true`、`topbar.titleMode:'custom'`、`topbar.maxSeats:6`，且 `version` **仍是 4**（走默认值分支，没升版）；`sanitizeSettings({scope:'nope'})` 回 `'smart'` |
| scope persists across a reload | `test:3339` | `scope` 三值逐轮写盘再读回都一致、经一次 sanitize 也不变；写 `scope` **不动**盘上的 `positions.topbar`（两件事互不覆盖） |
| scope three-way semantics | `test:3352` | `scope` 三档语义：`workspace` 只留当前工作区（`out-1` 被裁）；`all` 全工作区且**跨工作区置顶仍是 pinned**；`smart` 会话本身仍在，但**跨工作区置顶被降级成 idle** |
| titleMode reaches the pills | `test:3426` | 三档真的画到胶囊：`custom` 与 `icon` 都有 emoji 列（每颗 1 个）+ 1 个标题段；`text` 的 emoji 列归零而标题段仍在；band 节点带 `data-hotlist-title-mode`；`window.__HOTLIST__.topbar().titleMode` 报的是实时值 |
| settings page shows the new rows | `test:3464` | 页面按 `positions.topbar` 决定 band 段去留：开着时 `scope`/`topbar.titleMode`/`topbar.maxSeats` 三行都在；关掉后只剩 `scope`（它是全局行，永不消失） |
| console export defers to explicit ids | `test:3501` | 导出**只听 ids**：显式给 `ids:['a']` 时 JSON 解析成长度 1 的数组，页面上的 scope / 当前会话都不参与决定导谁 |
| session export is deterministic and safe to call bare | `test:3516` | 导出裸调用不抛：`exportSessions()` 返回 Markdown 字符串、以 `\uFEFF` 开头（BOM，Notion 粘贴中文不乱码）、表头是 `\uFEFF| displayTitle |`；标题里的 `|`、`\t`、`\n` 被安全处理；同一输入两次输出逐字节相等 |
| every seat count uses the same stepper | `test:3608` | 六个数字行共用同一个 stepper：`maxSeats`/`pinned.maxSeats`/`topbar.maxSeats`/`collect.completedTtlMs`/`sound.volume`/`recentWindow` 每个都有 1 个 `data-hotlist-stepper`、`['minus','plus']` 两颗按钮与同一个 `hl-input hl-num` 值框 |
| the band takes the urgent classes and the tab row the background ones | `test:3631` | 分工靠 `surface` 参数：`buildSeatPlan({surface:'topbar'})` 只收 `error/pending/completed`，`surface:'tab'` 只收 `pinned/idle`，`running` 两边都没有 |
| the band mounts with pills next to the tab row | `test:3656` | 真挂载：`previewInWeb:true` 时 `window.__HOTLIST__.topbar()` 报 `mounted:true`、`chips:[{id:'pv-ask'}]`（只有 pending 那颗），band 里真画出 1 颗胶囊，而 idle 会话的 `hotlist-seat-pv-idle` 仍在——两个面同时存在 |
| label modes draw exactly one emoji | `test:3687` | 一个 emoji，绝不两个：`leadingEmoji('✏️UI 大师')==='✏️'`、没有 emoji 时 `''`、空输入 `''`；`stripLeadingEmoji` 剥后是 `'UI 大师'`；三档与 scope 组合下 `labelOf` 只出现一颗 emoji |
| label mode names and their aliases | `test:3741` | 三档正名与别名：`TOPBAR_TITLE_MODES===['text','icon','custom']`；`TITLE_MODE_ALIASES==={unified:'text',two:'icon',smart:'custom',auto:'icon'}`；四个旧名经 sanitize 都落到对应新名 |
| custom scope decides per category | `test:3758` | `customScope` 逐类生效：关掉 `idle` 后 idle 座位拿到类别图标 `🧊 大聪明`，而 `pinned` 座位仍用标题自带的 `🎓 大聪明`；六类可以同时全关 |
| the scope row only exists in custom mode | `test:3778` | scope 行只在 `custom` 档出现：`custom` 时页面有 6 颗 `data-hotlist-scope` chip；换成 `text` 或 `icon` 时整行归零（那时候它不起作用） |
| pills strip the title emoji the same way | `test:3811` | 胶囊与座位同一套规则：`icon` 档 emoji 列是类别图标 `🧊`、标题段为 `大聪明`（标题自带 🎓 被剥）；`custom` 档 emoji 列消失、标题段变回 `🎓 大聪明`；把 idle 移出 scope 后类别图标又回来 |
| the band never starts under the menu | `test:3855` | 左边界是**命中测试**不是估算：`elementsFromPoint` 命中一块 right=262 的元素时 `occupiedLeft()===270`、`bandLeft()===270`、`leftSource()==='occupied'`；全宽容器（left 280 / right 1844）**不算**占位，不会被当成左边界 |
| label mode labels name what they draw | `test:3889` | 三档的中英文案名副其实：`settings.topbar.titleMode`「标签显示设置」、`.text`「仅显示文本」、`.icon`「使用插件图标」、`.custom`「自定义显示图标」、`settings.topbar.customScope`「自定义生效范围」；旧键 `.unified/.two/.smart` 已删不重复；英文侧 `Label display` / `Text only` 也在 |
| settings page reads as one page | `test:3909` | 整页读起来是一页：`scope` 行排在 `maxSeats` **之前**；`topbar.mode` 与 `topbar.rightReservePx` 两行**已删**（字段留给 API）；三个数字行同样共用 stepper；胶囊宽度 `0%` 显示成「默认」而不是数字；`WINDOW_CONTROLS_GUARD = 138` 写死在代码里且 band 宽度算式减掉它；三个座位上限的 hint 措辞是一家人 |
| a failure outlives the running flag | `test:3948` | 失败态活过 running：源码里**不再有**「每轮 sync 见到 `running===true` 就 `errors.delete(id)`」的急切擦除；改为订阅 `ctx.remote.$on('api-session/activity'`，只有出现更新的用户消息才退休错误标记（TTL 兜底） |
| sidebar row titles follow the same label modes | `test:3967` | 侧栏行标题走同一套三档：`icon` 档侧栏行首是类别图标、标题里的 emoji 被剥；`text` 档只留文字；`custom` 档让标题自带 emoji 顶上——侧栏与 tab 行/胶囊三处不出现两种规则 |
| the table names every seat and why the rest are out | `test:4015` | `hotlistTable()` 的 `rows` 每行带 `surfaces`（哪个面在画它）与从 1 开始的 `index`；`missing` 逐条给原因 —— 超上限 `over-cap`、该面关着 `position-off`、空会话 `empty`、子代理 `subagent`；把 idle 的三个面全关后原因变 `surface-off`；`scope:'workspace'` 时别的工作区会话原因 `scope`；`table.limit` 随行带出供标题使用 |
| the table view is a tab of its own | `test:4072` | 看板以固定 id `TABLE_VIEW_ID` 注册、`order === TABLE_VIEW_ORDER`（排在所有座位之后）；组件渲染出一个 `data-hotlist-table` 根节点、每个热会话一行 `data-hotlist-table-row`，此处没有落选行所以 `data-hotlist-missing` 计数为 0 |
| pills carry the class animation | `test:4098` | 顶栏胶囊带类别动效：待审批会话的胶囊有 `data-hotlist-chip-motion='bounce'`；把 `display.reduceMotion` 改成 `'on'` 后重渲染，该属性变 `undefined` —— 减动效摘掉的是胶囊上的动效，不是不画胶囊 |
| pills keep their class animation on the shared plan | `test:4126` | 读 band 注入的那张样式表：四类 × 两个目标（`emoji` 动图标 / `row` 动标题 span 的 `hl-text-*`）都有 `infinite` 常驻规则，**没有** `data-hotlist-chip-burst` 规则、没有 `hl-chip-nudge`；reduced-motion 覆盖 `[data-hotlist-chip] *`；freq 0 时胶囊连 `data-hotlist-chip-motion` 都没有；freq 1 + bounce/row 时胶囊带 `motion`/`target`，标题 span 拿 `animation-delay` 与 `animation-duration`（内联，来自共享 plan）；切 blink/glyph 后 emoji span 拿到新 delay/duration |
| tab seats draw the same glyph and motion | `test:4208` | 把 `categories.pinned.order` 调到 5 让会话进 tab 行后，座位按钮里长出 `data-hotlist-tab-glyph` 的 span：文本是类别图标 `📌`、`data-hotlist-motion='bounce'`；宿主原来的文本节点仍是 `会话 tab-pin` —— 图标不写进标题文字 |
| every category offers all three positions | `test:4245` | 六类 × `tab`/`sidebar`/`topbar` 共 18 个 `categories.<类>.surfaces.<面>` 行全部存在；`idle.surfaces.tab` 初始 `checked:true`，触发 `onChange()` 后设置里变 `false`，重渲染时摘要行那颗 `tab` chip 跟着变 `data-on='false'` —— 行与 chip 读的是同一份设置 |
| export is an API, not a button | `test:4280` | 设置页里**没有** `data-hotlist-export` 节点、也没有任何行键含 `export`；但 `window.__HOTLIST__.export` 仍然是函数，`export({format:'json'})` 返回可 `JSON.parse` 的数组 —— 导出只从控制台走 |
| a yielded title still shows a class glyph | `test:4295` | 标题自带 `🎓` 时侧栏仍建出 `data-hotlist-glyph` 槽位：`data-hotlist-char='🎓'`（用标题那颗而不是类别图标）、`data-hotlist-glyph-kind='emoji'`（所以能挂动效）、`style.display` 不是 `none`；同时宿主标题文本里那颗 emoji 被剥掉，只剩 `大聪明` |
| equal order falls back to the class rank | `test:4329` | `error.order` 与 `pending.order` 同为 10、同一会话既报错又待审批时，`classify()` 判成 `error` —— 平手靠类别名次（`CATEGORY_RANK`）断，不靠 Map 插入顺序 |
| the table only reads the surfaces that are on | `test:4343` | 三个面全开时该行 `surfaces` 三项全 `true`、`missing` 为空；band 落下（`bandUp:false`）且只开 tab 时 `surfaces` 变 `{tab:true,sidebar:false,topbar:false}` 但仍有一行；三个面全关时 `rows` 为空，而该会话进 `missing` 且 `reason==='position-off'` —— 不是悄悄消失 |
| the table keeps a foreign pin out of the pinned class | `test:4378` | `scopeWorkspaceIds:['here']` 时别的会话的置顶不算置顶：行还在，但类别落 `idle`；把它划进本工作区、`pinned.order` 仍是默认 60 时还是 `idle`（置顶默认比 idle 弱）；只有把 `pinned.order` 提到 5，本工作区的置顶才变 `pinned`，而别的工作区那颗**无论 order 多高都不赢** |
| a slot declared later never gets registered early | `test:4404` | 宿主先声明 `shell.overlay`、后声明 `conversation.view`：`apply()` 后顶栏进它自己的槽（`hotlist.topbar` 已注册），但**没有任何 `hotlist-seat-*`、也没有 `hotlist-table`**；等到 `conversation.view` 被声明，座位与看板才注册 —— 这就是 5.0.0-alpha.1 那次 `slot "conversation.view" is not declared` 启动崩的回归位 |
| rows left out are grouped by reason, not dumped | `test:4433` | 落选行按固定阅读顺序分组成 `['over-cap','empty','subagent']`（不是按条数排名）；每组是一个 `<details>` 且默认折叠（`open===undefined`）；三个落选会话仍然都渲染在组里、各自带原 `data-hotlist-missing` 原因；每组头部 `hl-missingGroupCount` 报该组条数（此处三个 1） |
| the cap has no auto mode and the window default replaces the old one | `test:4482` | `maxSeats` 行只剩 `[minus, plus]` 两个 stepper、没有第二个 `aria-pressed` 控件（自动档按钮已删）；`sanitizeSettings({maxSeats:6, collect:{recentWindowMinutes:5}})` 把未标记的 5 认成旧出厂默认、升到 **17**，而经页面写过的 5 会被记成用户选择、重载后仍是 5；`maxSeats:'auto'` 仍然合法（只是没有按钮），`buildSeatPlan` 按传进来的 `limit` 截断 |
| display metadata: the plugin list can show a name and an icon | `test:4521` | 插件列表的元数据：`package.json` 的 `icon` 指向 `./icon.svg` 且 `exports['./icon']` 与 `exports['./locale/*.json']` 都在、`files` 含 `icon.svg` 与 `locale`；`locale/{en,zh}.json` 两种语言的 `meta.title`/`meta.description` 都非空；图标以 `<svg` 开头且 ≤256 KiB（宿主上限） |
| ring player: waits out the configured minutes, repeats as configured | `test:4543` | 出厂 `ring` 形状 `{pending:false, error:false, completed:false, afterMinutes:7, repeatTimes:1}`；**锁存等待**：进入状态不开弹，原样停够 `afterMinutes` 分钟（差 1 ms 都不行）才第一次 `ring()`，之后每隔同样的间隔再来，`repeatTimes` 用完即止（1 次默认、2 次在 2n 才第二响、5 次睡过五个间隔醒来只补一次）；类别一变就重新计时；会话不再等（含重新跑起来）永不补弹；`error` 会话是当前会话（`currentId`）即视为已确认、永不升窗；完成的座位 TTL 掉出列表但没响过仍欠一次且只一次；开关关着等待照跑只是不画（`log('off')`）；两个会话同拍到期宿主只弹一个、另一个原位保留；`request` 抛错只留 console 行不炸 `observe` |
| host ring: script arguments and no-pwsh safety | `test:4713` | 宿主半边三道闸：参数夹取（`seconds` 夹到 1–30、`scope`/`anim` 白名单）、`spawn` 必须挂 `child.on('error')`（不挂会打死 host）、脚本真的在包里（`files` 含 `tools/attn-ring` 且**不含** `tools`）且在磁盘上（`RING_SCRIPT` 可解析） |
| the super reminder ships two clips, and the popout art is back to static | `test:4848` | 随包素材分家：`assets/manifest.json` 的 `total_webp_bytes` 是 **681462**（静态图那套），三类 × 四档逐条与磁盘字节相等、且每档 `px` 就是档位本身（不是把 500 px 动画缩下来）；光圈用的两段动画改放 `tools/attn-ring/media/`：`smack.gif` 10 帧、`wave.gif` 11 帧，都是 320×320 的 `GIF89a`、单份 <450 KiB 的包体预算 |
| a gif ring reaches the script with its clip, and other animations stay untouched | `test:4877` | `ringArgs('seconds=4&anim=gif&cat=completed')` → `{seconds:4, scope:'Primary', anim:'Gif', gifCategory:'completed'}`，`ringCommand()` 的 `-Anim Gif` / `-GifCategory completed` 都到位；非法 `cat`（`<script>`）回落 `pending`、不会进 shell；`anim=Expand` 时 `cat` 被忽略、`-GifCategory` 根本不出现；`Expand`/`Breathe`/`None` 仍在白名单里 |
| the audio gate is off by default and only lets headphones through | `test:4898` | 「只在耳机时响」的出厂形状是 `audio: { smart: false }`（**一个开关、默认关**）；写 `{ smart: true }` 落盘且被打上 `choices['audio.smart']`（出厂预设改不动它），非布尔值回落 `false`；纯函数 `audioGateAllowed` 六态逐条：开关关 → 一律放行（不看探测）、探测为 `null` → `audio-unknown`、`measured`+`speakers` → `not-headphones`、`measured`+`headphones` → 放行、`state:'unknown'` → `audio-unknown`、`error` 非空 → `audio-unknown`、超过 `AUDIO_PROBE_TTL_MS` 的旧探测视同没有；player 层三条：喇叭时**不播**且 console 记 `skip not-headphones`、耳机时放行、探测不出来时**不播**并记 `skip audio-unknown`；最后一条证明「开关关掉时绝不查探测」（探测是扬声器也照播） |
| the ring hint is gone and the audio switch takes its place | `test:4987` | 源码里 `'settings.ring.hint':` 这个键**已不存在**、`'settings.audio.needSetup':` 也**已不存在**，`'settings.audio.smart':` 存在；渲染出来的页面里 `data-hotlist-row="audio.smart"` 是真行、`ring.pending` / `ring.error` / `ring.completed` 三行仍在（只删说明行、没删开关）；`key === 'audioNote'` 的节点文本是 `settings.audio.needSetup`（初始化提示挂在开关下一行），且页面上没有任何 `hl-rowHint` 还写着 `settings.ring.hint` |
| the audio probe is scriptable and answers before any probe has run | `test:5012` | `window.__HOTLIST__.audio()` 在任何探测发生**之前**就能调用并返回对象：`smart` 为 `false`（默认关）、`pass` 为 `true`（开关关着时门禁从不拦），以及 `state` / `kindGuess` / `name` / `error` / `asOf` 五个只读字段的形状 |
| a fresh install matches the shipped defaults | `test:5025` | 用户在一台干净实例上亲手调好的那套出厂值：`maxSeats:7`、`categories.running.surfaces.tab:true`（且 `topbar:false`）、`topbar.customScope` **只有 `pinned` 为 true**、`categories.pinned.sound.enabled:false`（置顶静音）；同时断言没动的那三面没被带跑（`error`/`pending`/`completed` 仍在顶栏、`error` 仍不进 tab 行）。 |
| an untouched old preset is upgraded, a chosen one is not | `test:5047` | 老出厂值只是**预设不是选择**：一份写着旧默认的存档（`maxSeats:6`、`running.surfaces.tab:false`、`pinned.sound.enabled:true`、`customScope` 六类全 true）升到新默认；同一份存档一旦在 `choices` 里被标成用户选过（`maxSeats` / `running.surfaces.tab` / `pinned.sound.enabled` / `customScope.error`），四个值原样站住。 |
| audio config: the six states are derived, never stored | `test:5086` | 六态是**纯派生**，不落盘：`audioConfigStateOf(null)`→`hostDown`、非 `win32`→`unsupported`、`exists:false`→`missing`、`valid:false`→`invalid`、`headphoneCount:0`→`empty`、`>0`→`ready`；同一个函数设置页与门禁共用，读失败不会留着上次的「已配置」。 |
| audio config: device names match in three levels, and short names never match | `test:5102` | 名字三级匹配：①精确相等；②`normDeviceName` 归一后相等（去掉括号里的型号、全半角括号都去、压空白、小写）；③归一后双向包含，且**短的一边至少 6 个字符**——`耳机` vs `耳机 (Baseus)` 不匹配（短边不足 6 会误放行到外放），`Baseus Bass BC2 Stereo` vs `耳机 (Baseus Bass BC2 Stereo)` 也不匹配（括号尾巴不是设备身份）。 |
| audio config: a configured headphone list becomes a whitelist for the gate | `test:5129` | 有清单时它是**白名单**：清单里的耳机名放行；清单写着「扬声器」的那台即使探针猜成 `headphones` 也拒（`not-headphones`）；清单空/没有耳机退回探针的 `kindGuess` 分支（配置是叠加，不配置不哑巴）；非 `win32` 直接 `audio-unknown`；开关关着永远放行。 |
| audio config: the prompt never leaks a placeholder or a home directory | `test:5166` | 复制给 AI 的提示词自检：中英两版都不残留 `{{`；宿主给出绝对路径后文本里不再出现 `%USERPROFILE%`；`script:null` 时整句换成「插件没找到脚本」且不留半截路径；只有宿主完全不可用时才退回 `%USERPROFILE%\.dsh\hotlist-audio.json` 并加一句「以你实际目录为准」。 |

| tab seats always move the glyph and never wrap the host title | `test:5200` | tab 座位**只动图标**：`motionTarget` 是出厂默认 `'row'` 时 glyph 仍带 `data-hotlist-motion='bounce'`、页面上不存在 `[data-hotlist-tab-title]`；切到 `'glyph'`、再切回 `'row'` 都保持这个结果 —— 5.3.2 曾按 `motionTarget` 包住宿主标题（glyph 停在 `none`，表现是沙漏不转），5.3.4 回退 |
| the band and the tab row derive the same phase from the same seed | `test:5237` | 同一会话两个面共享相位：`motionPhaseOf(sessionId, category, durationMs)` 是 `fnv1a(sessionId|category) % durationMs`，顶栏胶囊标题与 tab 座位的 `animationDelay` 都是 `calc(-1 * <phase>ms)`——两个面打开同一关键帧的同一位置，看起来像同一个动画 |
| one session wears the same plan on all three surfaces | `test:5281` | 5.3.5 新增：`tri-a`（pending，freq 0.9）在侧栏 glyph、tab 座 glyph、顶栏胶囊标题三处的 `motion` 都是 `bounce`、duration 都是 `1333ms`、delay 都是同一个 `calc(-1 * motionPhaseOf('tri-a','pending',1333)ms)` —— 三处同名同期 |
| the seed separates sessions and classes | `test:5334` | 5.3.5 新增：同种子自稳定（`phase-x/pending` 两次算相等）、异类异会话相位不同（`phase-x` pending≠completed、`phase-x`≠`phase-y`）；两个会话各按自己的种子相位起播，互不相同 |
| frequency moves all three surfaces together | `test:5372` | 5.3.5 新增：`writeSettings` 把 freq 从 `1→0.5→0`，三处 duration 同步 `['1200ms'×3] → ['2400ms'×3] → 全停`（侧栏 `''` / tab `''` / 胶囊无 motion 属性）——「三处一起变」的守门组 |

### 1.3 改测试时踩过的坑（照抄结论）

- **假元素必须有 `parentElement` 与 `clientWidth`**：`seatLimit()` 量的是 `[data-conversation-tabs]` 的父元素；只给 `clientWidth` 会让上限退回 6，测试看起来"座位数不对"。
- 假选择器引擎要处理 `[attr^="value"]` 时**先剥引号**，否则 `data-row-key^="session:"` 永远不匹配。
- `React.useState(initializer)` 在 stub 里必须支持**函数型初值**（设置页用 `() => snapshot()`），否则拿到的是函数而不是对象。
- `walk()` 要递归嵌套数组：`h('div', {}, arr.map(...))` 的 children 是"数组里套数组"。
- registry 是**按 slot 分键**的：`settings.section` 与 `settings.section.icon` 可以同 id，测试桩不能把它们写进同一个 Map。
- 注销是**延迟两级**（`setTimeout(0)` → rAF → `setTimeout(0)`）：断言"座位已消失"要 `await tick()`，而 `tick()` 本身要跨两个宏任务。
- 侧栏 marker 只在**有状态**的行上出现：全是 idle 且该类 `surfaces.sidebar:false` 时一个 marker 都没有，想测 marker 得给某行 `running` / `pendingInteraction`。
- **全局 `head` 是共享的**：前一组 adapter 留下的 `<style data-hotlist-style>` 会让后一组的数量断言多出来，组开头要清（`clearStyleBlocks()`）。
- **假元素要支持 `dataset` / `classList`**：浮层与侧栏都用 `dataset` 写 `data-*`、用 `classList` 标 exit 类；stub 的 `dataset` 必须写回 attributes，否则选择器查不到。
- **`matchesSelector` 要认 `.class`**：`resolvePopoutSide` 量的是 `.mP3x-q_sidebarCol`，只认属性选择器的桩会让它永远走 left。
- **必须清理副作用**：`createCtx().cleanup()` 要逆序跑完所有 `slots.inject` 的 disposer 与 `ctx.effect` 的 disposer，否则侧栏的 `setInterval` 会让 node 进程跑完 `PASS` 后不退出。

## 2. 真机（唯一能证明"真的能点"的层）

环境：test profile 的 GUI（约定端口 59559，由 profile-runner 起）。验收期间**只能一个人操作 GUI**——另一个窗口的 reload 会把你的断言打断。

### 2.1 验收脚本

- v3.1：`cangku/tmp/261111_k4t_v31-acceptance.js`（7 项一把过；`cangku/` 是作者本机的草稿区，不在仓库里）。
- v4.0–v4.4：实测脚本在 `cangku/tmp/261111_v41_delta_out.json`（37 项）与 `cangku/tmp/261111_ev3*_out.json`（持久化），命名沿用 `cangku/tmp/261111_*_v4*.js`。卡片 UI 的判定键是 `[data-hotlist-settings]` 与 `[data-category][data-open]`，折叠态看 `[data-hotlist-card-body]` 数，展开态点 `button.hl-cardHead`；浮层的判定键是 `[data-hotlist-popout]` / `data-hotlist-popout-cat` / `data-side` / `data-reduce-motion`，`onDone` 之后该节点必须消失。
- 用法写在文件头：`ego_script({ script: <文件内容>, timeoutMs: 118000 })`；前置是目标版本已被 profile 加载，**旧版本的结果不算数**（脚本首先断言 `window.__HOTLIST_VERSION__`）。它会产出 `OUT.summary.verdict` 与截图。
- 脚本只读 + 通过 `window.__HOTLIST_SETTINGS__` 改设置（结束还原）；唯一 DOM 改动是插一个假 `[data-dsm-dot]` 探针并删掉。不点会话、不点「允许」。

### 2.2 ego 取证的三条硬规矩

1. **视口与截图必须同一次脚本**：`setViewportSize`（或 CDP metrics）和 `page.screenshot` 分开两次调用，截图可能是旧视口——断言宽度类的用例会假过。
2. **`page.goto` 到当前 URL 不会产生新文档**：想"重载一次"必须 `page.evaluate(() => location.reload())`，否则拿到的是同一个 document，stale 的 window 状态还在。
3. **`ego_screenshot` 在脚本内不可用**：脚本里要图就用 `page.screenshot({path})`（或 CDP `Page.captureScreenshot`），事后再用 `ego_screenshot` 看是另一回事。

### 2.3 只能在真机验的清单

- 点座位是否真的切会话（`aria-selected` 在真机上不一定跟随我们，`pointerdown` 双路径就是为这个加的）。
- 注销延后是否压住了 `uiConversation.binding: unknown session`（静置 ≥60s、切换若干次后看 console）。
- 短读保护：切换后 ~70s 座位是否掉（真机历史 bug）。
- dsm 状态点顶替与还原（需要另一个插件真的在画点）。
- 动效观感：`motionTarget:'row'`、`reduceMotion`、每类的「播放频率」（0–100% 滑块）与常驻预览——只能人眼看；`row` 目标现在带 1–2px 位移，标题应该看得出在动。
- **三处同节拍的读数（5.3.5，已实测可复现）**：同一会话要同时在三个表面上（默认 surfaces 里没有三面全开的类，验收时用 `__HOTLIST__.settings.set({categories:{<cat>:{surfaces:{tab:true,topbar:true,sidebar:true}}}})` 临时打开），然后同一时刻读三处：
  ```js
  const read = (el) => el && el.getAnimations().map(a => [a.animationName, a.effect.getTiming().duration, a.effect.getTiming().delay]);
  // 顶栏：document.querySelector('[data-hotlist-chip-emoji]') 或 [data-hotlist-chip-title]（row 目标）
  // tab 座：document.querySelector('[data-hotlist-tab-glyph]')
  // 侧栏：document.querySelector('[data-hotlist-glyph]')
  ```
  三者必须是同一个 `animationName` / `duration` / `delay`（2026-11-17 实测：`hl-bounce` / `1200` / `-32`）。把该类「节奏倍率」拖到 0，三处 `getAnimations().length` 同时变 0。**注意网页版顶栏预览条会被宿主页头盖住**（`topbar.previewInWeb` 画在 `top:0`），要肉眼比对三处就用桌面版。
- 设置页外观：token 是否在深色主题下正确、559px 内是否横向滚动、上传真实文件时 canvas/webp 是否可用；折叠态一张卡 ≈44px、展开态「置顶」卡 ≤520px（v4.4 真机：44 / 514 / 466；v4.5 少了全局区一行与 i18n 两键，v4.6.2 又删掉了「收藏」整类，卡片只剩 6 张，整体只会更矮）。
- 设置页结构与版本标记（验收脚本靠它们一击命中）：页根 `data-hotlist-settings` 期望值是 **`v5.3.5`**；卡片 **6 张**（`error` / `pending` / `pinned` / `completed` / `running` / `idle`，4.6.2 起「收藏」整类已删）；折叠态 chip 共 **30 个**（6 卡 × 5），其中 6 个是 topbar 位——**v5 起它们是活的**（`data-disabled="false"`，出厂 `error`/`pending`/`completed` 三张卡的 topbar 位 `data-on="true"`），不再是 4.x 的灰块；全局区必须有的 `[data-hotlist-row]` = `scope` / `maxSeats` / `pinned.maxSeats` / `collect.completedTtlMs` / `sound.volume` / `recentWindow` / `positions.tab` / `positions.topbar` / `takeOverStatusDot`，`positions.topbar` 打开时再多三行（`topbar.chipWidthPct` / `topbar.titleMode` / `topbar.customScope`）；超级提醒是**独立一组**（`[data-hotlist-ring]` 恰好 1 个，组标题 `settings.group.ring`）里三行 `ring.pending` / `ring.error` / `ring.completed` + **v5.3.2 起两行数字**（`ring.afterMinutes` 1–60 默认 7 / `ring.repeatTimes` 1–99 默认 1），同一组还有 `audio.smart` 一行 + 它下面的 `audioNote` 提示（`p`，不是 row）。
- 置顶走宿主原生：置顶来自宿主快照 `pinnedSessionIds`（侧栏行 hover 的「置顶会话」按钮），`settings.pins` 已在 **4.6.0 废弃**、读时丢弃，设置页也没有上移/下移/取消置顶；插件只提供全局「置顶最多显示」`pinned.maxSeats`（0–12，默认 3，0 = 不显示置顶）。真机上置顶/取消置顶后座位应在两轮 `tick()` 内跟着变。
- 「最近对话展示时间」在 5.1.8 之后**不再是两层范围**：设置页数字框给 **1–120** 分钟（`RECENT_WINDOW_UI`，`client.js:333`），与存储层上界一致（`RECENT_WINDOW_MINUTES`，`client.js:328`，`0`–`120`，默认 **17**；`0` = 不显示 idle）。仍要两只手都验：页面拖到 `1` 和 `120` 都要能落盘；走 API `window.__HOTLIST_SETTINGS__.set({ collect: { recentWindowMinutes: 0 } })` 也合法（只有页面不提供 0），重载后仍是 0。
- 耳机门禁（v5.3 新增，`audio.smart`）：开着它、且默认输出是**音箱**时，让某个会话进 `pending` 或 `completed`——**必须没有提示音**（console 有 `skip not-headphones`）；把默认输出切到耳机再来一次，**必须响**。切完后**不要点任何按钮**，等 60 秒以上再触发一次，应自动跟上（客户端按 `AUDIO_PROBE_TTL_MS` 自己重探）。`window.__HOTLIST__.audio()` 应依次给出 `{ smart:true, state:'measured', kindGuess:'speakers', pass:false }` → `kindGuess:'headphones', pass:true`。顺手验两条宿主闸门：控制台 `await fetch('/hotlist-audio')`（**不带** `x-hotlist-audio: 1`）应返回 **403 `no-marker`**；带上头再连发两次，60 秒内第二次应命中缓存（`cached: true`，不再起子进程）。另外验那条容易误以为坏了的行为：**设置页点 ▶ 试听，无论接音箱还是耳机都必须响**（它不走门禁）；以及被门禁拒掉的那一次**不消耗** 1500 ms 节流窗口——拒掉后立刻切到耳机再触发，应该马上响而不是等一秒。
- 设备清单（5.3.1 新增）：设置页「超级提醒」组里 `audio.smart` 下面那行，状态小字 + `{配置}` / `重新读取` / `文件位置` 三个**真按钮**（Tab 顺序 = 视觉顺序）。未初始化时写「未初始化 · 按系统类型判断」；点 `{配置}` 后剪贴板里应是一段中文提示词，含**真实绝对路径**、不含 `%USERPROFILE%`、不含 `{{`；让 AI 写完文件后**不要点任何按钮**，60 秒内状态自己变成「已配置 N 个（耳机 M 个）」；点「重新读取」应立即变；把文件改成坏 JSON →「文件格式不对」且按钮文案变「重新配置」；删掉文件 → 回到「未初始化」（不保留旧状态）；「文件位置」只复制路径、不弹文件对话框（浏览器拿不到本地绝对路径）。
- 超级提醒（v5.3.2 锁存语义）：开 `ring.pending` 后让会话进 `pending`——**7 分钟内不升窗**（默认 `afterMinutes`，差 1 ms 都不升），停够 7 分钟后升一次；不处理它，再过 7 分钟应再升（`repeatTimes` 默认 1 时只升一次，改成 2 再验第二次）；中途把状态改掉（点一下/切走）应**重新计时**；把 `afterMinutes` 拖到 1、`repeatTimes` 拖到 3，会话停 1 分钟升、之后每 1 分钟再升、第 3 次后停；`error` 会话若正是当前会话应**永不升窗**（打开即确认）。这些只有真机能验——单测只能证明 `observe()` 的属性写对了，`ring()` 是否真被宿主拉起要人眼看。
- 浮层：真的会在「别的会话进入 error/pending/completed」时弹出来、位置在正确一侧（auto 时看左侧会话栏宽度）、点到图上会切到那个会话、超时自己收回且收回后 DOM 里没有残留节点。
- 浮层的观感：clip 揭示的入场、breath/float 的待机、drop/particles 的退场，以及 `reduceMotion` 时是否只剩 120ms 淡入——单测只能证明属性写对了。
- 离线/缺素材时的回落：删掉某个 `assets/<cat>-<tier>.webp` 后应回落到同名 `.svg`，再删 `.svg` 应回落 emoji，console 里有 `[hotlist] popout` 的 fallback 日志。

## 3. 改动前最小回归清单

按顺序，全部过了再提"改完了"：

1. `node --check client.js index.js test/classify.test.mjs`。
2. `node cangku/tmp/261111_gate_pre_restart.mjs` → `STATIC VERDICT: clean`（查未声明常量、已删字段、新字段与模块形状；`node --check` 抓不到「引用一个没人声明的常量」这类崩溃）。
3. `node test/classify.test.mjs` → `PASS — 126 groups`。
4. 如果碰了排序：断言「同一批会话只变 `updatedAt` → registry 变更数不增加」（组 `adapter plan`），否则 tab 会每 30s 抖一次。
5. 如果碰了注册/注销：断言座位 id 仍带 `hotlist-seat-` 前缀、`stop()` 后无残留节点/属性/样式（组 `adapter sidebar markers`、`surface gating`）。
6. 如果碰了 CSS：断言所有样式文本不含 `[[`，且 takeover 规则只出现在 `data-hotlist-style="takeover"` 的 `<style>` 里（组 `takeover gate`、`styles stay valid`）。
7. 如果碰了设置模型：`README.md` 的可配置项表要同步（与 `defaultSettings()` 一一对应），并跑 `settings sanitizing` + `migrate v3 to v4` + `recent window migration and clamping` + `recent window UI bounds match the API`（页面 1–120、存储 0–120，默认 17 —— 5.1.8 之前页面只到 36、默认 5）；`SETTINGS_VERSION` 变了就补一条迁移与一条「旧版本安全归一化」用例；另外三条是「不破坏用户设置」的守门组，改默认值或顺序时必跑：`defaults never overwrite stored values` / `user settings are never overwritten` / `legacy default order is adopted, real choices are kept` / `factory presets are replaced, user choices are kept`（专治「改了出厂默认但老用户没动」：临时去掉 `LEGACY_VALUES` 的闸门，它必须变红）与 `user picks survive the preset rule`（专治「闸门把用户选的值也改了」：把 `isChoice` 短路成 `() => false`，它必须变红）。
8. 如果碰了动效：跑 `sidebar motion is the shared continuous plan`（三处同走同一份 plan、频率变 duration 跟着变、reduce 与频率 0 全停、`Math.random` 零调用）与 `frequency moves all three surfaces together`（freq `1→0.5→0` 三处同步）；`preview loop lifecycle` 覆盖预览串。
9. 如果碰了持久化：跑 `completedAt persistence`（一次 sync 只写一次、成为主视图立刻删、重启剪枝；列表 `phase` 非 `ready` 时不得丢弃读回的条目）。
10. `VERSION` 升了：`cangku/tmp/` 的验收脚本里的版本断言要同步，否则真机验收会 FAIL。
11. 如果碰了浮层：跑 `popout side resolution` / `popout priority arbitration` / `popout seq guard` / `popout reduce merge` / `popout cooldown` / `popout first entry only`；确认 `makeResolveAsset` 三条分支都不抛、`onDone` 之后节点被移除。
12. 如果碰了热键：跑 `shortcut cycle and guards`；确认没有自己挂 `document.addEventListener('keydown')`，且 `S` 只在 `shortcuts.overlayEnabled` 打开时消费事件。
13. 如果碰了设置页排版：跑 `settings page` / `settings page densified rows` / `settings page writes land immediately`（控件改动必须同步写进 `readSettings()`，座位类两轮 `tick()` 内生效）。
14. 最后才做真机项（§2.3）。
