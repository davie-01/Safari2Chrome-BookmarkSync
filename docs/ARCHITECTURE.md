# 架构说明

BookmarkSync 由三个部分组成：一个 macOS App（里面同时是后台服务）、一个浏览器扩展、一段两边共用的同步引擎。

```
BookmarkSync.app
  ├─ MacOS/BookmarkSync     SwiftUI 界面；同一个二进制加 `agent` 参数就是后台服务
  ├─ MacOS/bmsync           命令行 + 浏览器 native messaging 中继
  └─ Resources/
       ├─ engine.js         由 extension/engine 打包而成的同步引擎
       └─ web/ui/           和扩展共用的界面（含 en.json 文案表）

后台服务（登录项，或 App 打开时临时启动）
  ├─ EngineHost      在 JavaScriptCore 里运行 engine.js
  ├─ Coordinator     扫描 → 预览 → 执行 → 复读 → 提交（JS）
  ├─ SafariStore     保真读写 Bookmarks.plist、备份、原子替换、复读校验
  ├─ StateStore      统一版本 + 每端基线，带 revision 的乐观并发
  └─ Unix socket     ~/Library/Application Support/BookmarkSync/agent.sock（0600，校验对端 uid）
        ▲                                   ▲
   SwiftUI App                        bmsync（native host）
                                            ▲ Native Messaging
                                    浏览器扩展（执行器）
```

## 为什么这样分

- **引擎放在后台服务里**：浏览器没开时也能同步，多个浏览器可以同时作为同步端。
- **扩展只做执行器**：Chromium 的书签只能通过 `chrome.bookmarks` 修改，所以写入必须发生在扩展里。扩展响应后台服务的 RPC（`read` / `apply` / `ping`），并上报书签变化。
- **native host 不直接读 Safari 文件**：浏览器启动的子进程在 macOS 的 TCC 里归属浏览器，拿不到授予 BookmarkSync.app 的完全磁盘访问权限，所以它只做中继。
- **引擎是纯 JavaScript**：在 App 里用 JavaScriptCore 运行，在测试里用 Node 运行，同一份代码，能做完整的模拟测试和随机测试。

## 多端模型（hub and spoke）

- **统一版本（hub）**：一棵带稳定 id 的树，保存在 `state.json`。
- **每一端**（Safari、每个装了扩展的浏览器用户配置）各有一份映射（hub id ↔ 本端 id）和基线（上次一致的值）。
- **两遍**：① 把各端的改动合进 hub；② 把 hub 里该端还没有的改动写下去。
- **跨端冲突**：多个端改了同一项且不一致时，对照原始 hub 生成一条冲突，由用户选用哪一端的版本。
- **端离线**：不影响其他端；回来后先把离线期间自己的改动传出去，再补上错过的，不会把别人的新增误判成自己删了。
- **身份**：扩展端 id 是 `cr-<uuid>`（存在 `chrome.storage`）；native host 上报父进程可执行文件路径，后台据此判断浏览器种类。URL 从不作为身份。

## 差异与计划

差异（`engine/diff.js`）：重新识别（id 变了时只在证据唯一时重绑）→ 配对（同文件夹内按类型+标题+URL，再按 URL）→ 分类为 `modify` / `conflict` / `create` / `delete` / `deleteConflict` / `order`，并标注改动来自哪一端。一端有 ≥30% 已映射节点消失时给出警告。

计划（`engine/plan.js`）：转成每端的 `create / update / move / remove`，顺序是 创建 → 移动 → 修改 → 删除 → 排序，并在内存模拟器里逐条验证。创建按源树的前序排列。删除前检查子树，不能安置的子节点会拒绝这次删除。

## Safari 写入的安全门槛

1. 读取 → 在副本上执行 → **保真检查**（未涉及的节点、顶层容器逐值相等）→ 序列化后重新解析校验。
2. 备份到 `Backups/` → 比对 SHA-256 指纹 → 临时文件 + fsync + rename 原子替换 → 复读校验。
3. 不自动回滚（避免覆盖 iCloud 的并发改动），备份保留。
4. Safari 运行时也可写入（默认开启，可关闭）。

## 进程与服务

- 常驻开启时，后台服务是通过 `SMAppService` 注册的登录项（显示为 BookmarkSync）。
- 常驻关闭时，App 打开期间会拉起一个临时后台服务（`agent --exit-with-parent`），App 退出即结束。
- 后台服务启动时对 `agent.lock` 加 flock，保证同一时刻只有一个实例拥有 socket 和状态。

### macOS 打包上的三个坑

1. **`LSUIElement` 必须保留**：去掉后 launchd 拒绝 spawn 这个 bundle。App 在运行时调用 `setActivationPolicy(.regular)` 来获得正常的 Dock 图标。
2. **嵌套二进制要先签名**：`Contents/MacOS/bmsync` 必须在整包签名之前单独签。
3. **升级后要重新注册登录项**：launchd 会保留旧 bundle 的记录。

## 测试

| 层 | 命令 | 覆盖 |
| --- | --- | --- |
| 引擎与界面 | `cd extension && node --test test/*.test.js` | 首次合并、重复 URL、URL 规范化、改/移/删/恢复、冲突、排序与可疑重排、UUID 重建、崩溃重试、三端随机测试、离线补同步、跨端冲突、模式、状态迁移 |
| Swift | `cd native && swift test` | 规范化、保真写入、前置条件、与 JS 的语义一致夹具、状态并发、分帧、JavaScriptCore 里跑引擎自测 |
| 界面截图 | `python3 extension/test/ui/shot.py` | 用假数据渲染差异列表、设置、历史，人工核对 |

改引擎操作语义后要重新生成 Swift 夹具（`node extension/test/make-parity.mjs`）；改 `extension/engine/**` 后要重新打包（`node extension/build-engine.mjs`）。
