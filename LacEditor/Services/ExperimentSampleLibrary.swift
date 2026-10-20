import Foundation

struct ExperimentSampleFile: Sendable {
    let group: String
    let name: String
    let text: String
}

/// Local, editable fixtures. Never copied from the formal workspace.
enum ExperimentSampleCatalog {
    static let welcomePath = "写作与排版/开始体验.md"

    static func files() -> [ExperimentSampleFile] {
        [
            .init(group: "写作与排版", name: "开始体验.md", text: """
            # 给想法留一点空间

            欢迎试用 LacEditor 的新界面。这是一份可以随意编辑的本地示例。
            修改后可以保存；以后升级实验版，不会覆盖你已经改过的内容。

            ## 先试这几件事

            1. 展开左侧「代码与数据」，打开 JSON 或 JavaScript。
            2. 用 ⌘T 新建标签，试试快速切换和关闭。
            3. 用 ⌥⌘P 开关右侧预览，再拖动中间分隔线。
            4. 在侧栏搜索框输入 js 或「写作」，筛选文件。

            JSON 格式化用 ⌥⌘L；查找替换用 ⌘F / ⌥⌘F。
            切换标签可以用 ⌃Tab，也可以用 ⌘1、⌘2 等数字快捷键。

            ## 写作与列表

            1. 记录今天的灵感
               1. 看见的小细节
               2. 想继续探索的问题
                  1. 把大问题拆小
                  2. 留下下一步
            2. 写一个不求完整的初稿
            3. 明天回来再读一遍

            - [x] 打开示例
            - [ ] 在列表末尾按回车，检查自动延续
            - [ ] 使用 Tab / Shift+Tab，检查列表层级

            > 保持工具轻巧，让注意力回到内容本身。

            ### 中英文与换行

            今天记录一些想法，Mixed text 123，标点也应自然对齐。
            这是紧接着的第二行，右侧预览也应保留换行。

            **重点**、*补充说明*、~~暂时搁置~~，以及 `inline code`。

            | 体验项目 | 操作 | 观察 |
            | --- | --- | --- |
            | 侧栏 | 展开 / 收起分组 | 标题稳定，内容裁切 |
            | 预览 | 开关 / 拖动比例 | 正文选区与撤销保留 |
            | 标签 | 快速切换 | 不闪白、不丢内容 |

            ```javascript
            const message = "你好，LacEditor";
            const steps = ["记录", "整理", "继续"];
            steps.forEach((step, index) => {
              console.log(`${index + 1}. ${step}`);
            });
            ```

            ---

            这些文件位于实验版的独立数据目录。可通过文件右键菜单「在 Finder 中显示」找到它们。
            """ + "\n"),
            .init(group: "写作与排版", name: "日常便签.txt", text: """
            今天的小事

            不急着完成全部，先把最重要的一件写下来。
            English words 1234567890，与中文一起输入，观察行高和光标。

            待办：
            • 整理想法
            • 留一点空白
            • 明天再继续

            查找替换练习：苹果 苹果 苹果
            URL 解码练习：https://example.com/search?q=%E4%BD%A0%E5%A5%BD%20LacEditor
            Base64 解码练习：SGVsbG8sIExhY0VkaXRvciE=

            下一行含真实 Tab，可调整设置里的 Tab 宽度观察：
            名称\t数量\t状态
            笔记\t12\t已整理

            """),
            .init(group: "代码与数据", name: "preferences.json", text: """
            {"name":"LacEditor 示例","version":1,"editor":{"fontSize":14,"tabWidth":4,"wordWrap":true},"languages":["Markdown","JavaScript","Python"],"enabled":true,"note":null,"items":[{"id":1,"title":"记录","done":true},{"id":2,"title":"整理","done":false}]}
            """ + "\n"),
            .init(group: "代码与数据", name: "sample.js", text: #"""
            // 行注释到这里结束；下面的代码不应继续呈现注释颜色。
            const title = "你好，LacEditor 😀";
            const items = ["写作", "代码", "日常记录"];
            const pattern = /https?:\/\/[^\s]+/g;

            /* 多行注释里含有伪括号 { [ ( ) ] } */
            function makeSummary(values) {
              const result = values.map((value, index) => ({
                id: index + 1,
                title: value,
                message: `第 ${index + 1} 项：${value}`,
              }));
              return { title, count: result.length, items: result };
            }

            console.log(makeSummary(items));
            // 试着把光标移到括号前后，检查首尾配对高亮。
            """# + "\n"),
            .init(group: "代码与数据", name: "sample.py", text: """
            \"\"\"一份本地 Python 高亮与缩进示例。\"\"\"
            from dataclasses import dataclass

            @dataclass
            class Note:
                title: str
                completed: bool = False

            def summarize(notes: list[Note]) -> dict:
                # 注释不应影响下一行的高亮。
                completed = [note for note in notes if note.completed]
                return {
                    "total": len(notes),
                    "completed": len(completed),
                    "message": "今天也有一点进展 😀",
                }

            notes = [Note("记录灵感", True), Note("整理初稿")]
            print(summarize(notes))
            """ + "\n"),
            .init(group: "代码与数据", name: "index.html", text: """
            <!doctype html>
            <html lang="zh-CN">
            <head>
              <meta charset="utf-8">
              <title>轻装编辑</title>
              <style>
                body { font: 16px/1.7 system-ui; margin: 48px; }
                h1 { color: #5c61ba; }
              </style>
            </head>
            <body>
              <!-- 这份示例用于检查 HTML 语法高亮 -->
              <h1>给想法留一点空间</h1>
              <p>本地编辑，随时开始。</p>
            </body>
            </html>
            """ + "\n"),
            .init(group: "滚动与布局", name: "多行文本.txt", text:
                (1...5_000).map { "第 \($0) 行 · 中英文 Mixed text 123，快速滚动、调整窗口，检查行号与正文是否始终对齐。" }.joined(separator: "\n") + "\n"),
            .init(group: "滚动与布局", name: "超长行.log", text:
                (1...80).map { index in
                    "[本地模拟] \(index) " + String(repeating: "长行内容 long-line 1234567890 | ", count: 120)
                }.joined(separator: "\n") + "\n")
        ]
    }
}

@MainActor
final class ExperimentSampleLibrary: ObservableObject {
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?
    let rootURL: URL
    private let defaults: UserDefaults
    private let installedKey = "uiExperiment.sampleLibrary.v1"

    init(rootURL: URL? = nil, defaults: UserDefaults = .standard) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.rootURL = rootURL ?? base
            .appendingPathComponent("LacEditor-UI-Experiment/ExampleFiles", isDirectory: true)
        self.defaults = defaults
    }

    var welcomeURL: URL { rootURL.appendingPathComponent(ExperimentSampleCatalog.welcomePath) }

    func prepare(in library: SidebarLibraryStore, supplement: Bool = false) async {
        guard !isPreparing, supplement || !defaults.bool(forKey: installedKey) else { return }
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }
        let root = rootURL
        do {
            let files = try await Task.detached(priority: .utility) {
                let files = ExperimentSampleCatalog.files()
                for file in files {
                    let url = root.appendingPathComponent(file.group).appendingPathComponent(file.name)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        // Never replace a sample the user has edited, even on retry.
                        try Data(file.text.utf8).write(to: url, options: .withoutOverwriting)
                    }
                }
                return files.map { ($0.group, $0.name) }
            }.value
            var groupIDs: [String: UUID] = [:]
            for (name, _) in files where groupIDs[name] == nil {
                groupIDs[name] = library.groups.first(where: { $0.name == name })?.id ?? library.createGroup(named: name)
            }
            for (group, name) in files {
                guard let id = groupIDs[group] else { continue }
                library.add(root.appendingPathComponent(group).appendingPathComponent(name), toGroup: id)
            }
            if !library.isFavorite(welcomeURL) { library.toggleFavorite(welcomeURL) }
            defaults.set(true, forKey: installedKey)
        } catch {
            errorMessage = "示例准备失败：\(error.localizedDescription)"
        }
    }
}
