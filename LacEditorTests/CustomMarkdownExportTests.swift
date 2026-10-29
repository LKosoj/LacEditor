import AppKit
import Foundation
import Darwin
import XCTest
@testable import LacEditor

final class CustomMarkdownExportTests: XCTestCase {
    func testPDFEngineReceivesExplicitLatexSpaces() throws {
        let pandoc = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let quoted = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let engine = directory.appendingPathComponent("pdflatex")
        let script = """
        #!/bin/sh
        for last do :; done
        /bin/cp "$last" \(quoted)/spaces.tex
        printf '%%PDF-1.4\\n%%fixture\\n' > "$(/usr/bin/dirname "$last")/input.pdf"
        """
        try script.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        var profile = MarkdownExportProfile.pdfEngineProfile()
        profile.pdfEngine = engine.path
        for preserve in [false, true] {
            let result = try CustomMarkdownExportService.preparePDFEngine(text: "中文   text and $x$", source: nil,
                destination: directory.appendingPathComponent("out.pdf"), profile: profile, executable: pandoc,
                syntax: .init(preserveExportWhitespace: preserve))
            if let file = result.preparedURL { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let latex = try String(contentsOf: directory.appendingPathComponent("spaces.tex"), encoding: .utf8)
            XCTAssertEqual(latex.contains("\\ \\ \\ "), preserve)
            XCTAssertTrue(latex.contains("x"))
        }
    }

    func testHTMLPDFEngineKeepsWhitespaceSpan() throws {
        let pandoc = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let quoted = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let engine = directory.appendingPathComponent("wkhtmltopdf")
        let script = """
        #!/bin/sh
        last=''; previous=''
        for arg do previous="$last"; last="$arg"; done
        /bin/cp "$previous" \(quoted)/spaces.html
        printf '%%PDF-1.4\\n%%fixture\\n' > "$last"
        """
        try script.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        var profile = MarkdownExportProfile.pdfEngineProfile()
        profile.pdfEngine = engine.path
        profile.writer = "html"
        for preserve in [false, true] {
            let result = try CustomMarkdownExportService.preparePDFEngine(text: "a   b", source: nil,
                destination: directory.appendingPathComponent("out.pdf"), profile: profile, executable: pandoc,
                syntax: .init(preserveExportWhitespace: preserve))
            if let file = result.preparedURL { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let html = try String(contentsOf: directory.appendingPathComponent("spaces.html"), encoding: .utf8)
            XCTAssertEqual(html.contains("white-space: break-spaces"), preserve)
        }
        let loose = try CustomMarkdownExportService.preparePDFEngine(text: "###Header", source: nil,
            destination: directory.appendingPathComponent("loose.pdf"), profile: profile, executable: pandoc,
            syntax: .init(strictMode: false))
        if let file = loose.preparedURL { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let looseHTML = try String(contentsOf: directory.appendingPathComponent("spaces.html"), encoding: .utf8)
        XCTAssertTrue(looseHTML.contains(">Header</h3>"))
    }

    func testPDFEngineReceivesExtractedDiagramWithMathAndRootImage() throws {
        let pandoc = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        try png.write(to: directory.appendingPathComponent("root.png"))
        let quoted = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let engine = directory.appendingPathComponent("pdflatex")
        let script = """
        #!/bin/sh
        for last do :; done
        /bin/cp "$last" \(quoted)/engine.tex
        count=0
        /usr/bin/grep -o '/[^{}]*[.]png' "$last" | while IFS= read -r image; do
          count=$((count + 1))
          /bin/cp "$image" \(quoted)/asset"$count".png || exit 1
        done
        printf '%%PDF-1.4\\n%%fixture\\n' > "$(/usr/bin/dirname "$last")/input.pdf"
        """
        try script.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        var profile = MarkdownExportProfile.pdfEngineProfile()
        profile.pdfEngine = engine.path
        let text = "---\ntypora-root-url: .\n---\n\nBefore $x$ ![root](/root.png)\n\n![diagram](data:image/png;base64,\(png.base64EncodedString()))\n\nAfter"
        let destination = directory.appendingPathComponent("result.pdf")
        let result = try CustomMarkdownExportService.preparePDFEngine(text: text, source: directory.appendingPathComponent("note.md"),
            destination: destination, profile: profile, executable: pandoc, extractEmbeddedMedia: true)
        let output = try XCTUnwrap(result.preparedURL)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let tex = try String(contentsOf: directory.appendingPathComponent("engine.tex"), encoding: .utf8)
        XCTAssertTrue(tex.contains("Before"))
        XCTAssertTrue(tex.contains("After"))
        XCTAssertTrue(tex.contains("x"))
        XCTAssertGreaterThanOrEqual(tex.components(separatedBy: "includegraphics").count - 1, 2)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("asset1.png")), png)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("asset2.png")), png)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPDFEngineUsesSnapshotAndProtectedTemporaryOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.pdf")
        try Data("old".utf8).write(to: destination)
        let record = directory.appendingPathComponent("args")
        let executable = directory.appendingPathComponent("pandoc-fixture")
        let quotedRecord = "'" + record.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let defaultsRecord = directory.appendingPathComponent("defaults-record")
        let quotedDefaults = "'" + defaultsRecord.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(quotedRecord)
        out=''
        input=''
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --defaults) shift; /bin/cat "$1" > \(quotedDefaults) ;;
            --output) shift; out="$1" ;;
            --) shift; input="$1" ;;
          esac
          shift
        done
        /bin/cat "$input" > "$out"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var profile = MarkdownExportProfile.pdfEngineProfile()
        profile.pdfEngine = "/bin/sh"
        profile.arguments = "--toc --metadata=author:Alice --pdf-engine-opt=--example"
        let result = try CustomMarkdownExportService.preparePDFEngine(text: "Snapshot 中文 😀", source: nil,
            destination: destination, profile: profile, executable: executable)
        let prepared = try XCTUnwrap(result.preparedURL)
        defer { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        XCTAssertEqual(try String(contentsOf: prepared, encoding: .utf8), "Snapshot 中文 😀")
        let args = try String(contentsOf: record, encoding: .utf8)
        XCTAssertTrue(args.contains("--from=gfm+yaml_metadata_block+smart"))
        let noSmart = try CustomMarkdownExportService.preparePDFEngine(text: "Snapshot", source: nil,
            destination: destination, profile: profile, executable: executable, syntax: .init(smartPunctuation: false))
        defer { if let file = noSmart.preparedURL { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
        let noSmartArgs = try String(contentsOf: record, encoding: .utf8)
        XCTAssertFalse(noSmartArgs.contains("+smart"))
        XCTAssertTrue(args.contains("--to=latex"))
        XCTAssertTrue(args.contains("--pdf-engine=/bin/sh"))
        XCTAssertTrue(args.contains("--metadata=author:Alice"))
        XCTAssertTrue(args.contains("--pdf-engine-opt=--example"))
        XCTAssertFalse(args.contains(destination.path))
        let withDiagram = try CustomMarkdownExportService.preparePDFEngine(text: "![diagram](data:image/png;base64,AQ==)", source: nil,
            destination: destination, profile: profile, executable: executable, extractEmbeddedMedia: true)
        defer { if let file = withDiagram.preparedURL { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
        let diagramArgs = try String(contentsOf: record, encoding: .utf8)
        let extract = try XCTUnwrap(diagramArgs.split(separator: "\n").first { $0.hasPrefix("--extract-media=") })
        let extractedPath = String(extract.dropFirst("--extract-media=".count))
        XCTAssertTrue(URL(fileURLWithPath: extractedPath).isFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extractedPath))
        let posts = directory.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(at: posts, withIntermediateDirectories: true)
        let rooted = "---\ntypora-root-url: ../site\n---\n\n![x][id] [link][id]\n\n[id]: /a%23b.png"
        let rootedResult = try CustomMarkdownExportService.preparePDFEngine(text: rooted, source: posts.appendingPathComponent("note.md"),
            destination: destination, profile: profile, executable: executable)
        let rootedFile = try XCTUnwrap(rootedResult.preparedURL)
        defer { try? FileManager.default.removeItem(at: rootedFile.deletingLastPathComponent()) }
        let passed = try String(contentsOf: rootedFile, encoding: .utf8)
        XCTAssertFalse(passed.contains("file://"))
        XCTAssertTrue(passed.contains("site/a%23b.png"))
        XCTAssertTrue(passed.contains("[link][id]"))
        XCTAssertTrue(passed.contains("[id]: /a%23b.png"))
        XCTAssertTrue(rooted.contains("![x][id]"))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        for writer in ["context", "html", "ms", "typst"] {
            profile.writer = writer
            let value = try CustomMarkdownExportService.preparePDFEngine(text: "snapshot", source: nil,
                destination: destination, profile: profile, executable: executable)
            defer { if let file = value.preparedURL { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
            XCTAssertTrue(try String(contentsOf: record, encoding: .utf8).contains("--to=\(writer)"))
        }
        profile.writer = "latex"
        let config = directory.appendingPathComponent("defaults.yaml")
        let yaml = "resource-path: ['${.}/assets']\n"
        try yaml.write(to: config, atomically: true, encoding: .utf8)
        profile.arguments = "--defaults '" + config.path + "'"
        let withDefaults = try CustomMarkdownExportService.preparePDFEngine(text: "snapshot", source: nil,
            destination: destination, profile: profile, executable: executable)
        defer { if let file = withDefaults.preparedURL { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
        XCTAssertTrue(try String(contentsOf: defaultsRecord, encoding: .utf8).contains("LACEDITOR_DEFAULTS_"))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), yaml)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        profile.writer = "custom.lua"
        XCTAssertThrowsError(try CustomMarkdownExportService.preparePDFEngine(text: "x", source: nil,
            destination: destination, profile: profile, executable: executable))
        profile.writer = "latex"
        profile.arguments = "--metadata=path:${currentPath}"
        XCTAssertThrowsError(try CustomMarkdownExportService.preparePDFEngine(text: "---\ncurrentPath: fake\n---\n\nx", source: nil,
            destination: destination, profile: profile, executable: executable))
        profile.arguments = "--output=outside"
        XCTAssertThrowsError(try CustomMarkdownExportService.preparePDFEngine(text: "x", source: nil,
            destination: destination, profile: profile, executable: executable))
    }

    func testPDFEngineCancellationStopsNestedProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        let later = directory.appendingPathComponent("later")
        func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let fixture = directory.appendingPathComponent("pandoc-fixture")
        let nested = "printf started > \(quote(started.path)); /bin/sleep 2; printf later > \(quote(later.path))"
        try ("#!/bin/sh\n/bin/sh -c \(quote(nested))\n").write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let destination = directory.appendingPathComponent("result.pdf")
        try Data("old".utf8).write(to: destination)
        var profile = MarkdownExportProfile.pdfEngineProfile()
        profile.pdfEngine = "/bin/sh"
        let configured = profile
        let task = Task.detached {
            try CustomMarkdownExportService.preparePDFEngine(text: "snapshot", source: nil, destination: destination,
                profile: configured, executable: fixture, isCancelled: { Task.isCancelled })
        }
        defer { task.cancel() }
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: started.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: later.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testSubstitutionPreservesShellVariablesAndQuotes() throws {
        let value = "中文 ' \" $() `echo bad`\nnext"
        let command = "printf '%s\\n' ${inputPath} \"${inputPath}\" '${inputPath}' ${HOME} ${PATH}"
        let parsed = try CustomMarkdownExportService.substitute(command, variables: ["inputPath": value], required: ["inputPath"])
        XCTAssertTrue(parsed.script.contains("${HOME}"))
        XCTAssertTrue(parsed.script.contains("${PATH}"))
        XCTAssertFalse(parsed.script.contains(value))
        XCTAssertEqual(parsed.environment.count, 3)
        XCTAssertTrue(parsed.environment.values.allSatisfy { $0 == value })
        let escaped = try CustomMarkdownExportService.substitute(#"echo \${inputPath}"#, variables: ["inputPath": value], required: ["inputPath"])
        XCTAssertTrue(escaped.environment.isEmpty)
        XCTAssertEqual(escaped.script, #"echo \${inputPath}"#)
        XCTAssertThrowsError(try CustomMarkdownExportService.substitute("echo ${outputPath}", variables: [:], required: ["outputPath"]))
        XCTAssertThrowsError(try CustomMarkdownExportService.substitute("echo ${a.b}", variables: [:], required: []))
        XCTAssertThrowsError(try CustomMarkdownExportService.substitute("echo $(date) ${inputPath}", variables: ["inputPath": value], required: ["inputPath"]))
        XCTAssertThrowsError(try CustomMarkdownExportService.substitute("echo ${VAR:-${inputPath}}", variables: ["inputPath": value], required: ["inputPath"]))
        let literal = try CustomMarkdownExportService.substitute("printf '%s' '# ` <<' ${inputPath}", variables: ["inputPath": value], required: ["inputPath"])
        XCTAssertTrue(literal.script.contains("'# ` <<'"))
        let quotedHash = try CustomMarkdownExportService.substitute("printf '%s' \"# <<\" ${inputPath}", variables: ["inputPath": value], required: ["inputPath"])
        XCTAssertTrue(quotedHash.script.contains("\"# <<\""))
        let shellOnly = try CustomMarkdownExportService.substitute("echo ${HOME} && echo ${CUSTOM}", variables: [:], required: [])
        XCTAssertEqual(shellOnly.script, "echo ${HOME} && echo ${CUSTOM}")
    }

    func testZshGetsExactValuesWithoutExecutingTheirContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("must-not-exist")
        let value = "Unicode 😀 ' \" $(touch \(marker.path)) `touch \(marker.path)`\nline"
        let command = "printf '%s\\n' ${inputPath} \"${inputPath}\" '${inputPath}'"
        let parsed = try CustomMarkdownExportService.substitute(command, variables: ["inputPath": value], required: ["inputPath"])
        let output = directory.appendingPathComponent("out")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", parsed.script]
        process.environment = ProcessInfo.processInfo.environment.merging(parsed.environment) { _, new in new }
        process.standardOutput = handle
        try process.run()
        process.waitUntilExit()
        try handle.synchronize()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), String(repeating: value + "\n", count: 3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFileFolderAndNoOutputUseSnapshotAndPreserveDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result file.txt")
        try Data("old".utf8).write(to: destination)
        let file = try CustomMarkdownExportService.prepare(text: "новый 😀\n", source: nil, destination: .file(destination),
                                                           command: "/bin/cat \"${inputPath}\" > \"${outputPath}\"")
        let prepared = try XCTUnwrap(file.preparedURL)
        defer { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: prepared), Data("новый 😀\n".utf8))
        let folder = try CustomMarkdownExportService.prepare(text: "x", source: nil, destination: .folder(directory),
                                                             command: "printf '%s' folder > \"${outputPath}/item.txt\"")
        XCTAssertNil(folder.preparedURL)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("item.txt"), encoding: .utf8), "folder")
        let noOutput = try CustomMarkdownExportService.prepare(text: "x", source: nil, destination: .none, command: "printf '%s' complete")
        XCTAssertNil(noOutput.preparedURL)
        XCTAssertEqual(noOutput.stdout, "complete")
        XCTAssertThrowsError(try CustomMarkdownExportService.prepare(text: "x", source: nil, destination: .file(destination), command: "printf '%s' no-file"))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testCommandFailureRetainsDiagnosticsAndNoResult() throws {
        XCTAssertThrowsError(try CustomMarkdownExportService.prepare(text: "x", source: nil, destination: .none,
                                                                      command: "printf '%s' failed >&2; exit 7")) {
            XCTAssertTrue($0.localizedDescription.contains("failed"))
        }
    }

    func testYAMLVariableExpansionUsesDocumentSnapshot() throws {
        let text = "---\ntitle: '中文 *_title_*'\nbook:\n  name: 'quoted *_value_*'\n---\n\nbody"
        let result = try CustomMarkdownExportService.prepare(text: text, source: nil, destination: .none,
                                                             command: "printf '%s|%s' \"${title}\" '${book.name}'")
        XCTAssertEqual(result.stdout, "中文 *_title_*|quoted *_value_*")
    }

    func testInvalidYAMLDoesNotBlockHomePathOrInputPath() throws {
        let text = "---\ntitle: [invalid\n---\n\nbody"
        let result = try CustomMarkdownExportService.prepare(text: text, source: nil, destination: .none,
                                                             command: "printf '%s|%s|%s' \"${HOME}\" \"${PATH}\" \"${inputPath}\"")
        let parts = result.stdout.components(separatedBy: "|")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], ProcessInfo.processInfo.environment["HOME"] ?? "")
        XCTAssertEqual(parts[1], ProcessInfo.processInfo.environment["PATH"] ?? "")
        XCTAssertTrue(parts[2].hasSuffix("/input.md"))
    }

    func testUnsavedDocumentDoesNotUseYAMLForCurrentPath() throws {
        let text = "---\ncurrentPath: fake\ntitle: actual\n---\n\nbody"
        XCTAssertThrowsError(try CustomMarkdownExportService.prepare(text: text, source: nil, destination: .none,
            command: "printf '%s %s' '${title}' '${currentPath}'"))
    }

    func testCancellationStopsChildAndCleansBothTemporaryDirectories() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let quoted = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "pwd > \(quoted); printf '%s\\n' \"${outputPath}\" >> \(quoted); echo $$ >> \(quoted); exec /bin/sleep 30"
        let destination = directory.appendingPathComponent("result.txt")
        try Data("old".utf8).write(to: destination)
        let task = Task.detached {
            try CustomMarkdownExportService.prepare(text: "snapshot", source: nil, destination: .file(destination), command: command,
                                                    isCancelled: { Task.isCancelled })
        }
        defer { task.cancel() }
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(5)
        while lines.count < 3 && Date() < deadline {
            lines = (try? String(contentsOf: marker, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            if lines.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(lines.count, 3)
        guard lines.count == 3 else { return }
        let pid = try XCTUnwrap(Int32(lines[2]))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lines[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: lines[1]).deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }
    @MainActor
    func testCommandProfileIntegratesWithRepeatAndLatestSnapshot() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "CustomMarkdownExportTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "first", language: .markdown)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        var profile = MarkdownExportProfile.customCommand()
        profile.command = "/bin/cat \"${inputPath}\" > \"${outputPath}\""
        let destination = directory.appendingPathComponent("out.txt")
        state.exportMarkdown(profile: profile, destination: destination, expectedRevision: nil)
        for _ in 0..<100 {
            if state.hasPreviousMarkdownExport { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "first")
        XCTAssertTrue(state.hasPreviousMarkdownExport)
        document.text = "second"
        state.repeatMarkdownExport(overwrite: true)
        for _ in 0..<100 {
            if (try? String(contentsOf: destination, encoding: .utf8)) == "second" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "second")
    }

    @MainActor
    func testEditedDocumentDoesNotInstallLateCommandOutput() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "CustomMarkdownExportTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "snapshot", language: .markdown)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        var profile = MarkdownExportProfile.customCommand()
        profile.command = "/bin/sleep 1; /bin/cat \"${inputPath}\" > \"${outputPath}\""
        let destination = directory.appendingPathComponent("out.txt")
        try Data("old".utf8).write(to: destination)
        state.exportMarkdown(profile: profile, destination: destination, expectedRevision: nil)
        document.text = "edited"
        for _ in 0..<100 {
            if document.statusMessage == L10n.tr("文档已更改；命令可能已经执行。") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(document.statusMessage, L10n.tr("文档已更改；命令可能已经执行。"))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        XCTAssertFalse(state.hasPreviousMarkdownExport)
    }

    @MainActor
    func testPDFEngineProfilePersistsAlongsideDefaults() throws {
        let suite = "PDFEngineProfileTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        var profile = MarkdownExportProfile.pdfEngineProfile()
        profile.pdfEngine = "/Applications/TeX/bin/xelatex"
        profile.templatePath = "/tmp/example.tex"
        preferences.markdownExportConfiguration.profiles.append(profile)
        let restored = AppPreferences(defaults: defaults).markdownExportConfiguration.profiles
        XCTAssertEqual(restored.last, profile)
        XCTAssertEqual(Array(restored.dropLast()), MarkdownExportProfile.defaults)
    }

    @MainActor
    func testCommandProfilePersistsAlongsideExistingProfiles() throws {
        let suite = "CustomMarkdownExportTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        var profile = MarkdownExportProfile.customCommand()
        profile.command = "printf '%s' \"${HOME}\""
        profile.commandDestination = "folder"
        profile.showCommandOutput = true
        preferences.markdownExportConfiguration.profiles.append(profile)
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.markdownExportConfiguration.profiles.last, profile)
        XCTAssertEqual(Array(restored.markdownExportConfiguration.profiles.dropLast()), MarkdownExportProfile.defaults)
    }

    @MainActor
    func testClosingDocumentCancelsItsRunningCommand() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "CustomMarkdownExportTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "snapshot", language: .markdown)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        let marker = directory.appendingPathComponent("started")
        let quoted = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var profile = MarkdownExportProfile.customCommand()
        profile.command = "echo $$ > \(quoted); exec /bin/sleep 30"
        let destination = directory.appendingPathComponent("out.txt")
        state.exportMarkdown(profile: profile, destination: destination, expectedRevision: nil)
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pidText = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        document.markSaved()
        state.close(document)
        for _ in 0..<100 where state.documents.contains(where: { $0 === document }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(state.documents.contains { $0 === document })
        for _ in 0..<250 {
            if kill(pid, 0) == -1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testReleasedDocumentDoesNotLeaveItsExportLocked() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "CustomMarkdownExportTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var document: EditorDocument? = EditorDocument(text: "first", language: .markdown)
        let id = try XCTUnwrap(document?.id)
        weak var releasedDocument = document
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        let marker = directory.appendingPathComponent("started")
        let quoted = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var profile = MarkdownExportProfile.customCommand()
        profile.command = "echo $$ > \(quoted); exec /bin/sleep 30"
        let destination = directory.appendingPathComponent("out.txt")
        state.exportMarkdown(profile: profile, destination: destination, expectedRevision: nil)
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try XCTUnwrap(document).markSaved()
        state.close(try XCTUnwrap(document))
        for _ in 0..<100 where state.documents.contains(where: { $0.id == id }) { try await Task.sleep(for: .milliseconds(20)) }
        document = nil
        XCTAssertNil(releasedDocument)
        // Reusing the ID makes the retained export lock observable through the real command path.
        let replacement = EditorDocument(id: id, text: "second", language: .markdown)
        state.documents = [replacement]
        state.selectedDocumentID = replacement.id
        profile.command = "/bin/cat \"${inputPath}\" > \"${outputPath}\""
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: destination.path) { break }
            state.exportMarkdown(profile: profile, destination: destination, expectedRevision: nil)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "second")
    }

    func testCancellationStopsNestedShellBeforeSideEffect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        let done = directory.appendingPathComponent("unexpected")
        func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let child = "echo ready > \(quote(started.path)); /bin/sleep 2; printf done > \(quote(done.path))"
        let command = "/bin/sh -c \(quote(child)); printf finished"
        let destination = directory.appendingPathComponent("result.txt")
        try Data("old".utf8).write(to: destination)
        let task = Task.detached {
            try CustomMarkdownExportService.prepare(text: "snapshot", source: nil, destination: .file(destination),
                                                    command: command, isCancelled: { Task.isCancelled })
        }
        defer { task.cancel() }
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: started.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: done.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

}
