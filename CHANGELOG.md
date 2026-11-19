# Changelog

## 5.3.8 — 2026-11-19

**图标换成 PNG（meru 系）。**

## 5.3.7 — 2026-11-17

**Packaging only: `engines.dsh` and `repository`.** This release adds
`"engines": { "dsh": ">=0.2.2-rc.1 <0.3.0-0" }` so the host — and any directory
that lists the plugin — can check up front that a compatible DSH is installed,
and adds the `repository` field so npm and the GitHub repo cross-check as one
project. Nothing else changed: no behaviour, no settings shape, no rendering, no
sound. If you already run 5.3.6, installing 5.3.7 looks and acts exactly the
same.

## 5.3.6 — 2026-11-17

**修复：`frequency` 改回「多久播一次」，不是「动得多快」。** 用户原话：「动作频率又变成了动作速度？？？为什么老是改老代码还改错？？」——5.3.5 把频率直接除进时长（`duration = base / max(f, 0.05)`），于是把滑块往左拖是把**每一下的动作拉长**，用户要的是「更稀」，不是「更慢」。

- **单次时长恒定**：一次播放永远是 `MOTION_MS[motion]`（`spin 2400` / `pulse 1600` / `bounce 1200` / `blink 1200`，一个数都没改）；`frequency` 只决定隔多久播下一次——周期 = `play / f`，播放占前 `f` 那一份，其余时间**停在末帧**（`rotate(360deg)` 与 `0deg` 视觉等价，不会停在半个角度）。`f = 1` 连着播、`f = 0` 不播、`f = 0.3` + `bounce` = 播 1200ms 停 2800ms。实现：`motionDutyStep` / `motionPlayMs` / `motionDurationOf`（返回周期）/ `motionRestMs` / `motionKeyframeName`。
- **keyframes 提到模块级共享表**：`motionKeyframeRules()` 一次生成 8 个动作 × 20 个占空档 = 160 个 `@keyframes`，注入在 `<style data-hotlist-style="motion">`，三处表面引用同一个 `hl-*-<step>` 名字；`SIDEBAR_STYLE` / `TAB_CSS` / `CHIP_CSS` 不再自带 keyframes，`animation-name` 由 JS 内联写。`f = 1` 那一档与 5.3.5 手写表**逐停点等价**（`f=1 keyframes are the published 5.3.5 table` 把旧表当基线比对）。
- **`display.reduceMotion` 变成三档单一判据**：新增 `motionAllowed(settings, win)`（`on` → 停 / `off` → 动 / `auto` → 跟随 `matchMedia`），四个真实表面（侧栏 / tab 行 / 顶栏 / 缺失分组）都只问它；删掉 4 段 `@media (prefers-reduced-motion: reduce)` 与其上的 `!important`，改用根属性 `html[data-hotlist-reduce-motion]` 驱动。**设置页预览永不因它停**——预览是用户唯一能看见所选动作的地方，冻掉等于盲选；这一条写在 `motionAllowed` 的注释里，不要再「统一」。
- **tab 行 `row` 目标真的动标题**：给宿主自己的 `span[class*="tabLabel"]` 打 `data-hotlist-tab-label` 承载文字 keyframes，**不包 wrapper、不 clone、不改宿主 `display`**（5.3.4 就是包 wrapper 被回退的）。tab 按钮 35px、tab 行 25px 实测前后不变；glyph 在同一节点内骑同一趟位移，所以它的 `data-hotlist-motion` 记 `none`——一趟位移，不是两趟。宿主没有 label 元素的旧形态回落只动图标。
- 设置页文案改回频次口径：zh「播放频率 · 0% 不播；100% 一直播；越往左越稀。每一下的动作速度不变，顶栏、Tab 栏、侧栏三处一起变。」/ en「Playback frequency · 0% never plays; 100% plays back to back; further left is rarer. The speed of each play never changes…」。「节奏倍率 / Tempo / 越低越慢」的残留全部清掉。
- 测试 126 → 132 组：新增 `frequency is a duty cycle, not a speed` / `f=1 keyframes are the published 5.3.5 table` / `duty keyframes are well formed and hold the end frame` / `every motion frame is a property declaration with a value` / `a row target animates the host tab label, not a wrapper` / `reduce stops the real surfaces and never the preview`。红灯实验 7 次（删静止段、改脉冲峰值、丢 `transform:` 前缀、时长公式反向、塞回媒体查询、手写 `reduceMotion ===`、把 `motionAllowed` 接进预览）逐条验证会红。
- 真机（meru-test 59585，tab 行「库管」座位）：`f=1` → `hl-text-bounce-20` / `1.2s`，`f=0.3` → `hl-text-bounce-6` / `4s`；活动段 50ms 采样 40 点，中位速度 **5.0 vs 5.1 px/s**（同速）、变化样本 **40/40 vs 32/40**（变稀）；两次 400ms 位移 `f=1` **1.817px**、`f=0.3` 静止段 **0.000px**。`reduceMotion` 三档实测：`on` 时标记 0 / 在跑动画 0 / 根属性 `""`。
- `VERSION` / `package.json.version` → `5.3.6`；`SETTINGS_VERSION` 仍 `4`，无迁移（频率语义变了，但字段名与取值范围没变）。

## 5.3.5 — 2026-11-17

**三处动效统一成一份计划。** 用户原话：「顶栏 / Tab 栏 / 侧栏动画统一：只有前两个统一，侧栏不是，不管三个都统一成什么样，都得统一成设置里用户调的样式。」5.3.5 之前是三套模型：tab 座与顶栏胶囊常驻循环、侧栏 glyph 走 burst 抽签（`motionBursts` + `MOTION_CONCURRENCY` 限并发）。现在三处全部从同一个 `motionPlanOf(settings, sessionId, category, motion, motionTarget)` 派生：同一套 keyframes、同一个时长、同一个相位种子（`fnv1a(sessionId|category)`），一个会话在哪个表面上看起来都是同一段动画。

