# BookmarkSync 性能与资源开销源码审计

审计日期：2026-10-26  
审计对象：BookmarkSync 0.2.0 当前源码  
审计范围：常驻后台、Safari 监控、Chrome 扩展、Native Messaging、同步引擎、桌面 UI、缓存、日志及状态文件。

## 1. 结论摘要

以当前约 500 个书签、约 292 KB 同步状态文件的规模，日常运行不太可能持续占用高 CPU。源码中没有发现核心监控定时器不断增加或书签树永久无限累积一类的严重内存泄漏。

主要问题分成三类：

1. **空闲唤醒偏多**：Safari 每 2 秒轮询、扩展每分钟 alarm、自动同步每 15 分钟进行兜底扫描。
2. **常驻内存组成较多**：后台 Agent、每个浏览器 profile 的扩展 Service Worker 和 Native Host，以及隐藏但没有退出的 SwiftUI + WKWebView 同时存在。
3. **大数据量峰值风险明确**：同级书签顺序使用平方级 LCS；同一轮扫描重复计算多次完整差异；书签树在 Chrome、Native Host、Swift、JavaScriptCore 和 UI 之间存在多份副本。

当前本机数据占用：

- `state.json` 约 292 KB。
- BookmarkSync Application Support 约 7.2 MB。
- 日志约 84 KB。
- StateHistory 保留 20 份左右完整状态副本，是当前磁盘占用的主要来源之一，但仍属可接受范围。

日志中 2026-09-22 至 2026-10-23 记录约 30 次实际自动同步，其中 18 次由 Safari 文件变化触发，暂未观察到持续事件风暴。每 15 分钟无变化的兜底扫描不会写成功日志，因此不包含在这个数字内。

## 2. 高风险问题

### 2.1 同级顺序比较为平方级时间和内存

源码：

- `extension/engine/util.js:32-49`
- 调用位置：`extension/engine/diff.js:313-317`
- 调用位置：`extension/engine/plan.js:219-225`

`lcsSet()` 为两个顺序数组分配完整二维矩阵：

```js
const dp = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
```

复杂度：

- CPU：`O(n × m)`。
- 内存：约 `4 × (n + 1) × (m + 1)` 字节，另有数组对象开销。

如果一个文件夹内有大量直接子项，单个矩阵的理论占用约为：

| 同级节点数 | 矩阵占用 |
| ---: | ---: |
| 2,000 | 15 MB |
| 5,000 | 95 MB |
| 10,000 | 382 MB |

差异判断和排序计划都会执行 LCS；多端、多轮差异计算还会进一步放大 CPU 开销。普通规模下不明显，但批量导入、全部书签集中于书签栏时可能产生明显卡顿、内存压力甚至被系统终止。

建议：

- 改用 Myers diff、Patience diff 或线性内存 LCS。
- 为单文件夹顺序比较设置阈值；超过 2,000 项时只提示“大范围顺序差异”，不自动计算精确移动计划。
- 增加 1k、5k、10k 同级节点的性能和内存基准测试。

### 2.2 一次扫描重复执行多轮完整差异计算

源码：

- `extension/engine/multi.js:91-217`
- `extension/engine/coordinator.js:111-149`
- `extension/ui/ui.js:368-383`

一次 `runMulti()` 对每个端点至少执行：

1. 跨端冲突计算一次 `computeDiff()`。
2. 第一遍合并计算一次。
3. 第二遍写入计划计算一次。

两个端点约执行 6 次完整差异，三个端点约执行 9 次。用户在预览页面每修改一次选择，150ms 防抖后又重新执行整个 `runMulti()`；已经开始的请求不能取消，连续操作可能在 JavaScriptCore 串行队列中排队。

当前用户选择只影响操作计划，不会改变源树或原始差异，因此多数差异计算属于重复工作。

建议：

- 将流程拆成“扫描并计算不可变差异”与“根据选择生成计划”。
- 缓存索引、配对结果、跨端冲突与基础 diff。
- 预览只重新计算 plan 和摘要。
- 为预览请求添加递增版本号；过期响应不再更新 UI。
- 同一时刻只允许一个预览计算，后续操作合并为一次最新计算。

## 3. 中等风险问题

### 3.1 自动同步每 15 分钟进行一次完整兜底扫描

源码：`native/Sources/AgentCore/Agent.swift:533-544`

定时器在启动 30 秒后开始，每 15 分钟调用 `scheduleAuto("periodic")`。当前 `autoSync=true`，无书签事件时每天也会执行约 96 次全量扫描。

