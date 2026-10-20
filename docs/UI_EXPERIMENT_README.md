# LacEditor 界面实验 UI3

版本：**0.15.0 · UI3（构建 66）**。分支：`codex/flclash-ui-experiment`。

本轮在 UI1/UI2 基础上重做 Markdown 阅读样式，优化预览刷新与分栏状态保留，补充实际 WebKit 回归与性能记录。借鉴 FlClash 的表面层级、紧凑列表和局部反馈，使用现有 SwiftUI + AppKit 实现，不需要安装 Flutter、Dart、Android SDK 或其他新开发环境。

## 安装体验

1. 先正常退出正在运行的旧实验版，再解压 `dist/LacEditor-0.15.0-UI3-66-arm64.zip`。
2. 将「LacEditor 实验版.app」拖入「应用程序」。保留原有的「LacEditor.app」。
3. 在「设置 → 关于」核对 `0.15.0 · UI3（构建 66）`。新用户从空白文档开始；已有 UI1/UI2 用户沿用实验数据，只替换同名实验 App。

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

- Markdown 使用 15 px 系统字体、1.7 行高与最大 760 px 阅读宽度，重新调整标题、列表、引用、表格和代码块的间距；宽表格、长代码仅在局部横向滚动。
- 编辑更新现有页面，主题复用解析正文；预览保留滚动比例及表格/代码横向位置。「重新载入」恢复最新内容，不必再输入。
- 原生分栏隐藏时暂停渲染，重开时保留 WebKit 实例与分栏比例。分栏开关即时完成，避免宽度动画反复触发正文重排；真实撤销、选区与编辑器实例保持已测试。
- 侧栏标题与分组补充展开状态描述，键盘聚焦也能看到箭头及标题操作；减少动态效果时不播放悬停动画。
- 预览继续禁用文档 JavaScript，并限制资源为内联样式与 data 图片；不加载网络或本地路径图片，HTTP/HTTPS 链接由浏览器打开。
- 隐藏后的预览保留一个 WebKit 实例和已解析正文，有一定驻留内存成本；短循环测试不能证明长期无泄漏。50 MB 首次深区跳转仍有约半秒布局停顿，未宣称全场景提速。

UI1/UI2 已有变化继续保留：

- 设置左侧为五个分类，右侧分组并滚动；设置窗口默认 820 × 640，最小内容区 720 × 520。重复打开不重置已有分类，关闭后再次打开从编辑器分类开始。
- 查找窗口始终显示两种输入，选项集中一行，所有操作放在底部；转义说明仍为悬停显示。最小内容区 620 × 350，可调整窗口大小。
- 编解码窗口使用统一的标题、双栏表面和底部操作，保持自动换行与非模态；结果过期后禁止替换正文。
- 状态栏按宽度逐步隐藏次要信息，行列和任务信息优先；侧栏选中态区分窗口激活状态，并提供轻量按下反馈。
- 原生窗口/标签/标题栏继续负责窗口行为；侧栏使用系统 `.sidebar` 材质，跟随窗口激活与外观状态。
- 统一侧栏的标题、文件行、悬停、选中态、文件夹展开图标和完整路径提示；减少多余分隔线。
- 折叠仅改变标题下方内容的可见高度，展开 220 ms、收起 180 ms，避免整块平移与淡入淡出；减少动态效果时直接切换。
- 删除滚动条配置中的整窗重复遍历；后台加载文件存在状态和身份；工具栏合并刷新并跳过相同呈现状态。
- 保留现有文本排版、字体、输入法、行号、编辑操作和 NT2 原生标题栏材质路径。

自动化、实际画面检查、Instruments 覆盖与尚未验证项目见 [UI3 验收记录](../AcceptanceReports/UI3-2026-10-20.md)；历史记录见 [UI2](../AcceptanceReports/UI2-2026-10-20.md) 与 [UI1](../AcceptanceReports/UI1-2026-10-20.md)。未测量前不承诺帧率或性能提升比例。

## 可选性能复测

以下测试只使用临时夹具，不读取用户文档；默认 `swift test` 跳过压力负载：

```sh
LACEDITOR_UI_STRESS=1 swift test -c release --filter UIExperimentTests.testProfileInteractionWorkload
LACEDITOR_UI_STRESS=1 LACEDITOR_PROFILE_SIZE_MB=50 swift test -c release --filter UIExperimentTests.testProfileInteractionWorkload
```

输出的同步操作耗时包含 AppKit layout，不能当作显示帧时间；RSS 仅覆盖 XCTest 宿主，不包括 WebKit 子进程。完整设计保存在 [实验方案](FLCLASH_UI_EXPERIMENT_PLAN.md)。先体验独立候选包，确认后再决定合并正式版；多屏、非 Retina、VoiceOver、真实指针/IME 与长时间内存检查仍需继续。