- **`frequency` 从「抽签概率」变成三者共用的节奏倍率（tempo）。** 时长 = 基准 / `max(频率, 0.05)`：`0` = 停，`1` = 原速（2400/1600/1200ms），越低越慢。不再是「每 tick 掷一次骰子、命中才动一下」。
- **burst 机制整体删除**：`motionBursts` / `startBurst` / `stopBurst` / `bandBursts` / `chipBursts` / `MOTION_CONCURRENCY` / `data-hotlist-burst` / `data-hotlist-chip-burst` 全部移除，侧栏 tick 只保留窗口隐藏时的暂停属性。`Math.random` 不再参与动效。
- **设置页滑块改文案**：「播放频率」→「节奏倍率」，提示写明「顶栏、Tab 栏、侧栏三处一起变」；预览动画（`previewStyle`）改为 tempo 语义（始终 20 档、频率只拉长周期）。
- `prefers-reduced-motion` 与 `display.reduceMotion: 'on'` 三处一起停（行为不变，仍不升 `SETTINGS_VERSION`，老 `glyph.frequency` / `glyph.motion` 键保持可用）。
- 测试：`sidebar motion bursts` / `pills keep their class animation, and a burst plays it once` 按新模型重写；新增三组守门（`one session wears the same plan on all three surfaces` / `the seed separates sessions and classes` / `frequency moves all three surfaces together`），测试总数 123 → 126。
- `VERSION` / `package.json.version` → `5.3.5`；`SETTINGS_VERSION` 仍为 4，无迁移。

## 5.3.4 — 2026-11-15

**修复：tab 座位的沙漏又转起来了。** 5.3.2 让 tab 座位跟着 `motionTarget` 走（默认 `'row'`），结果它把宿主 tab 的标题包进我们自己的 span、把图标停在 `none` —— 用户看到的正是「Tab 栏的沙漏不转了」。这一版把规矩改回一句话：**tab 座位只动图标，宿主标题永不包**。`motionTarget` 仍然是侧栏行与顶栏胶囊的设置。

- `decorateTabSeat` 的 `moveTitle` 恒为假（`client.js:6712-6772`），`[data-hotlist-tab-title]` 只在清理旧 DOM 时出现。
- 真机取证（meru-test 59570，5.3.4）：一个前台阻塞的会话在 tab 行是 `⏳`、`data-hotlist-motion="spin"`、`animation-name: hl-spin`、`animation-duration: 2.4s`，两次相隔 0.9 秒取 `transform` 分别是 `matrix(-0.93, 0.37, …)` 与 `matrix(0.43, -0.90, …)` —— 真的在转。
- 单测仍 **123 组**，第 97 组改名为 `tab seats always move the glyph and never wrap the host title`（`test:5159`），第 98 组的相位断言改读 tab 的图标。

## 5.3.2 — 2026-11-15

超级提醒从「进入状态就弹一次」改成**锁存等待**：状态要原样停够设定的分钟数才升起来，之后每隔同样的间隔再补一次、用完次数为止。另外顶栏胶囊与 tab 座位的动效**对齐了相位**，同一会话在两个面打开的是同一关键帧的同一位置。`SETTINGS_VERSION` 仍是 `4`。

**超级提醒：先等，再提醒，不刷屏**

- 新增两个数字行 `ring.afterMinutes`（默认 `7` 分钟、`1`–`60`）与 `ring.repeatTimes`（默认 `1` 次、`1`–`99`）：一个状态必须**原样停够** `afterMinutes` 分钟才第一次升窗，之后每隔同样的间隔再来一次，`repeatTimes` 用完即止。
- 三条边界是测试钉死的：**状态一变就重新计时**（类别变了重开钟，会话不再等/重新跑起来永不补弹）；**error 打开即确认**（该会话是当前会话时视作已确认、永不升窗——打开那个会话本身就是确认）；**长睡不补弹**（笔记本合盖睡过五个间隔，醒来只补一次，不会一次弹五个）。
- 完成状态有个例外：座位在保留窗口结束后掉出列表，但**没响过的那一次仍然欠着**，只欠一次。
- 等待与重复次数和开关一样走 `choices`，出厂预设升级规则不会把它们关回去。

**动效相位对齐（task-87）**

- 顶栏胶囊与 tab 座位的动效共用同一个 `fnv1a(sessionId | category)` 种子相位：两个面打开同一关键帧的同一位置（`animationDelay: calc(-1 * <phase>ms)`），看起来像同一个动画而不是各跳各的。

**其他**

- 设置页两行数字控件（`ring.afterMinutes` / `ring.repeatTimes`）随 `sanitizeSettings` 夹取范围（1–60 / 1–99），越界写回会被归一。
- 单测 **123 组**（5.3.1 是 121 组）。本版新增 2 组：tab 座位按 `motionTarget` 移动标题或图标、两个面从同一种子推出同一相位；原「进态即弹一次」的 ring 组整体重写为「停够分钟数、按配置重复」（`test:4503`）。
- 九份文档同步到 5.3.2：两版 README 的超级提醒节改写为锁存语义并在默认值表补 `ring.afterMinutes`/`ring.repeatTimes` 两行；`docs/ARCHITECTURE.md` §19 补锁存段（标记结构、三条边界、`choices` 覆盖）；`docs/TESTING.md` 组表 121 → 123 行；`AGENTS.md` / `llms.txt` 的超级提醒段落同步锁存语义。

## 5.3.1 — 2026-11-15

两件事：耳机门禁多了一层**你自己配的设备清单**（严格得更有道理），以及**四项出厂默认值**换成了作者在干净环境里实际调出来的一组。数据结构只多一个字符串数组、`SETTINGS_VERSION` 仍是 `4`。

**新增：设备清单（配置向导）**

