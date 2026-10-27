# BookmarkSync 固定周期任务事件化改造方案

整理日期：2026-10-27  
适用版本：BookmarkSync 0.2.0 及后续版本  
目标：移除应用稳定运行时的固定周期唤醒，将后台工作改造成事件驱动、按需执行和失败时一次性退避。

## 1. 目标与原则

本次优化的目标不是删除所有带时间参数的代码，而是消除“即使系统没有发生任何变化也会固定反复运行”的任务。

需要移除的周期源：

- App 每 3 秒执行一次的 Agent 重连检查。
- 临时 Agent 每 2 秒执行一次的父进程检查。
- Agent 每 30 秒执行一次的 Safari 兜底检查。
- Chrome 扩展每 1 分钟执行一次的 keepalive alarm。
- Agent 每 15 分钟执行一次的周期维护。
- Agent 主 RunLoop 每 1 天执行一次的空定时器。

以下一次性时间控制不属于空闲周期唤醒，应当保留：

- Safari 文件事件稳定等待。
- Chrome 书签变化防抖。
- 差异预览与搜索输入防抖。
- 请求和 RPC 超时。
- 连接失败后的一次性指数退避。
- 进程退出时的有界等待。

这些任务只在事件已经发生、请求正在执行或错误需要恢复时存在，不会在稳定状态下持续唤醒进程。

## 2. 当前固定周期任务

| 间隔 | 位置 | 当前用途 | 建议 |
| --- | --- | --- | --- |
| 3 秒 | `native/Sources/BookmarkSyncApp/AgentLink.swift:48` | App 检查是否需要重新连接 Agent | 删除周期定时器，改为 Socket 文件事件和断线后一次性退避 |
| 2 秒 | `native/Sources/AgentCore/Agent.swift:136` | 临时 Agent 检查父 App 是否退出 | 使用 `DispatchSourceProcess` 或父子进程 Pipe |
| 30 秒 | `native/Sources/AgentCore/Agent.swift:655` | 检查 Safari 运行状态及书签文件状态 | 使用 FSEvents、文件事件和系统唤醒通知 |
| 1 分钟 | `extension/background.js:224` | 保证 Chrome Service Worker 能恢复 Native Messaging 连接 | 删除周期 alarm，改为断线事件和一次性 reconnect alarm |
| 15 分钟 | `native/Sources/AgentCore/Agent.swift:582` | 同步兜底、清理、刷新清单、检查 App 是否被删除 | 拆分为各自对应的事件触发任务 |
| 1 天 | `native/Sources/AgentCore/Agent.swift:99` | 防止 Agent 主 RunLoop 返回 | 使用无定时器的 RunLoop Source 或 `dispatchMain()` |

完成改造后，Safari、浏览器和书签均无变化时，BookmarkSync 不应主动创建周期性应用层唤醒。

## 3. App Agent 重连改造

### 3.1 当前问题

`AgentLink.start()` 创建一个永久重复的 3 秒 Timer。即使已经成功连接，App 仍会每 3 秒被唤醒一次并检查 `connected`。

窗口关闭但菜单栏图标继续运行时，这个 Timer 仍然存在。

### 3.2 推荐方案

实现一个连接状态机：

1. App 启动时连接一次。
2. Socket 连接断开时立即尝试重连一次。
3. 连接失败后创建一个一次性指数退避任务，例如 1、3、10、30、60 秒。
4. 监听 BookmarkSync Application Support 目录。
5. 当 `agent.sock` 创建或替换时立即连接，并取消尚未执行的退避任务。
6. App 重新激活、用户点击菜单栏、开启常驻服务或重启 Agent 时立即尝试连接。
7. 连接成功后清空失败计数，不保留任何重连 Timer。

建议状态：

```swift
enum AgentConnectionState {
    case disconnected
    case connecting
    case connected
    case waitingRetry(attempt: Int)
}
```

