# Chrome 应用店上架材料

Developer Dashboard 各字段的填写内容，可直接复制。改动扩展时记得同步更新本文件。

---

## 0. 操作顺序（重要）

拿 ID 和提交审核**必须分两步**，顺序错了会让已安装的用户连不上后台服务：

1. **上传草稿，不提交审核** → 从 Package 标签复制公钥、记下 Item ID
2. **改代码**：manifest 的 `key` 换成商店公钥，`Installer.swift` 的 `defaultExtensionID` 换成新 ID，并在 `allowed_origins` 里**同时保留旧 ID**
3. **发布 app 新版本**（带着新 ID 的 native messaging 配置）
4. **再提交扩展审核**

如果顺序颠倒——扩展先上线、app 还是旧 ID——用户从商店装上扩展后会连不上本机服务，直接给差评。

上架包由 `scripts/package.sh` 产出：

```
dist/webstore/bookmarksync-extension-<版本>-webstore.zip
```

这个包已去掉 `key` 字段（商店用自己的密钥分配 ID，manifest 带 `key` 会被拒），也不含 `test/`、`engine/`、构建脚本。

---

## 1. 基本信息

| 字段 | 内容 |
| --- | --- |
| 名称 | `BookmarkSync — 书签本机同步` |
| 简短说明 | `在本机同步 Safari 与 Google Chrome™ 的书签：差异预览、逐项选择、冲突处理、双向或单向。不联网，不上传。` |
| 类别 | 工作流与规划（Workflow & Planning） |
| 主语言 | 中文（简体） |
| 可见性 | **建议先选「不公开列出」(Unlisted)**，验证 ID 与本机通信都正常后再改公开 |