- 设置页「超级提醒」组里，`audio.smart` 下面原来是「需要初始化」那行小字，现在换成一行**设备清单**：一句状态 + 三个控件（`{配置}` / `重新读取` / `文件位置`）。
- 点 `{配置}` 会把一段提示词复制到剪贴板，交给**你自己的 AI**：它在本机枚举所有音频设备、按规则分组、把耳机标出来，写成 `<DSH_HOME>\hotlist-audio.json`。写完之后不用关设置页——**每 60 秒自动重读一次**，也可以点「重新读取」立刻看。
- 四种配置态：**未初始化**（按系统类型判断）、**已配置 N 个（耳机 M 个）**、**已配置但没标出耳机**、**文件格式不对**（这时按钮文案变「重新配置」）。读不到宿主时另有「读不到状态」，非 Windows 显示「仅 Windows 可用」。
- 判定变成两层，顺序固定：**清单优先**——清单里有耳机，就以它为准，当前默认输出设备必须命中清单里的耳机才响（**白名单语义**：命不中就静音）；清单缺耳机、没文件、文件坏了，**退回原来那层「按设备类型判断」**，所以不配置不会变哑巴。
- 名字匹配三级：先比完全相等，再比「去掉括号里的型号 + 压空白 + 小写」后的相等，最后才是包含——**包含只在两串都至少 6 个字符时才成立**（Windows 上真有设备就叫「耳机」，不设门槛会把别人的设备也放进来）。
- `{配置}` 复制出来的提示词里带的是**宿主解析好的绝对路径**（清单文件路径、枚举脚本路径），AI 不需要猜 `%USERPROFILE%` 是什么，也不需要知道本插件的目录结构。写不进去时提示词要求它把 JSON 贴回来，你手动落盘。
- 随包多带一个**枚举脚本** `tools/audio-endpoint/audio-devices.ps1`（Windows Core Audio，经 PowerShell 读默认设备与全部端点）。它是给**你的 AI** 用的：提示词里带的是宿主机上的绝对路径，脚本本身不在插件运行时里执行；插件只读那份 JSON。
- 门禁的判定明确为**六步**（写进 `docs/ARCHITECTURE.md` §21/§22）：①`audio.smart` 关着 → 全放行；②非 Windows → 不响；③没有探测或探测超过 60 秒 → 不响；④探测没测出来或脚本报错 → 不响；⑤清单可用且点了耳机 → 当前设备名必须命中清单；⑥清单不可用时才退回「按设备类型判断」。
- 配置只是**叠加**，不改门禁原有语义：开关关着照旧全放行；开着但没有清单时，「不知道就不响」「试听永远会响」两条一条都没动。
- `window.__HOTLIST__.audio()` 多一个 `config` 字段（配置态摘要），原有字段一个没改。

**出厂默认值：四项改动**

- `maxSeats`：`6` → **`7`**（tab 行默认多一个座位）。
- `categories.running.surfaces.tab`：`false` → **`true`** —— 「进行中」重新进 tab 行。它原本两个座位面都不占，实际用起来是「正在跑的会话在 tab 行里看不见」。
- `topbar.customScope`：六类全 `true` → **只有 `pinned` 是 `true`**，其余五类 `false`。顶栏胶囊默认只用置顶类去借标题 emoji，别的类一律画插件自己的图标。
- `categories.pinned.sound.enabled`：`true` → **`false`** —— 置顶默认静音（它本来也没有内置音效，开着也只是个空开关）。

**升级时会发生什么（会有人问，所以写清楚）**

四项都进了 `LEGACY_VALUES`：存值与**旧出厂默认**相同、且没有 `choices` 标记的，视为「从没选过」，**跟着新默认走**；你在设置页真正动过的项带 `choices` 标记，**一律不动**。所以升级后你的设置在两种情况下会变——只有当你从来没碰过那一项时。`resetSettings()` 会给的就是这组新默认。

**测试与文档**

- 单测 **121 组**（5.3.0 是 115 组）。本版新增 6 组：四项出厂默认值、老预设自动升级/显式选择保留、配置六态派生、名字三级匹配与 6 字符门槛、清单白名单对门禁的作用、提示词不残留占位符与家目录。
- 九份文档同步到 5.3.1：两版 README 各新增一节讲设备清单与四态并在默认值表里改掉那四项；`docs/ARCHITECTURE.md` 新增 §22「音频配置链路」并把 §21 扩成六步；`docs/TESTING.md` 组表 115 → 121 行。

## 5.3.0 — 2026-11-15

一个新开关：**只在耳机时响**。数据结构只多一个布尔，`SETTINGS_VERSION` 仍是 `4`，读到的旧配置照原样生效、不需要迁移。

**新增：严格音频门禁（`audio.smart`）**

- 设置页「超级提醒」组下面多一行「只在耳机时响」，出厂**关**。开了以后，**只有当前默认输出设备被探测为耳机**时才播提示音；探测结果是音箱 / HDMI / 显示器 → **不响**；探测失败、超时、没有 `pwsh`、不是 Windows → **也不响**。
- 「不知道就不响」是刻意的。会误判的场景恰好是插件对着会议室外放的场景，所以宁可静音也不猜。
- 这门只作用于**自动播放**（会话状态变化触发的那次）。设置页里点试听是你自己的手动动作，**永远会响**——否则在扬声器上就没法确认素材是不是好的。
- 每次状态变化前先问一次宿主「现在默认输出是什么」：`GET /hotlist-audio`，**必须带 `x-hotlist-audio: 1`**（否则 403 —— 同 `x-hotlist-ring` 的道理），宿主侧 60 秒缓存，客户端按同一节奏预热一次。
- 探测在宿主用 PowerShell 的 Core Audio 接口跑（`tools/audio-endpoint/audio-endpoint.ps1`，随包分发），**只有 Windows 有这条路**；其它平台开关存得下，但永远静音。
- 被门禁拒掉的那次**不消耗 1500 ms 节流窗口**：门禁在节流之前判，跳过的提示音不算「刚响过」。
- 这个开关走 `choices`：你自己打开就是你的选择，出厂预设覆盖规则不会把它关回去。

**同一个改动里删掉的东西**

- 设置页「超级提醒」组里原来那行说明文字（`settings.ring.hint`）删了。三个开关加一句 hint 已经把话说清，那行是 5.2.0 从光圈改成透明动画时的过渡文案，越留越长。
- 换成同一组的 `audio.smart` 开关行，以及它下面一行「需要初始化」（`settings.audio.needSetup`）：首次使用会探测一次默认输出设备。

**只读探针**

- `window.__HOTLIST__.audio()` → `{ smart, state, kindGuess, name, error, asOf, pass }`，音效播放器还没挂时返回 `null`。`pass` 是门禁**此刻**会给出的答案（开关关着时永远是 `true`）。用户说「开了却不响」时先读它，别猜。

**测试与文档**

