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
