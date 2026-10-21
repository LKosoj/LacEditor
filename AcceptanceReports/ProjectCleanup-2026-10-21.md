# 0.15.0 发布后项目清理

日期：2026-10-21。按用户“发布到 GitHub，搞定之后清理项目无用文件”的要求，在发布与下载验证成功后执行。

## 发布回读

- 远端 `main` 与带完整说明的注释标签 `v0.15.0` 已推送，应用源码提交为 `3d81005de789102f890af83a8270f5cf58c2253c`。
- [GitHub Release](https://github.com/kolmh/LacEditor/releases/tag/v0.15.0) 为非草稿、非预发布，`releases/latest` 返回 `v0.15.0`。
- 附件 `LacEditor-0.15.0-arm64.zip` 为 3,185,869 字节；GitHub 返回的 SHA-256 与本地一致：`d6c01446dd37befab94f57446c4ce3eb89d4c52770159ca9c232da73bd693960`。
- 实际重新下载 ZIP 和 `.sha256`，校验通过，ZIP 与本地逐字节比较一致。远端 README Git blob 与本地一致，当前版本与更新链接均为 0.15.0。
- 清理前核对 12 类常见文本格式的实际「打开方式」候选，LacEditor 均只有 `/Applications/LacEditor.app`；撤销项目 Debug、验收等确切副本登记，没有重置系统关联数据库或修改默认应用。

## 已清理

- `/Users/jia/Documents/LacEditor/.build`：清理前 2,572,256 KiB，约 2.45 GiB。包括 SwiftPM/Xcode 缓存、依赖检出副本、测试样本、Instruments trace、临时诊断程序、下载校验副本和解压测试 App。
- Vendor 下 11 个 `.swiftpm/xcode` 空目录及其空父目录；未删除任何 Vendor 源码、配置文件或依赖锁文件。
- 项目根目录和 `dist` 中两份忽略的 `.DS_Store`。

清理前检查无程序从项目 `.build` 运行，且目标下无 Git 跟踪文件。使用项目白名单清理脚本删除构建目录；空元数据目录按实际空目录删除。没有清空废纸篓或扫描/删除项目外的用户目录。

## 保留与验证

- 源码、Xcode 工程、依赖锁、Vendor 源码、全部 Git 历史、Design 图标草稿、验收报告、正式与历史 ZIP 均保留。
- 163 份构建/验收日志与 RC3 / UI 外观截图压缩留存：`dist/Verification/LacEditor-0.15.0-verification.zip`，约 13 MiB；归档完整性通过。SHA-256：`a30acff4195bdf3990dce85fdf7919b16db5bceeca71f5f4e0e5ee6e6fa32046`。
- 正式安装包清理后再次通过 ZIP 完整性与 `.sha256` 校验；`.build` 已不存在。
- 清理后项目共 291,200 KiB，约 284 MiB，其中 `dist` 约 72 MiB、Vendor 约 79 MiB、Git 历史约 132 MiB。目录占用与 APFS 实际释放量可能因共享块/快照不同，不视为精确磁盘释放值。
- 已安装 App 在发布/清理前后 Info.plist 与可执行文件 SHA-256 保持一致：分别为 `b671c302ad2cc0eaaf5357bc18f666fd63492eb30abc5fcb5dad01adb72d756e`、`de0e76bb6318c155efd8336afd1227f9f83d64be532735aab56f272e28c10516`。未主动退出、替换 App，未操作正式偏好、恢复快照或工作区。
- 原本两份历史报告删除和两份 0.13.x 未跟踪报告继续保留原状态，未误提交、回退或清理；安装包与本地证据 ZIP 不加入源码历史。

构建缓存及临时测试产物已直接删除，不能从废纸篓恢复，但均可重新生成；关键证据已另行保留。后续第一次构建会重新下载/解析 SwiftPM 依赖并重建缓存，耗时相应增加。