- 单测 112 → **115 组**（新增三组：门禁出厂关闭且只放耳机通过、ring hint 让位给 audio 开关、探针在首次探测前也能回答）。
- 九份文档（README 中英、AGENTS.md、llms.txt、CHANGELOG、CONTRIBUTING、`docs/ARCHITECTURE.md` / `EXTENDING.md` / `TESTING.md`）同步到 5.3.0；`docs/ARCHITECTURE.md` 新增 §21 讲门禁链路（设置 → 客户端门禁 → 宿主路由 → PowerShell → 60 秒缓存 → 与节流的关系）；两版 README 各新增一节「只在耳机时响」并补第 14 条已知限制。

## 5.2.1 — 2026-11-15

三个变化都属于「换个东西给你看」，不动设置、不动数据结构：`SETTINGS_VERSION` 仍是 `4`，读到的旧配置照原样生效。

**超级提醒（原名全屏提醒）默认改成透明动画**

- 新增 `-Anim Gif` 档，并且**成了默认**：屏幕正中升起一小段 320×320 透明动画——`error` 与 `pending` 共用 `smack.gif`（拍击，10 帧），`completed` 用 `wave.gif`（挥手，11 帧），30 ms 一帧，高度约占屏幕三分之一（上限 340 DIP）。**不铺暗底、不画光圈**，只有角色本体。
- `Expand` / `Breathe` / `None` 三档**原样保留**，还是那圈带光晕的琥珀色光环。素材缺失或解不开时脚本把 `$Anim` 改回 `Expand`，所以坏的安装退回光环而不是什么都不显示。
- 宿主路由多认一个查询参数：`GET /hotlist-ring?…&anim=Gif&cat=error`。`anim` 现在大小写不敏感；`cat` 只在 `Gif` 档有意义（`error` / `pending` / `completed`，非法值按 `pending`），`Expand` 档会**忽略** `cat` 而不是悄悄改写请求。三道闸（marker 头 403 / 2.5 秒冷却 429 / 脚本缺失 503）没变。
- 两份 GIF 在 `tools/attn-ring/media/`，随包分发（合计约 780 KB），由 `tools/attn-ring/build-media.py` 生成。

**随包弹出图改回静态，体积回落**

- `assets/*.webp` 从 5.2.0 的动画（约 1.6 MB）改回**静态**四档，合计 **681,462 字节**（约 681 KB）。每一档都是该尺寸的一张静图，`64` 是真缩略图，不是把大图缩下来的某一帧。
- 会动的片段**没有丢**，只是搬到了 `tools/attn-ring/media/`、归超级提醒用——这两个面本来就是两回事：弹出图是「这一格里的会话变了」，光圈是「整块屏幕叫你」。
- 顺手修正了 GIF 素材的调色板偏移：`build-media.py` 里的 shift 表原来差一位（`i → i-1`），整张图取到了调色板相邻的颜色（红粉噪点、红按钮偏藏蓝、腮红变蓝）。这次改成 `i → i+1` 并重新生成。**只影响观感，不影响任何行为**；文件字节数与修正前逐字节同长，文件名、帧数、体积都没变。

**顶栏胶囊改成常驻动效**

- 之前胶囊只在频率掷中时动一下，其余时间是完全静止的；一条不动的胶囊带挨着会动的侧栏图标，看着像坏了。现在**胶囊只要还在屏幕上就一直在动**，频率掷中时同一段动效**再补播一次**（`data-hotlist-chip-burst`），两者不互相打断。
- 两层都写在顶栏自己的样式表里（`CHIP_CSS`），keyframes 自带，所以侧栏适配器关掉时顶栏照动。两层之间靠特异性分层，**不用 `!important`**；`prefers-reduced-motion` 或 `display.reduceMotion: 'on'` 时一并停掉，连图标与标题子节点一起停。
- 早期那个只播一次的 `hl-chip-nudge` 已删除，它是旧方案的残留，留着会和常驻层抢同一条属性。

**测试与文档**

- 单测 109 → **112 组**（新增三组：胶囊两层动效、两段 GIF 与静态素材的字节数、`anim=Gif` 的参数与 `-GifCategory` 传递）。
- 九份文档（README 中英、AGENTS.md、llms.txt、CHANGELOG、CONTRIBUTING、`docs/ARCHITECTURE.md` / `EXTENDING.md` / `TESTING.md`）同步到 5.2.1；`docs/ARCHITECTURE.md` 新增 §20 讲胶囊动效分层，§19 补上 Gif 档与两份素材。

## 5.2.0 — 2026-11-14

两个新东西：随包的图会动了，以及整块屏幕的提醒光圈。不动数据结构、不写迁移，`SETTINGS_VERSION` 仍是 `4`。

**新增：全屏提醒（光圈）**

- 三个会话状态各一个开关：`ring.pending` / `ring.error` / `ring.completed`，**出厂全关**。开了以后，对应状态第一次出现时，屏幕最上层升起一圈琥珀色光环（带光晕），几秒后自己消失；点一下或按 Esc 立刻关，**不抢键盘焦点，不挡鼠标**。
- 光圈是**独立进程画的**（`tools/attn-ring/Show-AttnRing.ps1`，WPF 零依赖），所以它能盖住任务栏，也能盖住别的窗口，不像网页里的元素只能待在自己那一格里。
- 宿主半边新增一条路由 `GET /hotlist-ring`（`index.js`）。**必须带 `x-hotlist-ring: 1` 才会真的升起**，否则 403 —— 这样任何网页都没法靠 `<img src>` 弹一个全屏窗口出来。另有 2.5 秒冷却（连发返回 429）和「脚本缺失就 503」两道闸。
- 判定复用声音播放器的同一套边缘检测（跳过空会话与子代理；error > pending > completed），1500 毫秒节流共享。
- 三个开关走 `choices`：你自己打开就是你的选择，出厂预设覆盖规则不会把它关回去。

**新增：随包素材变成动图**

- `error` 与 `pending` 用「捶红按钮」那一小段，`completed` 用「打招呼」那一小段，都是 **动画 WebP**，浏览器直接播，没有逐帧换图的抖动。
- 源片是 500×500，正好等于弹出图默认的 390 CSS px @1.25 DPR，所以 `780` 与 `1560` 两档放同一个 500 px 动画（没有更高分辨率可取），`320` 是缩小版，`64`（只用于设置页缩略图）是第 0 帧静帧。
- **代价：`assets/*.webp` 从约 0.65 MB 涨到约 1.6 MB**，29 个文件变成 35 个。砍帧能瘦下来，但动作会一顿一顿，不值。

