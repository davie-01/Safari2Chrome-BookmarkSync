# 隐私政策 / Privacy Policy

**生效日期 / Effective date：2026-10-14**

---

## 中文

### 一句话

BookmarkSync 不收集、不上传、不共享任何数据。没有服务器，没有账号，没有统计和遥测。所有处理都在你自己的电脑上完成。

### 扩展会访问什么

- **本浏览器的书签**（读取和写入）。这是扩展的唯一用途：把这个浏览器的书签与同一台电脑上的 Safari 及其他浏览器保持一致。

### 这些数据去了哪里

书签数据只在**同一台电脑的两个进程之间**传递：

```
浏览器扩展  ──Chrome 原生消息通信──▶  BookmarkSync.app（你安装在本机的配套程序）
                                      └─▶ 读写本机 Safari 书签文件
```

**数据不会离开你的电脑。** 扩展不发起任何网络请求，不包含任何第三方代码、分析工具或广告 SDK。你可以在源码中核实这一点。

### 本机存储了什么

| 位置 | 内容 | 保留 |
| --- | --- | --- |
| 浏览器的 `chrome.storage` | 一个随机生成的端标识（用于区分不同浏览器和用户配置）、同步设置 | 直到卸载扩展 |
| `~/Library/Application Support/BookmarkSync/` | 同步状态、书签映射、设置、Safari 书签备份 | 备份默认保留 30 天，且至少保留最近 10 份 |
| `~/Library/Logs/BookmarkSync/` | 运行日志（记录同步操作，不含书签内容的完整副本） | 默认 30 天 |

保留天数可以在 App 的「高级」页自行调整。

### 权限为什么需要

| 权限 | 用途 |
| --- | --- |
| `bookmarks` | 读取本浏览器书签以比较差异，并把其他端的改动写入。这是扩展的核心功能，没有它无法工作。 |
| `nativeMessaging` | 与本机的 BookmarkSync.app 通信。同步引擎和 Safari 书签读写都在那个程序里，浏览器扩展本身无法访问 Safari 的文件。 |
| `storage` | 保存本端标识和同步设置。 |
| `alarms` | 在书签变动后延迟几秒触发同步，避免频繁操作时反复执行。 |

扩展没有申请 `tabs`、`host_permissions`、`<all_urls>` 等任何访问网页内容的权限，也不注入任何脚本到你浏览的页面。

### 如何彻底删除

1. 在浏览器的扩展页面移除本扩展（会清除 `chrome.storage` 里的数据）。
2. 在 BookmarkSync.app 的「高级」页点「卸载…」，它会移除后台服务、各浏览器的连接配置、同步状态、备份、日志和偏好设置。

### 政策变更

本文件的任何修改都会体现在仓库的提交历史中，可随时查阅。如果未来处理方式发生实质变化，会在发布说明中明确告知。

### 联系方式

通过 GitHub Issues 反馈：<https://github.com/davie-01/Safari2Chrome-BookmarkSync/issues>

---

## English

### In one sentence

BookmarkSync collects nothing, uploads nothing and shares nothing. There is no server, no account, no analytics and no telemetry. Everything happens on your own computer.

### What the extension accesses

- **This browser's bookmarks** (read and write). That is the extension's only purpose: keeping this browser's bookmarks in step with Safari and other browsers on the same Mac.

### Where that data goes

Bookmark data only ever moves **between two processes on the same computer**:

```
browser extension  ──Chrome native messaging──▶  BookmarkSync.app (the companion app you installed)
                                                  └─▶ reads and writes the local Safari bookmarks file
```

**Nothing leaves your computer.** The extension makes no network requests and contains no third-party code, analytics or advertising SDKs. You can verify this in the source.

### What is stored locally

| Location | Contents | Retention |
| --- | --- | --- |
| The browser's `chrome.storage` | A randomly generated endpoint id (to tell browsers and profiles apart) and your sync settings | Until you remove the extension |
| `~/Library/Application Support/BookmarkSync/` | Sync state, bookmark mappings, settings, Safari bookmark backups | Backups kept 30 days by default, and the newest 10 regardless of age |
| `~/Library/Logs/BookmarkSync/` | Operation logs (what was synced; not full copies of bookmark contents) | 30 days by default |

Both retention periods are configurable on the app's Advanced tab.

### Why each permission is needed

| Permission | Purpose |
| --- | --- |
| `bookmarks` | Read this browser's bookmarks to compute differences, and write in changes made elsewhere. This is the core function; the extension cannot work without it. |
| `nativeMessaging` | Talk to BookmarkSync.app on this computer. The sync engine and all Safari bookmark access live in that app — a browser extension cannot reach Safari's files. |
| `storage` | Keep this endpoint's id and your sync settings. |
| `alarms` | Debounce: wait a few seconds after a bookmark change before syncing, instead of reacting to every edit. |

The extension requests no `tabs`, no `host_permissions`, no `<all_urls>` — it has no access to the content of any page you visit and injects no scripts.

### How to remove everything

1. Remove the extension on your browser's extensions page (this clears its `chrome.storage` data).
2. In BookmarkSync.app, open Advanced → **Uninstall…**, which removes the background service, every browser's connection file, sync state, backups, logs and preferences.

### Changes to this policy

Any change to this file is visible in the repository's commit history. If data handling ever changes materially, it will be stated in the release notes.

### Contact

Please open an issue: <https://github.com/davie-01/Safari2Chrome-BookmarkSync/issues>

---

Google Chrome is a trademark of Google LLC. Safari is a trademark of Apple Inc. BookmarkSync is not affiliated with, endorsed by or sponsored by Google or Apple.