目录事件用于快速发现 Agent Socket，指数退避只负责权限错误、目录监听失效等异常情况。稳定连接期间没有定时任务。

### 3.3 临时 Agent 联动

`AgentSupervisor` 启动临时 Agent 后，不应固定等待 0.4 秒再连接。可以监听以下事件：

- `Process.terminationHandler`：临时 Agent 异常退出。
- Socket 文件出现：Agent 已经完成监听。
- 启动超时：只为本次启动创建一次性安全截止时间。

## 4. 临时 Agent 父进程监控改造

### 4.1 当前问题

临时 Agent 每 2 秒调用一次 `getppid()`，用于判断启动它的 App 是否已经退出。

### 4.2 推荐方案一：DispatchSourceProcess

记录启动时的父进程 PID，并监听 `.exit`：

```swift
let parentPID = getppid()
let source = DispatchSource.makeProcessSource(
    identifier: parentPID,
    eventMask: .exit,
    queue: work
)
source.setEventHandler {
    exit(0)
}
source.resume()
```

需要把 `source` 保存为 Agent 的强引用属性，避免提前释放。注册完成后应再次检查父 PID，处理父进程恰好在注册期间退出的竞态。

Apple 将子进程监听父进程退出列为 Process Dispatch Source 的适用场景：

- [DispatchSourceProcess](https://developer.apple.com/documentation/dispatch/dispatchsourceprocess)
- [Dispatch Sources Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/GCDWorkQueues/GCDWorkQueues.html)

### 4.3 推荐方案二：父子进程 Pipe

父 App 启动临时 Agent 时创建 Pipe：

- App 保留写端。
- Agent 监听读端 EOF。
- App 正常退出、崩溃或被强制结束后，系统自动关闭写端。
- Agent 收到 EOF 后立即退出。

Pipe 对 PID 复用不敏感，适合后续进一步强化临时 Agent 生命周期管理。

## 5. Safari 书签监听改造

### 5.1 当前问题

当前已有文件与目录 DispatchSource，但仍每 30 秒检查一次：

- Safari 是否正在运行。
- `Bookmarks.plist` 的修改时间和大小。
- 必要时读取书签并计算规范化树指纹。

30 秒兜底降低了漏事件风险，但每天仍会产生约 2,880 次检查。

### 5.2 推荐事件组合

建议使用多层事件机制：

1. 使用 FSEvents 监听 `~/Library/Safari`，开启文件级事件。
2. 保留当前文件和目录 DispatchSource，作为低延迟快速通道。
3. 文件被删除、重命名或原子替换后，重新挂载文件监听。
4. 收到 `NSWorkspace.didWakeNotification` 后检查一次文件状态和指纹。
5. 收到 Safari 启动或退出通知后检查一次。
6. Agent 启动时建立文件状态与规范化树指纹基线。
7. Safari 路径或完全磁盘访问权限变化时重建监听。
8. 用户手动扫描、端点重新上线时执行一次完整读取。

FSEvents 可以记录最后处理的事件 ID。Agent 重启后可以从已保存的 ID 继续接收事件，减少停机期间漏掉变化的风险。

参考资料：

- [Apple FSEvents Programming Guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)
- [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace)

### 5.3 不建议单独使用 NSFilePresenter

`NSFilePresenter` 适合配合 `NSFileCoordinator` 使用。Safari、iCloud 或系统组件如果直接通过低层文件接口写入，Presenter 不保证一定收到通知，因此不能单独承担书签变化监控。

参考资料：

- [NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter)

### 5.4 删除 30 秒兜底前的验证方式

建议先引入“影子验证模式”：

- 文件事件正常触发真实处理。
- 30 秒检查暂时保留，但只记录是否发现了事件层没有报告的变化，不启动同步。
- 连续运行一段时间，覆盖 Safari 编辑、iCloud 同步、睡眠唤醒、文件原子替换和权限变化。
- 没有发现漏事件后，再删除 30 秒 Timer。

影子验证只用于开发验收，不应保留在正式版本中。

## 6. Chrome keepalive alarm 改造

### 6.1 当前情况

扩展当前要求最低 Chrome 116。Chrome 从 105 开始，`runtime.connectNative()` 建立的 Native Messaging 连接会保持扩展 Service Worker 存活。

连接成功期间不需要每分钟 alarm 来保持 Service Worker。

参考资料：

- [Chrome Extension Service Worker 生命周期](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle)
- [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)

### 6.2 推荐方案

1. 删除 `periodInMinutes: 1` 的周期 alarm。
2. Native Port 断开时立即尝试重连一次。
3. 连续失败时创建一次性的 `chrome.alarms.create("reconnect", { delayInMinutes })`。
4. 在 `chrome.storage.session` 中保存失败次数和下次重试时间。
5. Service Worker 因断线而被回收后，由一次性 alarm 唤醒并继续恢复。
6. `endpoint.hello` 成功后清除 reconnect alarm 和失败状态。
7. 如果不再使用 alarm，删除 manifest 中的 `alarms` 权限。

扩展重连退避可以采用 3 秒、10 秒、30 秒、1 分钟、5 分钟，并加入少量随机抖动，避免多个浏览器 profile 同时重试。

### 6.3 更彻底的方案

让 Native Host 在与 Agent 断开后继续保持与扩展的 Native Port，并监听 Agent Socket：

- Agent Socket 出现时，Native Host 重新连接 Agent。
- 连接成功后向扩展发送 `agent.available`。
- 扩展收到事件后重新发送 `endpoint.hello`。

这样 Agent 暂时离线期间也不需要扩展主动探测。

### 6.4 实时模式与低功耗模式

实时双向同步需要保留 Native Messaging 长连接，因为本机 Agent 不能主动调用 Chrome 书签 API。

可以提供两种工作模式：

- 实时模式：保持 Native Port，浏览器变化和 Safari 变化都能及时同步。
- 手动/低功耗模式：不保持 Native Port，Service Worker 允许休眠；Safari 的变化要等浏览器事件、打开扩展或手动同步后才能写入 Chrome。

两种模式都不需要固定周期 alarm。

## 7. Agent 15 分钟周期任务拆分

### 7.1 当前职责

一个 15 分钟 DispatchSourceTimer 同时处理：

- 自动同步兜底。
- Native Host 清单刷新。
- 备份和日志清理。
- App 是否被删除的检查。

这些任务没有共同的运行周期，应拆成各自的事件触发逻辑。

### 7.2 同步兜底

完整扫描应由以下事件触发：

- Safari FSEvents 或文件事件。
- Chrome `bookmarks.*` 事件。
- Chrome 端点上线或重新上线。
- 系统从睡眠状态恢复。
- Agent 启动。
- 同步设置变化。
- 用户手动扫描。
- 上一次同步失败或在运行过程中又出现新变化。

为了移除 6 小时安全扫描，应持久化：

- Safari 最后观察到的文件状态和规范化树指纹。
- 各端点最后读取到的指纹。
- 最后成功同步后的指纹。
- 未处理的 `dirtyGeneration`。
- FSEvents 最后事件 ID。
- 失败重试次数和 `nextRetryAt`。

只有成功完成写入和验证后才能清除 dirty 状态。

### 7.3 Native Host 清单刷新

改为以下时机运行：

- BookmarkSync 安装或升级。
- Agent 启动。
- 用户修改扩展 ID。
- 监听到已支持的 Chromium 浏览器首次安装或启动。

Agent 已经监听 NSWorkspace 应用启动事件，可以在识别到 Chrome、Edge、Brave、Vivaldi 等浏览器时，为对应浏览器刷新一次清单。

### 7.4 备份和日志清理

改为增长点触发：

- 新建 Safari 备份后立即执行备份保留策略。
- Agent 启动或打开新日志文件时执行日志保留策略。
- 用户修改保留天数后执行一次清理。
- 用户手动点击清理时执行。

文件只在这些事件发生时增长，因此不需要按固定周期扫描目录。

### 7.5 App 被删除后的自清理

监听 BookmarkSync.app 所在父目录：

- App 包消失时记录一次事件。
- 创建一个一次性的宽限检查，避免应用升级期间误清理。
- 宽限期内 App 重新出现则取消清理。
- 宽限期结束仍不存在时执行清理并退出。

这里的一次性宽限任务只在 App 实际消失后创建，不属于周期唤醒。

## 8. Agent 主 RunLoop 改造

### 8.1 当前问题

Agent 在主 RunLoop 上创建一个每天触发一次、回调内容为空的 Timer，仅用于防止 `RunLoop.main.run()` 返回。

### 8.2 推荐方案

可选择：

- 使用 `dispatchMain()`，并将需要在主线程处理的 NSWorkspace 通知投递到主队列。
- 向主 RunLoop 添加一个长期存在的非定时器 Source 或 Port。
- 由 AppKit/NSWorkspace 已注册的事件源维持 RunLoop，并增加明确的生命周期测试。

推荐使用明确的非定时器 Source，避免依赖隐含行为。Agent 会阻塞等待真实事件，不产生每日空唤醒。

## 9. 统一事件调度器

建议将所有变化统一送入 `ChangeCoordinator`：

```text
Safari FSEvents ─────┐
Chrome 书签事件 ─────┤
端点上线/断线 ───────┤
系统睡眠唤醒 ────────┼─→ ChangeCoordinator ─→ 扫描/同步
设置变化/手动操作 ───┤      │
同步失败 ────────────┘      ├─ 单任务运行
                            ├─ 事件合并
                            ├─ dirtyGeneration
                            └─ 一次性退避
```

核心规则：

1. 同一时间只允许一个扫描或同步任务运行。
2. 每次输入事件增加 `generation`，并记录变化来源。
3. 任务开始时保存 `startedGeneration`。
4. 运行期间收到新事件，只更新 generation，不启动并发任务。
5. 任务结束后，如果 generation 已变化，立即安排下一轮。
6. 只有写入和验证成功，才能清除对应 dirty 状态。
7. 失败采用一次性指数退避；新事件、系统唤醒或用户操作可以提前唤醒重试。
8. 防抖只用于合并同一批事件，不承担定期兜底职责。

建议的持久化状态：

```json
{
  "generation": 42,
  "lastCompletedGeneration": 41,
  "dirtySources": ["safari"],
  "lastSafariFingerprint": "...",
  "endpointFingerprints": {},
  "lastFSEventId": 123456,
  "retry": {
    "attempt": 2,
    "nextRetryAt": 1793097600000
  }
}
```

## 10. 不应误删的一次性时间控制

以下逻辑不需要改成完全无延迟：

| 位置 | 用途 | 处理建议 |
| --- | --- | --- |
| `extension/background.js` 300ms | 合并连续 Chrome 书签事件 | 保留 |
| `Agent.swift` 500ms | 等待 Safari 原子写入与多次文件事件稳定 | 保留 |
| `extension/ui/ui.js` 150ms | 合并连续差异选择 | 保留 |
| `extension/ui/ui.js` 200ms | 搜索输入防抖 | 保留 |
| `AgentClient.request()` | 请求超时 | 保留并确保成功后取消 |
| `Agent.rpc()` | 浏览器 RPC 超时 | 保留并确保成功后取消 |
| 断线重连 | 错误恢复 | 使用一次性指数退避，不使用重复 Timer |

把这些一次性控制全部删除，可能造成重复同步、事件风暴、永久挂起或高频重连，反而会增加 CPU 和 I/O。

## 11. 实施顺序

### 第一阶段：低风险、可直接替换

1. 用 `DispatchSourceProcess` 替换父进程 2 秒检查。
2. 用非定时器 RunLoop Source 替换一天空定时器。
3. 将 App 3 秒重连改成 Socket 事件和一次性退避。
4. 将 Chrome 周期 alarm 改成断线后一次性 alarm。

### 第二阶段：拆分周期维护

1. 将备份清理移动到备份创建后。
2. 将日志清理移动到 Agent 启动与日志打开时。
3. 将 Native Host 清单刷新移动到安装、升级和浏览器启动事件。
4. 用 App 路径事件替代 App 删除周期检查。

### 第三阶段：移除同步兜底轮询

1. 完善 FSEvents 和现有 DispatchSource 的协作。
2. 增加系统唤醒校验。
3. 持久化 fingerprint、dirty generation 和 FSEvents ID。
4. 修复失败重试和运行期间新事件处理。
5. 完成影子验证后移除 Safari 30 秒检查。
6. 移除 Agent 15 分钟和 6 小时完整扫描。

## 12. 验证场景

必须覆盖：

- App 窗口打开、隐藏、关闭，仅保留菜单栏图标。
- 常驻 Agent 正常运行、崩溃、被 launchd 重启。
- 临时 Agent 对应的父 App 正常退出、崩溃和强制结束。
- Safari 原地保存、原子替换、删除后重建书签文件。
- iCloud 连续重写 Safari 书签。
- 系统睡眠和唤醒期间两端都发生变化。
- Chrome、Edge、Brave 等浏览器启动和退出。
- Chrome Service Worker、Native Host 和 Agent 分别异常退出。
- 多浏览器 profile 同时在线、同时断线和同时恢复。
- BookmarkSync.app 升级、移动和拖入废纸篓。
- 完全磁盘访问权限运行期间被授予或撤销。
- 一轮同步运行期间再次发生书签变化。
- 网络或进程异常导致一次性重试多次失败。

## 13. 验收标准

### 空闲状态

- BookmarkSync App、Agent 和扩展代码不存在固定重复 Timer。
- 不存在周期 `chrome.alarms`。
- Safari 与 Chrome 没有变化时，不读取完整书签树。
- 不重复检查父进程、Socket、App 路径或浏览器清单。
- Instruments 中没有由 BookmarkSync 自身产生的规律性 2 秒、3 秒、30 秒、1 分钟、15 分钟或 1 天唤醒。

### 正确性

- Safari 和 Chrome 的变化都能触发同步调度。
- 系统睡眠期间的变化在唤醒后能够发现。
- Agent 或浏览器重启后可以恢复同步。
- 同步失败不会丢失 dirty 状态。
- 运行期间的新变化会在当前任务结束后继续处理。
- 不依赖周期扫描才能恢复正常状态。

### 资源指标

建议使用 Instruments 的 Energy Log、System Trace 和 Allocations 记录：

- 空闲唤醒次数。
- 空闲平均 CPU。
- App、Agent、Service Worker 和 Native Host 的 RSS。
- 一次 Safari 文件变化产生的事件数量。
- 一次 Chrome 书签编辑产生的扫描次数。
- 断线恢复期间的进程创建和重连次数。

最终目标：在没有书签、进程、权限和系统状态变化时，BookmarkSync 保持被动等待，不主动按固定周期运行任何应用逻辑。

## 14. 修订方案（2026-10-27 复核后）

本节对照源码核实了前文的假设，并根据结果调整方案。凡与前文冲突之处，以本节为准。

### 14.1 已核实的前提

- 扩展的 `minimum_chrome_version` 为 116，Native Messaging 端口连接期间 Service Worker 保持存活，6.1 的前提成立。
- 8.2 已实测：Agent 主 RunLoop 只挂一个 `NSMachPort`、不挂任何 Timer 时，仍能持续运行，并正常收到 NSWorkspace 的启动和退出通知。不能改用 `dispatchMain()`，因为这些通知依赖 RunLoop 送达。
- 修改 Safari 书签路径时，App 已经会重启 Agent（`AdvancedSettings.swift`），5.2 第 7 条不需要额外处理路径变化。
- **前文遗漏**：日志只在 `Log.open()` 时检查是否超过 2MB 并轮转。移除周期任务后，常驻 Agent 可能长时间不重启，日志会持续增长，因此需要改为写入时检查大小并轮转。

### 14.2 对前文的调整

| 前文 | 调整 | 理由 |
| --- | --- | --- |
| 5.2、7.2、9：持久化指纹、`dirtyGeneration`、FSEvents ID、`nextRetryAt` | 不持久化。调度状态只保留在内存中：generation 计数和重试计数 | Agent 启动时执行一次完整扫描，即可覆盖停机期间的变化；端点上线时同样会触发扫描。持久化状态需要处理版本兼容和文件损坏，收益很小 |
| 5.2：引入 FSEvents | 暂不引入。由影子验证的结果决定 | 现有目录和文件 DispatchSource 已覆盖原地写入、原子替换、删除后重建（`FileWatcherTests`）。FSEvents ID 只在需要跨重启续传时才有价值 |
| 5.2 第 4 条、7.2：系统唤醒后完整校验 | 唤醒后只做一次轻量检查：stat 和指纹，不读取各端书签树 | 睡眠期间本机不会产生书签变化；唤醒后到达的 iCloud 或 Chrome Sync 变化都会产生文件事件或书签事件 |
| 6.2 / 6.3 | 以 6.3 为主方案：Native Host 在 Agent 断开后不退出，用 `FileWatcher` 监听 `agent.sock`，重连成功后发送 `agent.available`。Agent 离线期间的请求立即返回不可用。扩展只在 Host 本身无法启动时退避 | 这样扩展在 Agent 离线时不需要主动探测。需同时处理两点：Host 对正在进行的请求返回错误；扩展收到 `agent.disconnected` 后立即让等待中的请求失败 |
| 6.2 退避 | 分两段：3 秒和 10 秒使用 `setTimeout`；30 秒及以上使用一次性 alarm，失败次数存入 `storage.session`。保留 `alarms` 权限 | `chrome.alarms` 的最短间隔是 30 秒；`setTimeout` 在 Service Worker 被回收后会失效 |
| 4.2 / 4.3 | 选择 stdin Pipe：App 启动临时 Agent 时，把 Pipe 设为它的 `standardInput`；Agent 带 `--exit-with-parent` 启动时，在线程中阻塞读取 stdin，读到 EOF 后退出 | 不受 PID 复用影响，没有"注册监听期间父进程恰好退出"的竞态，代码最少。常驻 Agent 不带此参数，不受影响 |
| 3 | 先把 `AgentSupervisor.ensureRunning()` 移出主线程，再改为 `agent.sock` 文件事件、`Process.terminationHandler` 和断线后一次性退避 | 界面卡顿的根源是主线程上 0.4～1 秒的 `sleep`，而不是定时器本身 |
| 7.5：监听 App 父目录 | 打开 `.app` 目录本身，监听 rename 和 delete；事件发生后安排一次 15 分钟宽限检查；升级替换后重新挂到新的 App 包 | 拖入废纸篓就是一次 rename，可以直接收到；不会被父目录中其他文件的变化误触发 |
| 5.2 第 7 条：完全磁盘访问权限变化 | 文件监听未建立时，在 App 被激活或 Agent 收到 status 请求时重试一次 | 授予权限没有对应的系统事件；用户授权后通常会回到 App |
| 7.4：日志清理 | 日志改为写入时检查大小并轮转；按保留天数清理的时机为：备份创建后、Agent 启动时、修改保留设置后 | 见 14.1 |
| 9：独立的 ChangeCoordinator | 在 Agent 内实现：generation 计数，加一个根据运行结果决定下一步动作的纯函数，便于单元测试 | 规模小，不需要独立组件和状态文件 |

自身写入引起的残余事件：Chrome 写入超出 1.5 秒抑制窗口后到达的书签事件，会使 generation 加一。最多因此多做一次扫描，扫描发现无需写入即停止，不会形成循环。

### 14.3 复核发现的正确性问题（并入第一阶段）

1. **自动同步失败后不重试**：`autoRun` 把"正在同步"作为 `{ skipped: 'busy' }` 正常返回；`changedSinceScan`、`staleState` 也作为结果中的 `errors` 正常返回（`ok: false`）。Agent 只在 `.failure` 分支重试，这两种情况都走不到；而 `autoDirty` 已在运行前清零，最坏要等 6 小时兜底扫描。
2. **预览失败后仍可执行同步**：`refreshPreview` 捕获错误后，`flushPreview` 照常完成，`doRun` 会用过期的 `ui.preview` 做删除确认，却用最新的选择执行。
3. **未收齐的分片不会严格在 2 分钟后释放**：过期清理只在收到新的消息编号（CID）时执行；没有限制总字节数和同时进行的消息数，也没有校验 `total`、`seq` 和单片长度。
4. **Safari 指纹没有初始基线**：首次检查只保存了文件状态，没有计算指纹，因此启动后 Safari 第一次只改元数据的重写仍会触发同步。
5. **每分钟 alarm**：由第二阶段的扩展改造一并解决（见 14.2）。

### 14.4 实施顺序（取代第 11 节）

**第一阶段：正确性修复**

1. 自动同步结果分类与 generation 调度：
   - `busy`、`changedSinceScan`、`staleState`、端点超时或离线：一次性退避重试，最多 5 次。
   - 其他失败：保留待处理状态，等待下一个事件。
   - 运行期间 generation 发生变化：结束后立即再执行一轮。
2. 预览失败时禁用执行，`flushPreview()` 返回本轮是否成功，`doRun()` 遇到失败即中止。
3. 分片：每条消息设独立的 2 分钟定时器；单条消息上限 64MB，同时最多 4 条；校验 `total`、`seq` 和单片长度。
4. Agent 启动时建立 Safari 文件状态和指纹基线。

**第二阶段：移除 App 与扩展侧的周期任务**

1. App 重连：`ensureRunning` 移出主线程；监听 `agent.sock`；使用 `terminationHandler`；断线后一次性退避。
2. 临时 Agent 改用 stdin Pipe 感知父进程退出。
3. Agent 主 RunLoop 改用 `NSMachPort`。
4. Native Host 负责重连 Agent；扩展使用两段退避；删除周期 alarm。

**第三阶段：拆分 15 分钟维护任务**

1. 清单刷新：Agent 启动时、Chromium 系浏览器启动时（按 bundle id 识别）、安装或修改扩展 ID 时。
2. 清理：备份创建后、Agent 启动时、修改保留设置后；日志改为写入时轮转。
3. 自清理：监听 App 包本身。

**第四阶段：移除同步兜底轮询**

1. 增加唤醒后的轻量检查，以及完全磁盘访问权限的重试。
2. 增加影子验证开关 `BMSYNC_SHADOW_POLL=1`，默认关闭，关闭时零开销。开启后保留 30 秒检查，只记录事件层漏报的变化，不触发同步。
3. 影子验证持续数天且没有漏报后，删除 30 秒检查，以及 15 分钟和 6 小时的完整扫描。

**完成后**：稳定状态下只剩由事件或失败触发的一次性定时（防抖、超时、退避、宽限期）。验收方式：代码中不再有重复定时器；活动监视器"能耗"页的"空闲唤醒"或 `powermetrics` 显示 Agent、App、Native Host 在空闲时没有规律性唤醒。

### 14.5 实施进度

| 项 | 状态 | 说明 |
| --- | --- | --- |
| 第一阶段 1～4 | 已完成 | 见 14.3；`AutoScheduleTests` 覆盖结果分类和调度 |
| App 3 秒重连 | 已移除 | 在以下时机尝试连接：启动、断线、`agent.sock` 出现、App 被激活，以及失败后的一次性退避（1～60 秒，8 次后停止）。`ensureRunning` 与 launchctl 已移出主线程 |
| 临时 Agent 2 秒父进程检查 | 已移除 | 改为检测 stdin 管道 EOF；stdin 不是 App 的管道时，退回到 `DispatchSourceProcess` 监听父进程退出 |
| Agent 每日空定时器 | 已移除 | 改用 `NSMachPort` 保持主 RunLoop 运行 |
| 扩展每分钟 alarm | 已移除 | 由 Native Host（`AgentUpstream`）负责重连 Agent，并发送 `agent.available`；扩展只在 Host 本身不可达时退避：3 秒和 10 秒用定时器，30 秒起用一次性 alarm，8 次后停止。`background.test.js` 与 `AgentUpstreamTests` 覆盖这些行为 |
| Agent 15 分钟维护 | 已拆分 | 清单刷新：Agent 启动时，以及 Chromium 系浏览器启动时（按 bundle id 识别，10 秒后补一次，因为首次启动时数据目录可能还未创建）。清理：Agent 启动时、Safari 写入并生成备份后、修改设置后。日志：写入时超过 2MB 即轮转（`LogTests`）。自清理：监听 App 包本身，消失后进入 15 分钟宽限期，期间重新出现即取消。随后在第四阶段删除了该定时器 |
| Agent 15 分钟同步兜底与 6 小时完整扫描 | 已移除 | 完整扫描只由事件触发：Agent 启动、Safari 文件变化、Safari 退出、Chrome 书签事件、端点上线、设置变化，以及失败后的一次性退避重试。永久性失败会等待下一个事件，不再定时重扫 |
| Agent 30 秒 Safari 兜底 | 已移除 | 改为：文件事件；Safari 启动与退出通知；系统唤醒后一次轻量检查（stat，文件变化时再计算指纹，不读取各端书签树）。文件监听建立失败（通常是没有完全磁盘访问权限）时，在唤醒和任何界面请求状态时重试。`AgentWatchTests` 覆盖仅凭文件事件发现变化、忽略元数据重写 |

实施中新发现的问题：Agent 先 `bind()` 后 `listen()`，socket 文件出现时还不能连接。Host 和 App 在 socket 事件之后的连接若被拒绝，都会在约 3 秒内补试几次（50 毫秒起翻倍）。这组补试不计入 App 的退避次数，因此即使退避次数已经用完，socket 出现时也一定会重连。

**现状**：稳定状态下，App、临时 Agent、常驻 Agent、Native Host 和扩展均不存在固定周期唤醒。代码中唯一的重复定时器是影子验证，默认不启动。

### 14.6 影子验证

用于确认文件事件和系统通知没有漏报。只记录日志，不触发同步，也不改变正常检查所比较的基线。

```bash
launchctl setenv BMSYNC_SHADOW_POLL 1
launchctl kickstart -k gui/$(id -u)/com.mars.davie-01.BookmarkSync.sync
```

开启后，Agent 每 30 秒检查一次 Safari 的运行状态和书签文件，在 `~/Library/Logs/BookmarkSync/agent.log` 中把事件没有报告的变化记录为 `shadow: missed …`（同一次漏报只记录一次）：

- `a bookmarks change`：书签变化被漏掉，需要排查。
- `a metadata-only rewrite`：只是元数据重写被漏掉，不影响同步，只用于了解监听覆盖情况。
- `Safari launched` / `Safari quit`：启动或退出通知被漏掉。

建议覆盖：Safari 编辑、iCloud 同步、睡眠唤醒、浏览器重启。验证结束后关闭：

```bash
launchctl unsetenv BMSYNC_SHADOW_POLL
launchctl kickstart -k gui/$(id -u)/com.mars.davie-01.BookmarkSync.sync
```