**新增：`tools/attn-ring/` 进仓库**

- `package.json` 的 `files` 只放 `tools/attn-ring`，**不带** `tools/meru-tts` —— 那个是给你自己造音效用的，1.6 MB 的 `pylibs` 不该塞进每个装了插件的人机器里。

**文档**

- 新增单测 2 组（`107 → 109`）：一组守光圈路由的三种闸门与「脚本真的在包里 + 真的在磁盘上」，一组守 `files` 白名单只放 attn-ring。
- 全文 `client.js:N` 行号按 7038 行版本重新映射（`6863 → 7038`，脚本逐条对符号定义取真值，0 条未映射）。

## 5.1.9 — 2026-11-14

元数据版本。不动行为、不动数据结构、不写迁移，`SETTINGS_VERSION` 仍是 `4`。

**新增**

- **插件列表里终于有名字、描述和图标了**，不再是裸包名。宿主不需要执行我们的代码就能读到这些（`pluginPackages.metaOf`）：`locale/en.json` 与 `locale/zh.json` 提供 `meta.title` / `meta.description`，`package.json` 的 `icon` 提供图标。两个资源都必须在 `exports` 里声明（`./locale/*.json`、`./icon`）、并且在 `files` 里带上，否则发布出去的 tarball 里没有它们，装了也查不到。
- 新增一组单测守住这件事：清单声明齐、图标真的被打包且不超过宿主上限 256 KiB、两种语言都非空。106 → **107** 组。

## 5.1.8

两处设置页口径修正，不动数据结构、不动 `SETTINGS_VERSION`。

- **座位上限去掉「自动」。** 那一行原本在一个标准 `[−] [值] [+]` 旁边挂了个「自动」按钮，是全局区里唯一长得不一样的控件；现在它和置顶上限、顶栏上限一样就是个数字。存过的 `'auto'` 仍然有效（按量到的宽度算），只是没有界面能去选它；第一次点 stepper 就写成一个具体数字。
- **最近对话展示时间 1–120 分钟，默认 17。** 原来是「设置页只给 1–36、只有 API 才到 120」的两层范围，默认 5。现在界面与存储一致（`0` 只留给 API 表示「不显示闲置」），默认 17。老安装里**没动过**的 5 会升到 17；只要在设置页动过一次这个数字，就打了选择标记，以后不再被默认值覆盖。

## 5.1.7

第一个**正式版**（此前 `5.0.0-alpha.1` 只发在 `alpha` tag 上，`latest` 从未指向它）。
版本号跳过 5.0.x 是为了记住这条线改了太多次：4.6.5 → 5.0.0-alpha.1 → 中间十几轮真机往返 → 5.1.7。

**新增**

- **会话热表页**（tab 行第三格）：当前热表逐行的类别 / 顺序值 / 标题 / 出现在哪三个位置 / 备注；下面是「未进入热表 N 条」，按原因分组折叠（子代理 / 空会话 / 无状态 …），组内带序号。改前那 234 条是纯 `<li>` 平铺，整页 `scrollHeight 5445`；改后收起态 1 屏。
- **判定顺序跟着设置走**：赢家 = 够得上的类别里 `order` 最小的（同 order 按内置顺序破平），所以拖动卡片顺序真的会改变谁赢。默认 order 下 `pinned` 排在最后（60）。
- **顶栏胶囊动效**：每颗胶囊上的图标跑该类别自己的动效与频率，`prefers-reduced-motion` 下停。
- **tab 座位的图标与动效终于生效**：宿主把标签包在 `span.tabLabel` 里，以前我们把图标插在它外面被 flex 裁掉了（真机 `[data-hotlist-tab-glyph]` 数恒 0）。现在插进文字节点同一个父节点。
- **每个类别三个位置开关补齐**：Tab 行 / 侧栏 / 顶栏各有自己的一行（以前只有顶栏有行，另两个只有头部小标签）；头部小标签与开关双向同步，`栏` 改成 `左`。
- **导出只留接口**：设置页不再有导出按钮，`window.__HOTLIST__.export(opts)` 照旧可用（裸调用也能work，它先合并实时状态）。文档里写清了这是给 AI/二次开发用的入口。

**修复**

- **双 emoji**：标题自带多个前导 emoji（如 `🧪❓ 待选择`）时，以前只剥第一个，剩下的和自己画的图标叠成两个。现在剥全部前导 emoji，`custom` 档取离文字最近的那一个；纯 emoji 标题不再被剥成空串变「未命名」。
- **槽位声明时序**（整页 `Failed to load plugins` 的真因）：`ctx.slots.inject(key, cb)` 的回调不是一个只许注册 `key` 的作用域；`register` 抛的是「这个槽还没被声明」。注册前一律先 `if (ctx.slots.spec(name) === undefined) return;`，各自的 `inject` 回声会再跑一次。
- **`scope: 'smart'` 空列表**：拿不到当前工作区时不再把所有会话当「跨工作区」，退化为不裁剪。
- **导出漏传 scope**：跨工作区置顶以前在导出里报成 `pinned`，而界面是 `idle`。
- **失败态被静默擦掉**：每轮 sync 只要会话还在跑就删掉它的错误记录，而真实 agent 错误恰恰发生在失败那一轮还在跑的时候——真 ⛔ 也会被擦掉。改成只在「有更新的用户消息」时清，TTL 仍兜底。

**升级**

- 无需迁移：`SETTINGS_VERSION` 仍是 4。老安装里等于旧出厂预设的值（`💤`、`blink`、`motionTarget: 'glyph'`、频率 `1`、音效关）跟随新默认；用户真选过的值由 `choices` 保住。
- `pinned` 默认顺序 15 → 60（旧值 0/1/15 视为老默认自动跟新）。

## 5.0.0-alpha.1

