# BookmarkSync

在一台 Mac 上同步 **Safari** 与 **Chrome / Edge / Brave / Vivaldi / Arc** 等 Chromium 浏览器的书签。本机运行，不上传任何数据，不需要账号。

[English](README.en.md) · [架构说明](docs/ARCHITECTURE.md)

---

## 它能做什么

- **多端双向同步**：Safari 算一端，每个装了扩展的浏览器用户配置各算一端。任意一端改了书签，其余各端跟着变。
- **每一端单独设置**：启用/停用、双向 / 只接收 / 只发送。
- **改动先看再执行**：扫描后逐项列出新增、修改、删除、冲突、顺序调整，注明改动来自哪一端、会写到哪些端，勾选后再执行。
- **自动同步**：检测到改动后延迟几秒自动执行安全的项目；删除默认不自动执行，可单独开启并设单次上限；冲突和大范围重排永远等你确认。
- **顺序也同步**：同一文件夹内的排列顺序，可指定以哪一端为准。
- **写入 Safari 很小心**：每次写入前完整备份、保真校验、原子替换、写完复读校验；Safari 开着时也能写入（macOS 26 实测立即生效）。
- **中英文界面**，跟随系统或手动切换。
- **干净卸载**：一键移除后台服务、各浏览器的连接配置、同步状态、备份、日志和偏好。

> 实测环境：macOS 26.5 + Safari 26.5 + Chrome。其他 Chromium 浏览器用的是同一套扩展接口，理论上可用，但尚未逐一验证。

## 安装

需要 macOS 14 或更高版本。

### 1. 装 App