完整扫描会读取并规范化 Safari plist、调用 Chrome `bookmarks.getTree()`、读取状态、构建索引并执行多轮差异计算。无变化时不会记录成功日志，因此容易被忽略。

建议：

- 将兜底周期调整为 1～6 小时。
- 保存各端 change generation；没有任何变化时不进行完整扫描。
- 在系统唤醒、浏览器重新连接、Safari/iCloud 文件变化后执行完整校验。
- 将“安全兜底扫描周期”设置为高级选项。

### 3.2 Safari 每 2 秒主动轮询

源码：

- `native/Sources/AgentCore/Agent.swift:576-609`
- `native/Sources/AgentCore/SafariStore.swift:17-19`
- `native/Sources/AgentCore/SafariStore.swift:52-55`

每次轮询执行：

- 查询 Safari 进程是否运行。
- 获取 `Bookmarks.plist` 的修改时间和大小。

每天约产生 43,200 次定时器唤醒。单次调用很轻，通常不会造成持续高 CPU，但会增加能耗、系统调用和磁盘元数据访问。

建议：

- 使用 `DispatchSourceFileSystemObject` 或 FSEvents 监听文件变化。
- 使用 `NSWorkspace` 应用启动/终止通知监听 Safari 状态。
- 保留 15～60 分钟的低频轮询作为漏事件兜底。
- 在系统休眠时自然停止监控，唤醒后做一次状态校验。

### 3.3 Safari mtime/大小变化可能触发无效同步

源码：`native/Sources/AgentCore/Agent.swift:595-607`

当前只比较修改时间和文件大小。Safari/iCloud 仅调整私有同步元数据或重新序列化文件，也会被认为是书签变化，从而触发完整扫描。5 秒自动同步延迟只能合并短时间内的连续变化，无法阻止间隔较长的后台重写。

建议：

1. 文件变化后等待其稳定。
2. 生成规范化用户可见书签树指纹。
3. 指纹未变化时只更新文件状态，不进入完整同步。
4. 区分“文件变化”和“用户书签逻辑变化”。

### 3.4 Chrome 扩展、Service Worker 和 Native Host 长期常驻

源码：

- `extension/background.js:193-201`
- `native/Sources/AgentCore/NativeHost.swift`
- `native/Sources/AgentCore/Agent.swift:146-184`

扩展通过 Native Messaging 长连接保持端点在线。这会使每个浏览器 profile 维持：

- 一个 MV3 Service Worker。
- 一个 `bmsync` Native Host 进程。
- Agent 内的一条连接和一个阻塞读取线程。

这是 Safari 变化后主动写入 Chrome 所需的架构取舍，通常不会形成明显 CPU占用，但会产生持续的基础内存开销。

同时，正常连接时每分钟 `keepalive` alarm 基本没有必要，每个 profile 每天额外唤醒 1,440 次。

建议：

- 连接正常后清除 keepalive alarm。
- 只在断线时创建重连 alarm，连接成功后取消。
- 为不需要实时同步的端点提供按需连接模式。
- 评估是否可以由书签事件和 Safari 变化按需建立连接，同时保留实时模式作为选项。

### 3.5 后台异常时重连过于积极

源码：

- `extension/background.js:170-175`
- `extension/background.js:197-201`
- `native/Sources/AgentCore/NativeHost.swift:72-91`

断线后 3 秒尝试重连；Native Host 单次会进行 15 次、每次间隔 200ms 的 socket 连接，并可能调用 `launchctl kickstart`。

在 App 未安装、清单错误、签名失效或后台服务持续无法启动时，可能出现进程反复创建、launchctl 调用和扩展反复唤醒。

建议：

- 使用指数退避：3 秒 → 10 秒 → 30 秒 → 1 分钟 → 5 分钟。
- 保证同一时间只有一个重连任务。
- 成功后重置退避。
- 连续失败时停止自动拉起并向 UI 明确显示原因。

### 3.6 完整书签树存在多份临时副本

源码：

- `extension/engine/coordinator.js:95-109`
- `extension/engine/coordinator.js:136-149`
- `native/Sources/AgentCore/NativeHost.swift:130-148`
- `extension/agent-client.js:71-85`
- `extension/engine/host.js:16-20`

一次扫描过程中可能同时存在：

- Chrome API返回的原始树。
- 规范化树。
- JSON字符串和指纹字符串。
- Native Messaging 消息 Data。
- Base64 分块。
- 浏览器端重组数组。
- JavaScriptCore 解析后的对象。
- 差异索引和两个模拟树。
- 最多 3 个扫描快照。