> 名称里不能出现 "Chrome"、"Google"、"Safari" —— 按[品牌指南](https://developer.chrome.com/docs/webstore/branding)，在名称或图标中使用他方商标需要书面许可，这是常见拒审原因。说明文字里以 "for Google Chrome™" 这类描述性引用是允许的，但要带 ™ 并附归属声明（见第 6 节）。

---

## 2. 详细说明（中文）

```
在一台 Mac 上同步 Safari 与 Chromium 系浏览器的书签。本机运行，不上传任何数据，不需要账号。

⚠️ 本扩展需要配合免费开源的 macOS 配套程序 BookmarkSync.app 使用，单独安装扩展无法工作。
下载：https://github.com/davie-01/Safari2Chrome-BookmarkSync/releases

【它能做什么】

• 多端双向同步 —— Safari 算一端，每个装了本扩展的浏览器用户配置各算一端。任意一端改了书签，其余各端跟着变。
• 每一端单独设置 —— 启用/停用，双向 / 只接收 / 只发送。
• 改动先看再执行 —— 扫描后逐项列出新增、修改、删除、冲突、顺序调整，注明改动来自哪一端、会写到哪些端，勾选后再执行。
• 自动同步 —— 检测到改动后延迟几秒自动执行安全的项目。删除默认不自动执行，可单独开启并设单次上限；冲突和大范围重排永远等你确认。
• 顺序也同步 —— 同一文件夹内的排列顺序，可指定以哪一端为准。
• 写入很小心 —— 每次写入 Safari 书签前完整备份、保真校验、原子替换、写完复读校验。
• 中英文界面，跟随系统或手动切换。

【隐私】

不收集、不上传、不共享任何数据。没有服务器，没有账号，没有统计和遥测。

书签数据只在同一台电脑的两个进程之间传递：本扩展 →（Chrome 原生消息通信）→ BookmarkSync.app。数据不会离开你的电脑。扩展不发起任何网络请求，不含任何第三方代码、分析工具或广告 SDK。

完整说明：https://github.com/davie-01/Safari2Chrome-BookmarkSync/blob/main/PRIVACY.md

【开源】

全部源码以 GNU GPLv3 开放，可自行审阅和编译：
https://github.com/davie-01/Safari2Chrome-BookmarkSync

【需要的权限】

• 书签 —— 读取本浏览器书签以比较差异，并写入其他端的改动。这是核心功能。
• 与本机应用通信 —— 与 BookmarkSync.app 交换数据。同步引擎和 Safari 书签读写都在那个程序里，浏览器扩展本身无法访问 Safari 的文件。
• 存储 —— 保存本端标识和同步设置。
• 闹钟 —— 书签变动后延迟几秒再同步，避免频繁操作时反复执行。

本扩展不申请访问网页内容的任何权限，也不向你浏览的页面注入脚本。

【系统要求】

macOS 14 或更高版本；Chrome 116 或更高版本。
已验证：macOS 26.5 + Safari 26.5 + Chrome。Edge、Brave、Vivaldi、Arc 使用同一套扩展接口，理论上可用。

———
Google Chrome 是 Google LLC 的商标。Safari 是 Apple Inc. 的商标。本扩展与 Google、Apple 均无关联，亦未获其背书或赞助。
```

---

## 3. 详细说明（English）

```
Keeps bookmarks in step between Safari and Chromium browsers on one Mac. Everything happens locally: no server, no account, nothing uploaded.

⚠️ This extension requires its free, open-source macOS companion app, BookmarkSync.app. The extension alone does nothing.
Download: https://github.com/davie-01/Safari2Chrome-BookmarkSync/releases

WHAT IT DOES

• Two-way sync across every endpoint — Safari is one endpoint; every browser profile with this extension is another. Change a bookmark anywhere and the rest follow.
• Per-endpoint settings — enabled or not, and two-way / receive only / send only.
• See changes before they happen — a scan lists every addition, edit, deletion, conflict and re-ordering, says which endpoint changed it and where it will be written, and applies only what you tick.
• Automatic sync a few seconds after a change, for the safe cases. Deletions are off by default and have a per-run limit. Conflicts and large re-sorts always wait for you.
• Folder order is synced too, with a configurable endpoint whose order wins.
• Careful with Safari — a full backup before every write, a fidelity check, an atomic replace, and a re-read afterwards.
• English and Chinese, following the system or set by hand.

PRIVACY

Collects nothing, uploads nothing, shares nothing. No server, no account, no analytics, no telemetry.

Bookmark data only ever moves between two processes on the same computer: this extension → (Chrome native messaging) → BookmarkSync.app. Nothing leaves your machine. The extension makes no network requests and contains no third-party code, analytics or advertising SDKs.

Full policy: https://github.com/davie-01/Safari2Chrome-BookmarkSync/blob/main/PRIVACY.md

OPEN SOURCE

All source is available under the GNU GPLv3, for you to audit and build yourself:
https://github.com/davie-01/Safari2Chrome-BookmarkSync

PERMISSIONS

• Bookmarks — read this browser's bookmarks to compute differences, and write in changes from other endpoints. This is the core function.
• Communicate with cooperating native applications — exchange data with BookmarkSync.app. The sync engine and all Safari bookmark access live in that app; a browser extension cannot reach Safari's files.
• Storage — keep this endpoint's id and your sync settings.
• Alarms — debounce: wait a few seconds after a bookmark change before syncing.

The extension requests no access to the content of any page you visit and injects no scripts.

REQUIREMENTS

macOS 14 or later; Chrome 116 or later.
Verified on macOS 26.5 with Safari 26.5 and Chrome. Edge, Brave, Vivaldi and Arc use the same extension APIs and should work.

———
Google Chrome is a trademark of Google LLC. Safari is a trademark of Apple Inc. BookmarkSync is not affiliated with, endorsed by or sponsored by Google or Apple.
```

---

## 4. 单一用途声明（Single purpose）

```
把这台电脑上 Safari 与各 Chromium 浏览器的书签保持一致。扩展只做一件事：读取本浏览器的书签、把它交给本机的配套程序做比较，并把其他浏览器的书签改动写回本浏览器。
```

English:

```
Keeping bookmarks consistent between Safari and Chromium browsers on the same computer. The extension does one thing: read this browser's bookmarks, hand them to the local companion app for comparison, and write back bookmark changes made in other browsers.
```

---

## 5. 权限理由（Permission justification，逐项必填）

**`bookmarks`**

```
扩展的核心功能就是同步书签。需要读取权限来枚举本浏览器的书签树并与其他端比较差异，需要写入权限来应用用户确认过的改动（新增、修改、移动、删除、重新排序）。没有这项权限扩展无法实现任何功能。
```

**`nativeMessaging`**

```
同步引擎和 Safari 书签文件的读写都在配套的 macOS 程序 BookmarkSync.app 中，原因是浏览器扩展无法访问 Safari 的书签文件（该文件受 macOS 系统保护，需要「完全磁盘访问权限」，只有本机原生程序才能获得）。本扩展通过 chrome.runtime.connectNative 与该程序通信，交换书签树和操作指令。通信双方都在用户自己的电脑上，数据不经过任何网络。配套程序同样开源，源码见 https://github.com/davie-01/Safari2Chrome-BookmarkSync
```

**`storage`**

```
用 chrome.storage.local 保存两样东西：一个首次运行时随机生成的端标识（用于在多浏览器、多用户配置的场景下区分各端），以及用户的同步设置（启用状态、同步方向等）。不保存书签内容本身。
```

**`alarms`**

```
用于延迟触发（debounce）。书签发生变动后等待几秒再执行同步，避免用户连续编辑时反复触发，也避免 service worker 被频繁唤醒。
```

**远程代码（Remote code）**：选「不，我不使用远程代码」。扩展的全部代码都在包内，不加载任何外部脚本。

---

## 6. 数据使用申报（Privacy practices）

### 收集的数据类别

**全部不勾选**，即「未收集或使用任何用户数据」。

依据：Chrome 应用店对「收集」的定义是数据被传出用户设备。本扩展把书签交给**同一台设备上**的配套程序，数据不离开设备，不经过网络，也不存在任何接收方。

> 如果审核方对此提出异议，退一步的答法是勾选「网站内容」并在说明中写明"仅在同一设备的两个本地进程间传输，不上传至任何服务器"。不要在第一次提交时就这么勾——那会引出更多追问。

### 三项合规声明

全部选「是」：

- 不将用户数据出售或转让给第三方（经批准的用例除外）
- 不将用户数据用于或转让用于与扩展单一用途无关的目的
- 不将用户数据用于或转让用于判断信用度或贷款目的

### 隐私政策 URL

```
https://github.com/davie-01/Safari2Chrome-BookmarkSync/blob/main/PRIVACY.md
```

---

## 7. 给审核员的说明（Notes for reviewer）

```
这个扩展需要配合一个开源的 macOS 配套程序才能工作，单独安装扩展不会有任何功能表现。

如需测试：
1. 从 https://github.com/davie-01/Safari2Chrome-BookmarkSync/releases 下载 BookmarkSync.dmg 并安装（未经 Apple 公证，首次打开需在「系统设置 → 隐私与安全性」中放行）
2. 在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中为它打钩（读取 Safari 书签文件所必需）
3. 安装本扩展后，点击工具栏图标即可看到两端书签的差异列表

关于数据流向：书签数据只通过 chrome.runtime.connectNative 发送给同一台电脑上的配套程序，再由它读写本机 Safari 的书签文件。扩展不发起任何网络请求。

代码中唯一的 fetch 调用位于 ui/i18n.js 第 20 行，加载的是扩展自身包内的 ui/en.json（中英文对照表），使用 chrome-extension:// 协议，不是外部请求。manifest 中没有 host_permissions，也没有任何远程代码加载。

全部源码（含配套程序）以 GPLv3 开放：
https://github.com/davie-01/Safari2Chrome-BookmarkSync
```

---

## 8. 素材清单

| 素材 | 要求 | 状态 |
| --- | --- | --- |
| 商店图标 | 128×128 PNG | ✅ `extension/icons/128.png` |
| 截图 | 1280×800 或 640×400，至少 1 张、最多 5 张 | ⬜ 待补 |
| 小型宣传图块 | 440×280（可选，影响推荐位曝光） | ⬜ 可选 |

截图建议拍这几张，顺序即展示顺序：

1. 扩展弹出页的差异列表（能看到逐项勾选和「来自哪一端」的标注）
2. App 主窗口的「同步」页
3. App 的「端」页（体现多浏览器）
4. 冲突处理界面

截图里避免出现真实的个人书签，用演示数据。`extension/test/ui/shot.py` 可以用假数据渲染界面。
