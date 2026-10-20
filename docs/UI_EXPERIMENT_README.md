# LacEditor 界面实验 UI1

版本：**0.15.0 · UI1（构建 64）**。分支：`codex/flclash-ui-experiment`。

本轮完成 UI0 的构建与数据隔离，以及 UI1 的主界面第一轮调整。借鉴 FlClash 的表面层级、紧凑列表和局部反馈，使用现有 SwiftUI + AppKit 实现，不需要安装 Flutter、Dart、Android SDK 或其他新开发环境。

## 安装体验

1. 解压 `dist/LacEditor-0.15.0-UI1-64-arm64.zip`。
2. 将「LacEditor 实验版.app」拖入「应用程序」。保留原有的「LacEditor.app」。
3. 打开实验版，在设置页核对 `0.15.0 · UI1（构建 64）`。首次为空白文档，需要从实验版内打开测试文件。

本机打包采用 ad hoc 签名，未进行 Developer ID 公证。若 macOS 阻止首次启动，按系统「隐私与安全性」中的提示允许打开。

## 构建

在 Xcode 打开 `LacEditor.xcodeproj`，选择 **LacEditor UI Experiment** scheme 后运行。该 scheme 使用优化的 `Experimental` 配置，适合比较日常操作体验。

终端打包：

```sh
./Scripts/package-experiment.sh
```

脚本复用 `.build/XcodeDerivedData`，生成一个约 3 MB 的 ZIP；不会安装 App、更新 Git 标签、推送 GitHub 或清理项目。`swift test` 仍用于本地测试；SwiftPM 命令本身不生成带实验版标识的 App 安装包。

正式 `Debug`、`Release` 的版本元数据和 `VERSION` 仍为 0.14.4（63）。在实验分支选择正式 scheme 会编译当前实验源码；要重建原正式界面，应先妥善保存未提交修改，再使用 `main` 的正式提交 `7024a03`。已安装正式 App 可以继续直接使用。

## 数据隔离

| 项目 | 正式版 | 实验版 |
| --- | --- | --- |
| App 名称 | LacEditor | LacEditor 实验版 |
| Bundle ID / 偏好域 | com.laceditor.app | com.laceditor.ui-experiment |
| Application Support 目录 | LacEditor | LacEditor-UI-Experiment |
| Finder 文件关联 | 保留 | 不声明文件关联 |

偏好、最近文件、收藏与分组、工作区和异常恢复均分离，不自动导入正式数据。两个 App 主动打开同一磁盘文件时仍会编辑同一文件，体验对比建议使用文件副本。

## 本轮变化与边界

- 原生窗口/标签/标题栏继续负责窗口行为；侧栏使用系统 `.sidebar` 材质，跟随窗口激活与外观状态。
- 统一侧栏的标题、文件行、悬停、选中态、文件夹展开图标和完整路径提示；减少多余分隔线。
- 折叠仅改变标题下方内容的可见高度，展开 220 ms、收起 180 ms，避免整块平移与淡入淡出；减少动态效果时直接切换。
- 删除滚动条配置中的整窗重复遍历；后台加载文件存在状态和身份；工具栏合并刷新并跳过相同呈现状态。
- 保留现有文本排版、字体、输入法、行号、编辑操作和 NT2 原生标题栏材质路径。

自动化、实际画面检查与尚未验证的项目见 [本轮验收记录](../AcceptanceReports/UI1-2026-10-20.md)。未测量前不承诺帧率或性能提升比例。

## 下一轮

UI2：分类设置、精简状态栏、查找与编解码窗口的统一样式、焦点与提示回归。

UI3：Markdown 阅读样式、分栏开关反馈、不同外观及无障碍收尾、Instruments 掉帧与内存对比。完整设计保存在 [实验方案](FLCLASH_UI_EXPERIMENT_PLAN.md)。确认实验效果后再合并正式版。
