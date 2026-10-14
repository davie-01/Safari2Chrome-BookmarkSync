# 参与开发 / Contributing

BookmarkSync 是个自用工具开源出来的项目，欢迎 issue 和 PR。下面是上手需要知道的。

## 结构

```
extension/        浏览器扩展；engine/ 是同步引擎（纯 JS，App 和扩展共用），ui/ 是界面（两个宿主共用）
native/           Swift：Safari 书签读写、后台服务、SwiftUI App
scripts/          编译打包脚本
docs/             架构说明
```

同步引擎在 App 里用 JavaScriptCore 运行，在测试里用 Node 运行，是同一份代码。改动 `extension/engine/**` 之后要重新打包：

```bash
node extension/build-engine.mjs
```

## 测试

```bash
cd extension && node --test test/*.test.js   # 56 项：差异、计划、多端、离线补同步、URL 规范化、界面逻辑
cd native && swift test                      # 13 项：保真写入、操作语义与 JS 对齐、引擎宿主
```

改了操作语义要重新生成 Swift 对照夹具：`node extension/test/make-parity.mjs`。

界面改动可以跑截图脚本人工看一眼：`python3 extension/test/ui/shot.py`（需要 playwright）。

## 界面文案

中文是原文，`extension/ui/en.json` 是中英对照表，App 和扩展共用。新增文案时：

- JS：`t('中文')`，带变量用 `t('共 {n} 项', { n })`
- Swift：`t("中文")`，带变量用 `t("共 {n} 项", ["n": n])`

然后在 `en.json` 里补一条英文。没有对应条目时会原样显示中文。

## 提交前

- 两套测试都过
- 界面改动在默认窗口尺寸（820×600）下不出现滚动条，中英文都看一眼
- 涉及 Safari 写入的改动，务必保留「备份 → 保真校验 → 原子替换 → 复读」这条链路

## 许可与贡献者授权

本项目以 **GNU General Public License v3.0** 发布，见 [LICENSE](LICENSE)。

提交 issue 或 pull request 即表示你确认：

- 你拥有所提交内容的版权，或已获得权利人授权提交；所提交内容不侵犯第三方权利；
- 你的贡献以 GPLv3 授权给本项目及其下游使用者；
- 你同意项目维护者可将你的贡献**以其他许可条款再次发布**，包括专有许可。这是为了保留将来的分发余地——例如上架某些不接受 GPL 条款的平台，或与其他项目以不同许可集成。你本人对自己贡献的版权不受影响，仍可自行以任何方式使用。

如果你不接受第三条，请在 PR 中写明，我们可以讨论其他合并方式（例如改为可选模块）。

### Licence and contributor terms (English)

This project is released under the **GNU General Public License v3.0** (see [LICENSE](LICENSE)).

By submitting an issue or pull request you confirm that:

- you own the copyright in what you submit, or are authorised to submit it, and it infringes no third-party rights;
- your contribution is licensed to this project and its downstream users under the GPLv3;
- you grant the maintainers permission to **re-release your contribution under other licence terms, including proprietary ones**. This keeps future distribution options open — for instance platforms that do not accept GPL terms, or integration with differently licensed projects. You keep your own copyright and may use your own contribution however you like.

If you would rather not grant the third point, say so in the pull request and we can discuss another way to merge it.