`FrameWriter.frames()` 先构造全部分块再发送；浏览器端同时保留 Base64 字符串、各分片字节及最终合并数组，造成明显的瞬时内存放大。

建议：

- 分块边生成边发送，不先构造完整 `[Data]`。
- 限制总消息大小、分片数和重组缓存时间。
- 扫描缓存只保留最新一份或设置 5～10 分钟过期时间。
- 只重新读取发生变化的端点。
- 减少 Swift ↔ JSON字符串 ↔ JavaScriptCore 的重复转换。
- 对超大书签库增加明确的保护性上限和错误提示。

### 3.7 同步完成后 UI 又进行一次完整扫描

源码：

- 内部验证：`extension/engine/coordinator.js:192-217`
- UI再次扫描：`extension/ui/ui.js:422-426`

`run()` 已经在执行后重新读取各端、提交状态并再次扫描验证。UI收到结果后又立即调用一次 `scan()`，造成额外的全量读取和多轮差异计算。

建议让 `run()` 返回最终验证得到的 items、preview、warnings 和 endpoints，UI直接使用，不再重复扫描。

### 3.8 差异列表没有虚拟化

源码：

- `extension/ui/ui.js:232-253`
- `extension/ui/ui.js:273-355`
- `extension/ui/ui.js:765`

所有差异项一次性创建 DOM。文件夹差异还可能为每项附带最多 200 个子节点；搜索框每输入一个字符都会重建完整列表。

首次同步、导入大量书签或出现数千条差异时，可能导致：

- WebView/Chrome 页面内存升高。
- 输入与选择操作卡顿。
- 主线程持续繁忙。
- 滚动性能下降。

建议：

- 使用虚拟列表，只渲染可见区域。
- 搜索增加 150～300ms 防抖。
- 用户展开文件夹时才生成子树 DOM。
- 对顺序差异和超大子树只显示摘要与前几十项。

### 3.9 隐藏窗口不会释放 SwiftUI 和 WKWebView

源码：

- `native/Sources/BookmarkSyncApp/RootApp.swift:79-114`
- `native/Sources/BookmarkSyncApp/WebUI.swift`

启用菜单栏图标时，⌘Q 被改为隐藏窗口而不终止 App。因此以下组件同时保留：

- SwiftUI App。
- WKWebView 与页面 JS状态。
- 上一次扫描结果和 DOM。
- 可能存在的 WebKit WebContent 相关进程。
- 后台 Agent。

这很可能是日常基础内存占用的主要来源之一，比 Safari 的 2 秒 stat 轮询更明显。

建议：

- 允许 UI App 真正退出，只让 Agent 常驻。
- 菜单栏入口可以由轻量帮助进程或 Agent 提供，重新打开时再启动 UI。
- 如果保留当前结构，窗口隐藏一段时间后释放 WKWebView、扫描结果和大型 DOM；重新显示时再创建。

## 4. 低风险或有界开销

### 4.1 最多保留 3 份扫描快照

源码：`extension/engine/coordinator.js:136-142`

数量有限，因此不是无限泄漏；但每份都包含状态和各在线端点的完整树，而且没有按时间过期。建议只保留当前扫描，或为旧扫描设置短期过期时间。

### 4.2 WebBridge 事件回调没有注销机制

源码：

- `native/Sources/BookmarkSyncApp/AgentLink.swift:129-130`
- `native/Sources/BookmarkSyncApp/WebUI.swift:78-82`

每创建一次 WebBridge 都向 `eventSinks` 追加闭包，没有 removal token。闭包弱引用 WebBridge，因此不会强行保活旧页面，但数组会积累失效回调，每次事件仍需遍历。

建议 `addEventSink()` 返回可取消 token，并在 WebBridge 销毁时注销。

### 4.3 RPC超时闭包无法提前取消

源码：`native/Sources/AgentCore/Agent.swift:199-213`

RPC提前成功后，对应的 90 秒或 300 秒 `asyncAfter` 仍保留至截止时间。正常频率下影响很小，短时间大量请求时会形成暂时性闭包和连接引用积累。

建议使用可取消的 `DispatchWorkItem`，收到响应或连接断开时取消。

### 4.4 UI状态刷新存在重复请求

相关源码：

- `native/Sources/BookmarkSyncApp/AgentLink.swift:76-175`
- `native/Sources/BookmarkSyncApp/WebUI.swift:149-174`
- `extension/ui/ui.js:770-787`

同一个端点或自动同步事件可能同时触发 Swift 状态刷新和 Web UI 的 `loadStatus()`；嵌入式 Web UI 的 status 路由还会再次调用 `link.refresh()`。