**Windows 桌面版顶栏（v5 第一版，alpha）。** 在窗口最上沿那条 40px 标题带里画一排会话胶囊，与对话区 tab 行并存、互不顶替。仍是 alpha：只在开发 profile 与网页预览里验过，桌面真机三条红线（`top===0`/`height===40`、不压左侧菜单与右侧窗控、拖拽带空隙可点）尚未实测。

- **顶栏**：`positions.topbar` 默认开；`shell.overlay` 里一条 `pointer-events:none` 的透明带，胶囊自己 `pointer-events:auto` + `-webkit-app-region:no-drag`，所以拖拽带照旧能拖。左边界用命中测试（`elementsFromPoint`）实测，只认「贴左边且宽度 ≤ 480」的元素——全宽容器不算占位，否则网页版会把胶囊推到屏幕外。窗控一侧写死 `WINDOW_CONTROLS_GUARD = 138`，不属于设置项。网页版默认不挂，靠 `topbar.previewInWeb` 预览。
- **谁出现在哪**：`CATEGORY_SURFACES` 重排——报错/待处理/已完成走顶栏，闲置/置顶走 tab 行，进行中两边都不占；`classify()` 六条分支都过 `categoryVisible()`，类不在本面就整体不出现（不再降级成闲置）。
- **标签显示设置**（`topbar.titleMode`）：`text` 仅显示文本 / `icon` 使用插件图标 / `custom` 自定义显示图标。三档都会剥掉会话名开头那颗 emoji，避免和图标并排成两个 emoji；旧值 `unified`/`two`/`smart` 与 `auto` 全部别名兼容，`SETTINGS_VERSION` 仍 4、无迁移。
- **自定义生效范围**（`topbar.customScope`）：按类别勾选是否用会话名开头的 emoji 替换图标，只在 `custom` 档出现；设置页第二行，六颗 chip。
- **置顶顺序默认 60**（原 15）：`LEGACY_DEFAULTS` 认 `0/1/15` 为老默认，用户自己写过的值照旧保留。
- **侧栏标题归属**：插件会剥掉行标题开头的 emoji 并记住宿主原文，退出时还原；标题被别的插件改写时只 `console.debug` 一次，不动手。
- **导出**：`window.__HOTLIST__.export({format})` 裸调用不再返回空数组；`scope` 三档在拿不到当前工作区时退化为不裁剪，默认 `smart` 不会空列表。
- **失败态修 bug**：原来每次 sync 都按「还在跑」清掉错误标记，而真实 agent 错误恰恰发生在失败那一轮还在跑的时候——真 ⛔ 会被擦掉。改成订阅 `api-session/activity`，只有出现更新的用户消息才清，TTL 兜底。
- **设置页**：三处座位数统一成同一个 stepper（只有座位上限带「自动」）；删「顶栏样式」与「右侧预留」两行（字段保留，API 可写）；单位统一；胶囊宽度 0% 显示「默认」。
- **测试**：93 组（4.6.5 是 65 组）。

## 4.6.5

**修掉 4.6.4 砸死的控件：被预设覆盖的字段，只要用户自己选过，就不再被覆盖。** 4.6.4 没有发布，
所以这版对外的变化是「4.6.3 → 4.6.5」；下面两段一起构成这次升级。

- **新增持久字段 `choices`**（`{ "<path>": true }`）：只有**用户自己写过**的字段才在里面。埋点是唯一写入口
  `writeSettings(patch)`，用**传进来的 patch** 判断（不是合并后的整体）——预设规则在 sanitize 阶段改写值，
  被它改写的不算用户选择。
- **闸门改成 `旧预设 && !choices[path]`**：没动过的字段仍然跟随新默认（4.6.4 的「出厂预设覆盖」保留），
  动过的字段永不覆盖。于是设置页里 `none` / `blink` / 「仅图标」/ 频率 100% / 关音效**都能真正落地了**——
  在 4.6.4 上这些都会回弹成默认值（选了等于没选）。
- **`resetSettings()` 一并清空 `choices`**：恢复默认就是重新认可出厂预设。`backups()` / `restore(i)` 把 `choices`
  和整份设置一起存取。`choices` 是已知字段，不进保留副本；`SETTINGS_VERSION` 仍为 4，无迁移。
- 设置页的 patch 现在只带**改动的那个字段**（`mergePatch` 往下多合一层，`{glyph: {motion}}` 不会再把上传池冲掉）。
- `VERSION` / `package.json.version` → `4.6.5`。

## 4.6.4

- Factory presets now replace older factory presets: a stored value that only ever equalled an
  earlier default (`💤`, `blink`, `none`, frequency `1`, sound off) follows the current default,
  so an existing install finally sees the ice cube and the new motion table. No user choice is ever
  overwritten — a value that is not one of our old defaults is kept byte for byte.

版本号跟 `client.js` 里的 `const VERSION` 一致，也与 `package.json` 的 `version` 一致（后者同时是 npm 分发版本号）。设置数据另有一套 schema 版本（`SETTINGS_VERSION`），两者不同：前者是发布版本，后者只在**数据结构**变化时才动。

## 4.6.3

**只调整默认参数，没有改任何逻辑。**

- **动效默认值**：报错 / 待处理 / 置顶改为「弹跳」并同时作用于标题（`motionTarget: 'row'`），已完成改为「旋转」；进行中仍是旋转，闲置仍是不动。
- **播放频率默认值**：报错 90%、待处理 90%、置顶 30%、已完成 100%、进行中 100%、闲置 0%（闲置不参与动效）。频率仍按「每个节拍掷一次骰子」的概率工作。
- **提示音默认开关**：报错 / 待处理 / 置顶 / 已完成四类默认开启，进行中与闲置默认关闭。
- **闲置图标换成 `🧊`**（冰块）：`💤` 是三个码位挤在一起，13px 下糊成一团；冰块对应「不用的会话已经凉了」，冷色也和其余五类拉开。
- 老安装已存的值原样保留——这批只是默认值，没有迁移，也不覆盖用户改过的东西。`SETTINGS_VERSION` 仍为 4，`VERSION` / `package.json.version` → `4.6.3`。

## 4.6.2

**删掉第 7 类「收藏」+ 最近对话窗口补单位、UI 收窄到 1–36。**