从 [Releases](https://github.com/davie-01/Safari2Chrome-BookmarkSync/releases) 下载 `BookmarkSync-x.y.z.dmg`，把 BookmarkSync 拖进「应用程序」。

这个版本没有经过 Apple 公证，首次打开会被系统拦下（提示「无法验证是否包含恶意软件」）。放行方式二选一：

- **系统设置**：点「完成」关掉提示 → 打开 **系统设置 → 隐私与安全性**，往下找到「已阻止使用 BookmarkSync」那一条 → 点 **仍要打开** → 再确认一次（可能需要输入密码）。
- **终端一行命令**：

  ```bash
  xattr -dr com.apple.quarantine /Applications/BookmarkSync.app
  ```

  去掉下载隔离标记后就能正常双击打开。如果提示权限不足，在前面加 `sudo`。

> macOS 15 之前可以用「右键 → 打开」绕过，15 起 Apple 取消了这个入口，只能用上面两种方式。

也可以从源码编译：

```bash
git clone https://github.com/davie-01/Safari2Chrome-BookmarkSync.git
cd BookmarkSync
scripts/build-app.sh        # 编译、打包、安装到 ~/Applications 并注册后台服务
```

### 2. 给「完全磁盘访问权限」

Safari 的书签文件受系统保护。打开 **系统设置 → 隐私与安全性 → 完全磁盘访问权限**，把 BookmarkSync 加进去并勾选，然后在 App 的「权限」页点「重启后台服务」。

（每次重新编译安装后，如果用的是 ad-hoc 签名，这一项需要重新勾选。）

### 3. 装浏览器扩展

从 Release 下载 `bookmarksync-extension-x.y.z.zip` 解压，或直接用仓库里的 `extension/` 目录，然后：

浏览器地址栏打开 `chrome://extensions` → 打开右上角「开发者模式」→「加载已解压的扩展程序」→ 选择这个目录。

扩展 ID 是固定的（`dllnilcheahcklaiheddleegbdalbcjn`），换机器、重装都不变。

多个浏览器就在每个浏览器里各装一次；同一浏览器的多个用户配置也各装一次，它们在 BookmarkSync 里是各自独立的端。

## 用法

打开 BookmarkSync，五个标签页：

| 页面 | 用途 |
| --- | --- |
| 同步 | 扫描差异、逐项选择、执行、查看历史 |
| 端 | 每个浏览器的在线状态、启用开关、同步方式 |
| 规则 | 自动同步、延迟、自动删除上限、顺序基准端、Safari 运行时写入 |
| 权限 | 完全磁盘访问、后台运行、扩展连接、通知 |
| 高级 | Safari 书签文件位置、界面语言、存储与清理、重置同步状态、卸载 |

首次同步会把各端合并（相同书签自动配对），默认不删除任何东西。

菜单栏图标可以随时「立即同步」或打开主窗口；⌘Q 只收起窗口，后台继续同步，真正退出走菜单栏图标里的「退出」。

## 卸载

App 的「高级」页 →「卸载…」。它会移除后台服务注册、各浏览器的连接配置、同步状态与备份、日志、偏好和缓存，并把 App 移到废纸篓。**浏览器扩展要你自己在扩展页面删除**。

直接把 App 拖进废纸篓也可以：后台服务发现自己所在的 App 没了，会自动清理残留并退出。

## 数据放在哪

| 内容 | 位置 |
| --- | --- |
| 同步状态、设置、备份 | `~/Library/Application Support/BookmarkSync/` |
| 日志 | `~/Library/Logs/BookmarkSync/` |
| Safari 书签备份 | 上面目录下的 `Backups/`，每次写入前一份 |

备份和日志默认各保留 30 天，最近 10 份备份不论多久都保留，可在「高级」页调整。

## 常见问题

**书签会上传到哪里吗？**
不会。所有处理都在本机，没有服务器，也不需要登录。

**浏览器没开的时候呢？**
它的改动会等它下次打开时补上；Safari 一侧随时可读写。常驻后台同步开着时，两个浏览器都没开也在运行。

**会不会误删书签？**
删除默认不执行，要你勾选。自动删除可以单独打开，且有单次上限；检测到大量书签同时消失（例如 iCloud 正在重建）会给出警告并拒绝自动执行。Safari 每次写入前都有完整备份。

**Safari 开着能写入吗？**
可以，macOS 26 / Safari 26 实测写入后立即显示。如果不放心，可以在「规则」页关掉，改成等 Safari 退出再写。

**iCloud 书签同步会冲突吗？**
不会互相覆盖：写入前会比对文件指纹，文件在这期间变过就放弃本次写入，下次扫描重来。

## 目录结构

```
BookmarkSync/
├── extension/                浏览器扩展；界面和同步引擎也放在这里，App 复用同一份
│   ├── manifest.json         MV3 清单；key 字段锁定扩展 ID，换机器重装都不变
│   ├── background.js         扩展的 service worker：作为「执行器」读写本浏览器书签、
│   │                         上报书签变化、把界面请求转给后台服务
│   ├── agent-client.js       native messaging 客户端，与 App 的后台服务通信
│   ├── chrome-adapter.js     chrome.bookmarks ↔ 规范化树：读取、执行操作
│   ├── backup-order.js       解析 Chrome 导出的书签 HTML，按它恢复文件夹内顺序
│   ├── build-engine.mjs      用 esbuild 把 engine/ 打包成 native/Resources/engine.js
│   ├── engine/               同步引擎（纯 JS，App 在 JavaScriptCore 里跑同一份）
│   │   ├── coordinator.js    调度：扫描 → 预览 → 执行 → 复读 → 提交，设置与历史
│   │   ├── multi.js          多端逻辑：两遍合并、跨端冲突、各端基线、状态迁移
│   │   ├── hub.js            统一版本树（hub）的结构与操作
│   │   ├── diff.js           三方比较：重新识别、配对、分类成新增/修改/删除/冲突/顺序
│   │   ├── plan.js           把选择转成每端的操作序列，并在模拟器里逐条验证
│   │   ├── commit.js         执行后推进基线，只对确实一致的字段推进
│   │   ├── tree.js           树索引与内存模拟树
│   │   ├── util.js           URL 规范化、UUID、根节点常量
│   │   ├── url.js            WHATWG URL 序列化实现（JavaScriptCore 里没有 URL）
│   │   └── host.js           引擎在 App 里的入口：BMS.handle + 原生调用桥
│   ├── ui/                   界面，扩展页面和 App「同步」页共用
│   │   ├── index.html/ui.css/ui.js   差异列表、逐项选择、冲突、执行、历史、设置
│   │   ├── i18n.js           语言切换与文案查表
│   │   └── en.json           中文原文 → 英文对照表（App 也读这一份）
│   ├── icons/                扩展图标
│   └── test/                 56 项测试：引擎、多端、URL、界面逻辑、随机与压力测试
├── native/                   Swift 部分
│   ├── Package.swift         三个目标：SafariBookmarks、AgentCore、App 与 CLI
│   ├── Resources/            engine.js 打包产物、App 图标
│   └── Sources/
│       ├── SafariBookmarks/  Safari Bookmarks.plist 的模型与保真编辑
│       │   ├── PlistNode.swift        plist 节点，保留所有未知字段
│       │   └── SafariDocument.swift   规范化树、操作解析、保真校验
│       ├── AgentCore/        后台服务与本机集成
│       │   ├── Agent.swift            socket 服务、各端 RPC、自动同步调度
│       │   ├── EngineHost.swift       在 JavaScriptCore 里运行 engine.js
│       │   ├── SafariStore.swift      读写 Bookmarks.plist：备份、原子替换、复读校验
│       │   ├── StateStore.swift       同步状态，带 revision 的乐观并发
│       │   ├── NativeHost.swift       浏览器 native messaging 中继
│       │   ├── Installer.swift        登录项注册、各浏览器的连接配置
│       │   ├── Cleanup.swift          备份与日志的统计和按天清理
│       │   ├── Uninstall.swift        卸载清单、执行与残留检查
│       │   └── Support.swift          标识、路径、日志、JSON 与 socket 工具
│       ├── BookmarkSyncApp/  SwiftUI App（同一个二进制加 agent 参数就是后台服务）
│       │   ├── RootApp.swift          窗口与菜单栏、⌘Q 行为
│       │   ├── StatusView.swift       主窗口外壳、分段栏、同步页
│       │   ├── SettingsView.swift     端与规则两页
│       │   ├── PermissionSettings.swift  权限页
│       │   ├── AdvancedSettings.swift 高级页：语言、存储清理、卸载
│       │   ├── WebUI.swift            WKWebView 承载共用界面，桥接后台服务
│       │   ├── AgentLink.swift        与后台服务的连接和状态
│       │   ├── AgentSupervisor.swift  非常驻模式下的临时后台服务
│       │   ├── Models.swift           设置与状态的数据模型
│       │   └── Strings.swift          中英文查表
│       └── bmsync/           命令行：install/uninstall/status/dump/apply，以及 native host
├── scripts/
│   ├── build-app.sh          编译、打包 .app、安装并注册后台服务
│   ├── package.sh            出 dmg、扩展 zip 和校验和
│   └── dev/                  开发辅助：迁移演练、后台服务命令行、书签树对比
├── docs/ARCHITECTURE.md      架构与设计决策
└── .github/workflows/        CI（测试 + 打包）与 Release（打标签自动发布）
```

## 开发

```bash
cd extension && node --test test/*.test.js   # 同步引擎与界面逻辑的测试
cd native && swift test                      # Safari 读写、保真、引擎宿主的测试
node extension/build-engine.mjs              # 改了 extension/engine/** 之后重新打包
scripts/build-app.sh                         # 打包并安装
```

引擎是纯 JavaScript（`extension/engine/`），在 App 里用 JavaScriptCore 运行，在测试里用 Node 运行，两边是同一份代码。细节见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 许可

MIT，见 [LICENSE](LICENSE)。