这会重复请求 hello、settings、pending、lastRun 和存储统计。它不会解析完整书签树，风险较低，但可以合并为单一状态快照，并增加 200～500ms 刷新防抖。

### 4.5 状态历史复制完整 state.json

源码：`native/Sources/AgentCore/StateStore.swift:20-38`

每次提交都复制完整状态文件，最多保留 20 份。当前约 292 KB/份，总体只有数 MB，主要属于磁盘冗余，不会造成明显常驻 CPU或内存问题。

当前无需优先优化。如果将来状态达到几十 MB，可改成压缩快照、差量日志或降低历史数量。

### 4.6 Safari 安全写入多次解析和复制完整 plist

源码：`native/Sources/AgentCore/SafariStore.swift:84-135`

写入过程会读取、解析、深拷贝、保真检查、序列化、再次读取和复读验证。这会产生短暂 CPU与内存峰值，但属于保护用户书签和防止并发覆盖的必要安全成本。

不建议为了节省资源删除这些步骤。可以通过后台队列、进度提示和大文件预警改善体验。

## 5. 未发现的严重问题

本次审计没有发现：

- Safari 2 秒定时器重复创建或数量不断增加。
- Chrome 书签监听器在同一 Service Worker 生命周期内反复注册。
- 同步历史、扫描缓存或日志完全没有上限。
- 核心书签树在每个 tick 中被完整读取；2 秒 tick 目前只做进程查询和文件 stat。
- Safari 写入产生的自触发事件立即形成明显无限循环；写入后会更新 `lastStat`，Chrome写入期间也有事件抑制窗口。

仍需注意，Chrome大批量写入超过 1.5 秒抑制窗口、Safari/iCloud 延迟重写以及后台反复启动失败，都可能产生一次或多次额外扫描，但从当前日志看尚未形成持续循环。

## 6. 建议实施顺序

### 第一阶段：阻止峰值问题

1. 替换或限制平方级 LCS。
2. 预览只重算 plan，不重算完整 diff。
3. 增加大书签库和超大单文件夹性能测试。
4. 为 Native Messaging 消息和重组缓存设置合理上限。

### 第二阶段：降低空闲能耗

1. 使用文件事件和 NSWorkspace 通知替换 Safari 2 秒轮询。
2. 将 15 分钟兜底扫描延长，并用变更代数跳过无变化扫描。
3. 正常连接时取消扩展每分钟 alarm。
4. 为连接失败增加指数退避。

### 第三阶段：降低 UI 和常驻内存

1. 同步完成后复用内部验证结果，取消重复扫描。
2. 差异列表采用虚拟滚动，搜索防抖，子树延迟渲染。
3. UI隐藏后释放 WKWebView，或拆分 UI App 与常驻 Agent 生命周期。
4. 为 WebBridge 回调和 RPC超时任务补充取消机制。

## 7. 建议补充的验证

源码审计不能替代真实运行测量。建议使用 Instruments 和统一测试数据完成以下基准：

- 空闲 30 分钟：Agent、App、Chrome Worker、Native Host 各自 CPU、唤醒次数和 RSS。
- App窗口显示、隐藏、真正退出后的内存差异。
- 500、5,000、20,000 个书签的扫描时间和峰值内存。
- 单文件夹 500、2,000、5,000 个子项的顺序比较。
- 1,000、5,000 条首次同步差异的 UI渲染和搜索响应时间。
- Native Host断开、App不存在、清单错误时 30 分钟的重连次数和进程创建次数。
- Safari/iCloud 连续重写时自动同步触发次数。
- 睡眠/唤醒、浏览器重启、多 profile 同时在线时的稳定性。

验收时建议记录：平均 CPU、峰值 CPU、空闲唤醒次数、常驻 RSS、峰值 RSS、单次扫描耗时、一次同步中的完整树读取次数以及 Native Messaging 总传输字节数。

## 8. 核实结果与处理状态（2026-10-27）

对照源码逐条核实后的结论与处理情况。基线 tag：`pre-perf`。

### 8.1 对原审计结论的更正

- **2.2**：“用户选择不会改变原始差异”不成立。第一遍会把选择应用到工作中的 hub（`multi.js` 的 `applyHubOps`），因此从第二个端点起的第一遍差异和全部第二遍差异都依赖选择，无法整体拆成“不可变 diff + plan”。与选择无关、可以缓存的只有跨端冲突（`crossConflicts`）。
- **3.4**：原生消息端口连接期间 Service Worker 本就常驻，每分钟的 alarm 只做一次空判断，不构成额外唤醒；它的作用是 Service Worker 被回收后恢复连接，予以保留。
- **3.2**：Agent 主线程原先阻塞在 `accept()` 循环，主 run loop 不运行，收不到 NSWorkspace 通知；已把 accept 循环移到后台线程，主线程运行 run loop。

