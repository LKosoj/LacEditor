# 0.15.0 · RC3 试用说明

> 本文保留为候选阶段历史说明。已转为 **0.15.0 正式版（构建 76）**，正式安装包为 `dist/LacEditor-0.15.0-arm64.zip`，发布验证见 [正式版记录](../AcceptanceReports/0.15.0-2026-10-21.md)。正式打包使用 `zsh Scripts/package-release.sh`；下文 RC3 的“尚未发布”“不合并”等描述只对应候选阶段。

RC3 为构建 75，基于 UI9 / RC1 / RC2，修复关联文件冷启动不显示窗口、设置按钮按下背景尺寸，并移除侧栏底部常驻说明。未发布到 GitHub。设置页显示「版本 0.15.0 · RC3（构建 75）」。

## 安装与数据

1. 在旧正式版正常退出，让未保存工作区完成保存。
2. 解压 `dist/LacEditor-0.15.0-RC3-75-arm64.zip`。
3. 将 `LacEditor.app` 拖到「应用程序」，替换旧正式版。
4. 打开后在设置页核对版本，检查收藏、分组、最近文件及原有标签。

候选版名称及 bundle ID 仍为 `LacEditor` / `com.laceditor.app`，沿用原正式版数据。
UI 实验版继续使用独立 App 和数据目录；体验文档入口、UI9 标识不会出现在候选版，不会自动写入示例文件。
若只在实验版添加过收藏或分组，这些数据不会自动迁入正式版。

程序包只适用于 Apple Silicon、macOS 26+。本机 ad-hoc 签名，没有增加自动更新或网络权限。

## 构建与验证

```sh
./Scripts/run-acceptance.sh
zsh Scripts/package-candidate.sh
```

打包脚本复用现有构建缓存，仅生成 ZIP，不安装、不提交、不打标签、不发布。
先完成静态分析，再打包签名，避免分析构建使已签名产物失效。
本轮验证证据见 [RC3 验收记录](../AcceptanceReports/RC3-2026-10-21.md)，文件关联维护见 [RC2 记录](../AcceptanceReports/RC2-2026-10-21.md)，原有连续交互与性能边界见 [RC1 验收记录](../AcceptanceReports/RC1-2026-10-20.md)。

冷启动回归使用隔离验收 App 与临时 home，直接发送 Launch Services 文件打开事件，断言前不发送 Dock 重开事件：

```sh
swiftc -parse-as-library Verification/FinderLaunchVerification.swift -o .build/finder-launch-verification
.build/finder-launch-verification "$PWD/.build/AcceptanceDerivedData/Build/Products/Release/LacEditor.app"
```

## 文件关联与开发构建

- 安装后从「设置 > 文件关联」查看当前 App 位置和系统默认应用，点击对应格式的「设为默认」。macOS 可能弹出确认；不会自动修改默认应用。
- macOS 按内容类型管理默认应用，同类型的扩展名共用设置。某些扩展名存在歧义（例如 `.ts` 可能被识别为视频）；非文本类型不提供批量设置，请在访达中按具体文件处理。
- Xcode Debug 使用 `com.laceditor.development` / `LacEditor-Development`，与正式偏好和工作区隔离。开发、验收和实验构建不声明文件关联。
- 普通 Release 构建的 `LSHandlerRank` 为 `None`；打包脚本只在临时复制件中改为 `Alternate` 后签名，ZIP 解压安装件才参与文件打开推荐。不要把 `.build` 内 App 当安装版运行。
- 历史版本保留 ZIP；避免长期保留多个解压的正式 App。当前本机五个历史 App 已校验归档到 `dist/Archives/`，原解压副本移入废纸篓。

维护命令（不会由 App 自动执行）：

```sh
zsh Scripts/file-associations.sh --audit           # 只读检查
zsh Scripts/file-associations.sh --clean           # 精确撤销副本登记，保留已安装 App 的文件关联
zsh Scripts/file-associations.sh --verify-open-with # 验证实际「打开方式」候选
zsh Scripts/file-associations.sh --archive-history # 校验归档 dist/版本号/LacEditor.app，移废纸篓
```

维护工具只识别 LacEditor 的明确 bundle ID；不更改系统默认应用、不重置 Launch Services 数据库。访达已展开的菜单可能有缓存，关闭后重新打开再检查。若手动从其他位置启动旧 App，系统仍可能重新登记它。

## 试用重点

- 关闭全部标签和窗口后，从 Dock 重开，侧栏、菜单及新标签均正常。
- Finder「打开方式」在保留原有未保存内容的同时打开目标文件。
- App 完全退出后双击已关联的 TXT / Markdown 文件，立即显示对应窗口，不需要点击 Dock；一次打开多个文件、恢复工作区后打开新文件也应正常。
- 标签拆出、合并、切换、关闭与退出恢复。
- 设置窗口焦点、侧栏收起/展开、提示消失、Markdown 预览与长文档滚动。

试用确认前，保留当前实验分支，不合并主分支或发布 GitHub 版本。