- **`favorite`（收藏）整类删除**：`CATEGORY_IDS` 从 7 类变 **6 类**——`pinned / error / pending / completed / running / idle`。类型、`CATEGORY_ORDER` 里的 `favorite: 60`、设置页那张第 7 卡（以及它的「预留、只读」文案与 `settings.pins.*` 之外的 `favorite` 相关 i18n）、`reserved` 字段一起删掉。**旧数据里的 `categories.favorite` 会被丢弃**（`RETIRED_PATHS`，读时扔掉、写回不再带），不迁移、不报错。置顶不受影响，**仍然接宿主原生置顶**。设置页从 7 卡变 **6 卡**。仓库里 `assets/favorite-*` 五张历史素材也一并删除（`manifest.json` 的类别表同步去掉它）。
- **老安装的旧默认顺序会被自动升级到新默认，逐类判断**：「某个值等于这一类的历史默认」就视为「用户没选过」，换成新版默认；改过的值原样保留。历史默认在 `LEGACY_DEFAULTS` 里：`pinned` 的 `0`（以及最早那版的 `1`）→ 新 `15`、`pending` 的 `20` → `10`、`completed` 的 `30` → `20`、`running` 的 `40` → `30`；`error` 一直是 `10`、`idle` 一直是 `50`，不需要动。所以「一次都没调过顺序」的老安装会整体看到新次序，只改过其中一类的则只保留它那一个值。
- **「最近对话展示时间」补单位、UI 范围改为 `1`–`36`**：字段仍是 `collect.recentWindowMinutes`，**单位是分钟**。存储层夹取仍是 `0`–`120`（`0` = 不显示 `idle`），所以**通过 API 写 90 依然有效并保留**；只是设置页那一行现在只给 `1`–`36`（默认 5），不再让人填 0 或 120。两层范围是分开的两个常量（`RECENT_WINDOW_MINUTES` 管数据、`RECENT_WINDOW_UI` 管界面），改代码时别把 UI 上限当数据上限。旧字段 `categories.idle.within` 仍按原路迁移到它。
- `VERSION` / `package.json.version` → `4.6.2`；`SETTINGS_VERSION` **保持 4**——删掉一个从不产出的类别不构成数据结构破坏，旧数据靠「读时丢弃 + 缺省补全」过关。

## 4.6.0

**置顶改接宿主原生 + 类别顺序与优先级按用户口径重排。**

- **默认展示顺序变了**：`error 10 / pending 10 / pinned 15 / completed 20 / running 30 / idle 50 / favorite 60`。旧版是 `pinned 0 / error 10 / pending 20 / completed 30 / running 40 / idle 50`。`pinned` 不再固定第 0 位，它的 `order` 也变成可编辑的 1–99。
- **判定优先级重排**：一个会话只属于一个类别，从高到低 `error > pending(审批/提问) > completed > running > pinned > idle`。置顶从「最高」降到「只高于闲置」——置顶会话报错了就进 `error`，不再霸着 `pinned`。
- **置顶改接宿主原生置顶**：读 `uiWorkspace.workspaces.list.getSnapshot().pinnedSessionIds`（最近置顶在前），`pinLevel` = 下标 + 1。插件的 `settings.pins`（手工置顶级 map）整块废弃——不再参与 `classify` / `sidebarStateOf`，旧盘上读时丢弃；设置页 `pinned` 卡里的「上移 / 下移 / 取消置顶」一段与对应 i18n 键（`settings.pins.*`）一起删掉。置顶/取消置顶用宿主侧栏行自带的菜单。
- **新增全局设置 `pinned.maxSeats`（默认 `3`，范围 `0`–`12`）**：全局区多一行「置顶最多显示」，`0` = 不显示置顶。`buildSeatPlan()` 里超出这个上限的 `pinned` 行会被丢掉（`pinned` 仍属优先通道，但受这条上限约束）。
- `VERSION` / `package.json.version` → `4.6.0`；`SETTINGS_VERSION` **保持 4**——没有结构破坏性变更，旧数据靠「读时丢弃 + 缺省补全」过关，不写迁移。

## 4.5.0

**设置页减法 + 内置音效换成两个 wav。首个公开版本。**

- **删掉设置页「浮层尺寸」那一栏**（`overlay.sizeMin` / `sizeMax`）。字段与「取中值再按视口收窄」的算法都保留，只是不再有 UI；想改用 API。
- **内置音效从 21 条 mp3 换成 2 个 wav**：`pending` / `error` → `attention.wav`，`completed` → `complete.wav`（`BUILTIN_SOUND`，`client.js:325`）。固定映射、一对一，不再随机挑 7 条之一。旧的 21 条 `*-1..7.mp3` 从 `assets/sounds/` 删除；上传池机制不变。
- 包名从本地命名空间 `@local/dsh-hotlist` 改为 **`dsh-better-notice`**，`package.json` 的 `version` 与 `VERSION` 对齐到 `4.5.0`（此前是 `1.0.0`）。
- 仓库随附 `tools/meru-tts/`：生成这两条提示音用的 TTS 小工具（不参与插件运行）。

## 4.4.0

**设置页按用户反馈做减法，动效改成「播放频率」。**

- 删掉四类行：`hideNativeDot`、快捷键三条（`Alt+Shift+[` / `]` / `S` 的行为全保留，只是不再有 UI）、「全部恢复默认」、「另有 N 个待处理会话未显示」提示条。
- 图标组不再选「尺寸」（固定 20px / 16px），「来源」与「上传」并排一行。
- 每类的动效「平均间隔（毫秒）」→ **播放频率滑块 0–1**（`glyph.frequency`，默认 `1` = 每拍都播，`0` = 不播）；旧值按 `f = 1 − (ms − 2000) / 58000` 迁移。
- `idle` 卡里的「收录窗口」搬成全局 **「最近对话展示时间」**（`collect.recentWindowMinutes`，默认 5 分钟，0–120）。
- **修 `motionTarget:'row'`**：根因不是没命中标题，而是文字 keyframes 只改 `opacity`、肉眼看不出动。给四个文字 keyframes 加 1–2px 位移（不加 scale，避免发虚）。
- 预览改成按播放频率**常驻循环**（原来只播一次，看不出频率感）。
- 修侧栏适配器漏传 `pinned` / `children`：置顶会话现在侧栏也显示 📌，「子代理在跑」也会并入 ⏳。