### 8.2 审计未覆盖、本次新发现的问题

| 问题 | 位置 | 处理 |
| --- | --- | --- |
| 15 分钟定时器无条件广播 `changed`，UI 误报“书签有新变化”（自动同步关闭时也会） | `Agent.swift` `scheduleAuto` | 已修复 |
| `autoRun` 无待决定项时仍重复计算一次 preview | `coordinator.js` | 已修复 |
| 重新识别对每个丢失映射扫描全树，O(M×N)；Safari/iCloud 重建 UUID 时触发 | `diff.js` | 已修复（3000 节点 191ms → 18ms） |
| 每个双方都存在的 key 都构造 `info()`/`pathOf`，结果大多被丢弃 | `diff.js` | 已修复（单次 diff 约 -30%） |
| `run()` 每端读取 3 次；验证可复用写入后的读取 | `coordinator.js` | 已修复（3 → 2 次，UI 不再另扫） |
| 新选择的 preview 未返回前点击执行，删除确认可能被跳过或显示旧数量 | `ui.js` `doRun` | 已修复 |
| `changedSinceScan`/`busy` 时无限重试 | `Agent.swift` `runAuto` | 已修复：按运行结果分类（引擎多数失败以正常返回值报告），暂时性失败退避重试最多 5 次；运行期间又有变化则结束后再跑一轮（generation 计数） |
| 预览失败后仍可执行同步，删除确认使用过期计划 | `ui.js` `refreshPreview`/`doRun` | 已修复：预览失败即禁用执行，`doRun` 在没有当前计划时中止 |
| Safari 指纹没有初始基线，启动后第一次元数据重写仍会触发同步 | `Agent.swift` `tick` | 已修复：首次检查即建立基线 |
| 顺序对比中空标题书签遮蔽翻译函数 `t`，列表渲染抛错 | `ui.js` `renderOrder` | 已修复 |
| `kv` 字典跨队列读写 | `Agent.swift` `afterRun` | 已修复 |

### 8.3 原审计条目处理状态

| 条目 | 状态 |
| --- | --- |
| 2.1 平方级 LCS | 已修复：唯一 key 下改为 LIS，O(n log n) 时间、O(n) 内存；1 万项 1ms |
| 2.2 重复差异计算 | 部分处理：跨端冲突按扫描缓存；UI 同时只发一个 preview，期间的选择合并为一轮 |
| 3.1 15 分钟兜底扫描 | 已移除：完整扫描只由事件触发（启动、书签事件、端点上线、设置变化、失败后的一次性重试），详见 `EVENT-DRIVEN-TIMER-OPTIMIZATION.md` |
| 3.2 Safari 2 秒轮询 | 已移除：由文件事件（目录 + 文件，DispatchSource）、NSWorkspace 启动/退出与唤醒通知驱动检查，不再轮询。可用 `BMSYNC_SHADOW_POLL=1` 开启仅记录日志的影子验证 |
| 3.3 mtime/size 误触发 | 已处理：比较规范化书签树指纹，未变化不同步 |
| 3.4 keepalive alarm | 保留（见 8.1） |
| 3.5 重连过于积极 | 已修复：扩展单任务指数退避；Native Host 每进程 60 秒内最多 kickstart 一次 |
| 3.6 多份树副本 | 部分处理：Native Host 边编码边发送分片；扩展到达即解码，每条未收齐的消息有独立的 2 分钟到期定时器，单条消息上限 64MB、同时最多 4 条，并校验 `total`、`seq` 与单片长度。扫描快照仍保留最多 3 份（有上限，按当前规模影响很小） |
| 3.7 同步后 UI 重复扫描 | 已修复 |
| 3.8 差异列表 | 已处理：分批渲染（每批 300 行）、折叠内容展开时才生成、搜索 200ms 防抖 |
| 3.9 隐藏窗口保留 WKWebView | 已处理：窗口收起或关闭时释放 WebView，再次显示时重建 |
| 4.2 事件回调不注销 | 已修复：按 owner 弱引用登记，自动清理 |
| 4.4 状态刷新重复请求 | 已处理：300ms 合并；Web UI 的 status 不再额外触发刷新 |
| 4.3 RPC 超时闭包 | 已修复：收到回复即取消，超时任务只弱引用连接 |
| 4.5 / 4.6 | 维持现状 |