## 4.3.1

**修一个会让整页起不来的回归**（v4.3.0 引入，公开版首发即中招）。

- 症状：加载后只剩一条 `Failed to load plugins` 横幅，`web boot: 20 entries did not activate`，`ui-workspace` / `ui-open-in-app` / `ui-sidebar-terminal` 直接 `failed`，其余 UI 全 `pending (waiting for service: uiWorkspace)`；console 里 24 条重复的 `locale subscriber crashed: TypeError: command.label is not a function`。
- 根因：宿主要求快捷键命令的 `label` 是 **thunk**——`dsh-client-shortcuts/lib/client.js:1190` 与 `:1249` 都是 `label: command.label()`，直接调用。我们传的是 `t(...)` 的返回值（字符串），于是在 `refreshLabels()` 里抛错，把 `uiWorkspace` 一起拖下水。
- 修法：三处 `registerFixed` 的 label 改成 `() => t(...)`（`client.js:4677-4679`）。
- 为什么没被拦住：单测里 `shortcuts` 是桩，桩不调用 `label()`，所以「传字符串」在单测里永远看不见。补了一组 **`shortcut labels are thunks`** 断言：`typeof spec.label === 'function'`、调用返回非空字符串。教训写进 `docs/TESTING.md`：凡宿主会调用我们传入的回调，桩必须真的调一次。

## 4.3.0

- **快捷键**：`Alt+Shift+[` / `Alt+Shift+]` 循环切换座位（稳定环，当前会话不占座位也能正确前进/回绕）；`Alt+Shift+S` 手动弹一次速查浮层（默认关）。
- 路线走宿主的 `ctx.shortcuts.registerFixed` + `observeFixedInput`，不自建 `keydown`；`shortcuts` 是软依赖，服务缺失时座位照常挂载。
- 修掉 `cycleSeat` 的一个真 bug：原来用 `cycleIds.indexOf(current)` 定位，而当前会话永不出座 → index 恒 -1，按几次都跳回同一头/尾。
- 图标定种去掉时间锚（`${sessionId}|${category}`），同一会话在同一类别里刷新不再换图；`enteredAt` 整表删除。
- 设置页 shortcuts 区接线（`overlayEnabled` 真开关、`jumpEnabled` 恒灰「下一版」、只读键位行）。
- 文档补两条语义：**拒绝/中断也算完成**（`running → 非 running`）、**宿主 `refreshViews` 在会话释放后会抛一次**（不要用全局 `onerror` 兜）。

## 4.2.0

- **音效真的会响**：每类进入时播一次，三道闸——冷启动首轮不播（armed）、同会话同类去重（离开即清）、全局 1500ms 节流。`sound.enabled` 默认关。
- **内置 21 条音效**（`pending` / `error` / `completed` 各 7 条），打包进插件，由 host 半边注册 `/hotlist-sound` 前缀路由自服务（DSH 的 package-asset 路由只认图片，`.mp3` 会 404）。
- **素材池**：图标 / 弹出图 / 音效每池最多 6 份，用时随机取一份。图标按「身份」定种、弹出图与音效按「事件」随机。
- **对外 API**：`window.__HOTLIST__.{settings,assets}` + `docs/EXTENDING.md`。
- 旧 `sound.kind`（`none` / `chime1` / `chime2` / `alert`）读时迁移成 `{enabled, builtin, uploads}`。

## 4.1.0

- 七类清单模型落地：`pinned` / `error` / `pending` / `completed` / `running` / `idle` / `favorite`（预留）。
- 设置页改卡片式：7 张折叠卡 + 位置前缀行 + 五组（图标 / 动效 / 弹出 / 音效 / 顺序）；展开态高度从 1315px 收到 ≤520px；支持多卡同开（`sessionStorage`）。
- 每类独立「平均动效间隔」；删掉「减少动效」「原生点可见时」「同时播放动效上限」「会话跳转快捷键」等行。
- ✅ 持久化到 `localStorage`（7 分钟 TTL），修好「刷新后 ✅ 立刻消失」——根因是宿主 `sessions.list` 首拉前 `phase !== 'ready'`，剪枝把条目全删了。
- 图标定种种子去掉时间锚，刷新后不再换图。
- `hideNativeDot` / `takeOverStatusDot` 真正接线。

## 3.1.0

- 侧栏状态标记适配器（`createSidebarAdapter`）：DOM 增强插 glyph，不改宿主结构，卸载逐项还原（`misses() === 0`）。
- 官方设置页 `settings.section` 落地：全局区 + 8 状态表单（后来在 4.1 换成 7 卡）。
- CSS 动效五件套（spin / pulse / bounce / blink / none），只用 `transform` / `opacity`，`prefers-reduced-motion` 降级。
- 接管 `dsh-sessions-manager` 的状态点（注入 `[data-dsm-dot]{display:none !important}`），并保留其归档/回收站/星标等其余功能。

## 3.0.0

- 三级排序成型：待审 / 报错 / 刚完成 → 干活中 → 五分钟内闲置。
- 状态判据换成宿主真实数据（`uiSession.sessionStatus` 的 `running` / `pendingInteraction.kind` / `completionUnread`），⛔ 由自采 `api-session/error` 补齐。

## 2.1.0

- 座位 id 加 `hotlist-seat-` 前缀 + 模块加载时自愈 `localStorage` 里的视图偏好。此前座位注销会把持久化的 `view` 留成「不存在的视图」，触发 React #185 整页白屏。
- 座位注销延后到下一个宏任务，避开宿主 `refreshViews` 在会话释放窗口内抛 `binding: unknown session`。
- `healViewPreferences` / `repairSourcePreference`：切换会话时把源会话的 `view` 写回 `chat`。

## 2.0.0

- 每个会话占一个 `conversation.view` 座位（不再是「一个 tab 里套列表」）。
- 当前会话永不出座（它本身就是「对话」tab）。

## 1.0.0

- 第一个版本：注册 `conversation.view` 座位，面板里列出当前工作区的会话，点击切换。

## 0.x

- 调研阶段：确认 tab 行由 `slots.entries('conversation.view')` 渲染，座位注册 `{name, id, label, order}` + 组件即可；切会话走 `ctx.get('uiWorkspace').openSession(id)`。
