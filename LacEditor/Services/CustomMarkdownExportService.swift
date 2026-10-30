import Foundation
import Darwin

enum CustomMarkdownExportService {
    enum CommandError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case let .failed(details): L10n.tr("命令执行失败：%@", details) }
        }
    }
    enum Destination: Sendable { case file(URL), folder(URL), none }
    struct Result {
        let preparedURL: URL?
        let stdout: String
        let stderr: String
    }
    struct Substitution {
        let script: String
        let environment: [String: String]
    }

    static func run(_ process: Process, isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
        try process.run()
        while process.isRunning {
            if isCancelled() {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        if isCancelled() { throw CancellationError() }
    }

    private static func runShell(script: String, environment: [String: String], directory: URL,
                                 stdout: FileHandle, stderr: FileHandle, isCancelled: () -> Bool) throws -> Int32 {
        func check(_ code: Int32) throws {
            if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        if isCancelled() { throw CancellationError() }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout.fileDescriptor, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr.fileDescriptor, STDERR_FILENO))
        try directory.path.withCString { try check(posix_spawn_file_actions_addchdir(&actions, $0)) }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var arguments = [strdup("/bin/zsh"), strdup("-c"), strdup(script)]
        var env = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            arguments.forEach { free($0) }
            env.forEach { free($0) }
        }
        guard arguments.allSatisfy({ $0 != nil }), env.allSatisfy({ $0 != nil }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        arguments.append(nil)
        env.append(nil)
        var pid: pid_t = 0
        if isCancelled() { throw CancellationError() }
        let status = arguments.withUnsafeMutableBufferPointer { argv in
            env.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        try check(status)
        var exitStatus: Int32 = 0
        while true {
            if isCancelled() {
                _ = kill(-pid, SIGKILL)
                while waitpid(pid, &exitStatus, 0) < 0 && errno == EINTR {}
                throw CancellationError()
            }
            let result = waitpid(pid, &exitStatus, WNOHANG)
            if result == pid { break }
            if result < 0 && errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isCancelled() { throw CancellationError() }
        guard exitStatus & 0x7f == 0 else { return 128 + (exitStatus & 0x7f) }
        return (exitStatus >> 8) & 0xff
    }

    // Values are passed through the environment, never inserted as shell syntax.
    static func substitute(_ command: String, variables: [String: String], required: Set<String>) throws -> Substitution {
        let reserved = Set(["HOME", "PATH"])
        let characters = Array(command)
        var output = "", environment: [String: String] = [:]
        var quote: Character?, index = 0, count = 0, usesAppVariable = false, complexContext = false
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        while index < characters.count {
            let c = characters[index]
            if c == "\\" && quote != "'" {
                guard index + 1 < characters.count else { throw PandocExportError.invalidConfiguration(L10n.tr("引号或转义未结束")) }
                output.append(c); output.append(characters[index + 1]); index += 2; continue
            }
            if c == "'" && quote != "\"" { quote = quote == "'" ? nil : "'"; output.append(c); index += 1; continue }
            if c == "\"" && quote != "'" { quote = quote == "\"" ? nil : "\""; output.append(c); index += 1; continue }
            if quote != "'" {
                if c == "`" || (c == "$" && index + 1 < characters.count && characters[index + 1] == "(") { complexContext = true }
                if quote == nil && (c == "#" || (c == "<" && index + 1 < characters.count && characters[index + 1] == "<") ||
                    (c == "$" && index + 1 < characters.count && characters[index + 1] == "'")) { complexContext = true }
            }
            if c == "$", index + 1 < characters.count, characters[index + 1] == "{" {
                guard let end = characters[(index + 2)...].firstIndex(of: "}") else {
                    throw PandocExportError.invalidConfiguration(L10n.tr("变量未结束"))
                }
                let name = String(characters[(index + 2)..<end])
                if name.contains("${"), Set(variables.keys).union(required).contains(where: { name.contains("${" + $0) }) {
                    throw PandocExportError.invalidConfiguration(L10n.tr("命令中的变量位置暂不支持"))
                }
                if !reserved.contains(name), let value = variables[name] {
                    guard !value.contains("\0") else { throw PandocExportError.invalidConfiguration(L10n.tr("变量包含无效字符")) }
                    usesAppVariable = true
                    let key = "LAC_EXPORT_\(nonce)_\(count)"
                    count += 1
                    environment[key] = value
                    let reference = "${\(key)}"
                    if quote == "'" { output += "'\"\(reference)\"'" }
                    else if quote == "\"" { output += reference }
                    else { output += "\"\(reference)\"" }
                } else if required.contains(name) || (name.contains(".") && name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                    !$0.isEmpty && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0) }
                }) {
                    throw PandocExportError.invalidConfiguration(L10n.tr("未知变量：%@", name))
                } else {
                    output += String(characters[index...end])
                }
                index = end + 1; continue
            }
            output.append(c)
            index += 1
        }
        guard quote == nil else { throw PandocExportError.invalidConfiguration(L10n.tr("引号或转义未结束")) }
        if usesAppVariable && complexContext {
            throw PandocExportError.invalidConfiguration(L10n.tr("命令中的变量位置暂不支持"))
        }
        return Substitution(script: output, environment: environment)
    }

    static func runPandocGroup(_ pandoc: URL, arguments: [String], directory: URL,
                               stderr: FileHandle, isCancelled: () -> Bool,
                               additionalEnvironment: [String: String] = [:]) throws -> Int32 {
        func check(_ status: Int32) throws { if status != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) } }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr.fileDescriptor, STDERR_FILENO))
        try directory.path.withCString { try check(posix_spawn_file_actions_addchdir(&actions, $0)) }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var argv = arguments.map { strdup($0) }
        var environment = ProcessInfo.processInfo.environment.merging(additionalEnvironment) { _, new in new }.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else { throw CocoaError(.fileWriteUnknown) }
        argv.append(nil); environment.append(nil)
        if isCancelled() { throw CancellationError() }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer { args in
            environment.withUnsafeMutableBufferPointer { env in
                posix_spawn(&pid, pandoc.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        try check(spawned)
        var status: Int32 = 0
        while true {
            if isCancelled() {
                _ = kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                throw CancellationError()
            }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0 && errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return status
    }

    // Explicit PDF-engine profile: Pandoc and its engine share one process group.
    static func preparePDFEngine(text: String, source: URL?, destination: URL, profile: MarkdownExportProfile,
                                 executable: URL? = nil, isCancelled: @escaping () -> Bool = { false },
                                 syntax: MarkdownSyntaxOptions = .init(), extractEmbeddedMedia: Bool = false,
                                 wiki: MarkdownWikiLinkSource? = nil) throws -> Result {
        guard !isCancelled() else { throw CancellationError() }
        guard destination.pathExtension.lowercased() == "pdf",
              let engine = profile.pdfEngine, engine.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: engine) else {
            throw PandocExportError.invalidConfiguration(L10n.tr("请选择可执行的 PDF 引擎和 PDF 文件"))
        }
        guard let pandoc = executable ?? PandocExportService.findPandoc() else { throw PandocExportError.missingPandoc }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: work) }
        let outputDirectory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: destination.deletingLastPathComponent(), create: true)
        var retained = false
        defer { if !retained { try? manager.removeItem(at: outputDirectory) } }
        let input = work.appendingPathComponent("input.md")
        let output = outputDirectory.appendingPathComponent("output.pdf")
        let snapshot = text.contains("$") || syntax.preserveExportWhitespace || !syntax.strictMode || (wiki != nil && text.contains("[["))
            ? try PandocExportService.markedExportSnapshot(text, syntax: syntax, includeTOC: false, wiki: wiki, isCancelled: isCancelled) : nil
        let imageRooted = try PandocExportService.rootImageSnapshot(snapshot?.text ?? text, document: source, isCancelled: isCancelled)
        let preparedText = try PandocExportService.rootMediaSnapshot(imageRooted, document: source, isCancelled: isCancelled)
        try Data(preparedText.utf8).write(to: input, options: .withoutOverwriting)
        var variables: [String: String] = ["outputPath": output.path,
            "outputFileName": destination.deletingPathExtension().lastPathComponent,
            "outputFileFullName": destination.lastPathComponent]
        if let source {
            variables["currentPath"] = source.path
            variables["currentFolder"] = source.deletingLastPathComponent().path
            variables["currentFileName"] = source.deletingPathExtension().lastPathComponent
            variables["currentFileFullName"] = source.lastPathComponent
        }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        variables["today"] = date.string(from: Date())
        if profile.arguments.contains("${"), MarkdownPresentationParser.frontMatter(text) != nil {
            for (name, value) in try PandocExportService.yamlScalarVariables(text, isCancelled: isCancelled)
                where variables[name] == nil && !["currentPath", "currentFolder", "currentFileName", "currentFileFullName"].contains(name) {
                variables[name] = value
            }
        }
        guard ["latex", "context", "html", "ms", "typst"].contains(profile.writer) else {
            throw PandocExportError.invalidConfiguration(L10n.tr("不支持此 PDF 中间格式"))
        }
        let parsed = try PandocExportService.checkedArguments(profile.arguments, variables: variables, pdfEngine: true)
        let defaults = try PandocExportService.prepareDefaults(arguments: parsed, source: source, temporary: work, profile: profile, isCancelled: isCancelled)
        let extra = defaults.arguments
        if profile.templatePath != nil && extra.contains(where: { $0 == "--template" || $0.hasPrefix("--template=") }) {
            throw PandocExportError.invalidConfiguration(L10n.tr("参数与输出格式不匹配"))
        }
        let ast = work.appendingPathComponent("document.json")
        let log = work.appendingPathComponent("stderr")
        guard manager.createFile(atPath: log.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let stderr = try FileHandle(forWritingTo: log)
        defer { try? stderr.close() }
        var readerFormat = "--from=gfm+yaml_metadata_block" + ((syntax.smartPunctuation ?? true) ? "+smart" : "") + (syntax.preserveExportSoftBreaks == true ? "+hard_line_breaks" : "")
        var writerInput = input
        if let snapshot {
            let readerArguments = [pandoc.path, "--from=gfm+yaml_metadata_block-tex_math_dollars" + ((syntax.smartPunctuation ?? true) ? "+smart" : "-smart") + (syntax.preserveExportSoftBreaks == true ? "+hard_line_breaks" : "-hard_line_breaks"), "--to=json", "--output", ast.path, "--", input.path]
            let readerStatus = try runPandocGroup(pandoc, arguments: readerArguments, directory: source?.deletingLastPathComponent() ?? work,
                                                  stderr: stderr, isCancelled: isCancelled, additionalEnvironment: defaults.environment)
            if isCancelled() { throw CancellationError() }
            guard readerStatus == 0, var tree = try JSONSerialization.jsonObject(with: Data(contentsOf: ast)) as? [String: Any] else {
                throw PandocExportError.conversionFailed("Pandoc (\(readerStatus))")
            }
            if let metadata = try PandocExportService.originalMathMetadata(text, executable: pandoc, source: source, temporary: work,
                                                                           environment: defaults.environment, isCancelled: isCancelled) {
                tree["meta"] = metadata
            }
            let restored = try PandocExportService.restoreMath(in: tree, markers: snapshot.math, latexWhitespace: profile.writer == "latex", isCancelled: isCancelled)
            try JSONSerialization.data(withJSONObject: restored).write(to: ast, options: .atomic)
            readerFormat = "--from=json"
            writerInput = ast
        }
        var arguments = [pandoc.path, readerFormat, "--to=\(profile.writer)", "--pdf-engine=\(engine)", "--standalone"]
        if extractEmbeddedMedia { arguments.append("--extract-media=\(work.appendingPathComponent("media", isDirectory: true).path)") }
        if let template = profile.templatePath, !template.isEmpty { arguments.append("--template=\(template)") }
        arguments += extra + ["--output", output.path, "--", writerInput.path]
        let status = try runPandocGroup(pandoc, arguments: arguments, directory: source?.deletingLastPathComponent() ?? work,
                                        stderr: stderr, isCancelled: isCancelled, additionalEnvironment: defaults.environment)
        try stderr.synchronize()
        let diagnostics = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        if isCancelled() { throw CancellationError() }
        guard status == 0 else { throw PandocExportError.conversionFailed(diagnostics.isEmpty ? "Pandoc (\(status))" : diagnostics) }
        guard let attrs = try? manager.attributesOfItem(atPath: output.path), attrs[.type] as? FileAttributeType == .typeRegular else {
            throw PandocExportError.invalidConfiguration(L10n.tr("命令未生成输出文件"))
        }
        retained = true
        return Result(preparedURL: output, stdout: "", stderr: diagnostics)
    }

    // Runs off the main thread. The returned prepared file belongs to the caller.
    static func prepare(text: String, source: URL?, destination: Destination, command: String,
                        isCancelled: @escaping () -> Bool = { false }) throws -> Result {
        if isCancelled() { throw CancellationError() }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PandocExportError.invalidConfiguration(L10n.tr("命令不能为空"))
        }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: work) }
        let input = work.appendingPathComponent("input.md")
        try Data(text.utf8).write(to: input, options: .withoutOverwriting)
        var replacement: URL?
        var retained = false
        defer { if !retained, let replacement { try? manager.removeItem(at: replacement) } }
        var variables: [String: String] = ["inputPath": input.path]
        switch destination {
        case let .file(url):
            let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                            appropriateFor: url.deletingLastPathComponent(), create: true)
            replacement = directory
            let output = directory.appendingPathComponent("output").appendingPathExtension(url.pathExtension)
            variables["outputPath"] = output.path
            variables["outputFileName"] = url.deletingPathExtension().lastPathComponent
            variables["outputFileFullName"] = url.lastPathComponent
        case let .folder(url):
            variables["outputPath"] = url.path
            variables["outputFileName"] = url.lastPathComponent
            variables["outputFileFullName"] = url.lastPathComponent
        case .none: break
        }
        if let source {
            variables["currentPath"] = source.path
            variables["currentFolder"] = source.deletingLastPathComponent().path
            variables["currentFileName"] = source.deletingPathExtension().lastPathComponent
            variables["currentFileFullName"] = source.lastPathComponent
        }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        variables["today"] = date.string(from: Date())
        let required: Set<String> = ["inputPath", "outputPath", "outputFileName", "outputFileFullName", "currentPath", "currentFolder", "currentFileName", "currentFileFullName", "today"]
        let pattern = try NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_.-]*)\}"#)
        let sourceCommand = command as NSString
        let names = pattern.matches(in: command, range: NSRange(location: 0, length: sourceCommand.length)).map {
            sourceCommand.substring(with: $0.range(at: 1))
        }
        let environment = ProcessInfo.processInfo.environment
        let metadataNames = names.filter { !required.contains($0) && $0 != "HOME" && $0 != "PATH" && environment[$0] == nil }
        if !metadataNames.isEmpty, MarkdownPresentationParser.frontMatter(text) != nil {
            let metadata: [String: String]
            do { metadata = try PandocExportService.yamlScalarVariables(text, isCancelled: isCancelled) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if metadataNames.contains(where: { $0.contains(".") }) { throw error }
                metadata = [:]
            }
            for (key, value) in metadata where variables[key] == nil && !required.contains(key) && environment[key] == nil && key != "HOME" && key != "PATH" {
                variables[key] = value
            }
        }
        let parsed = try substitute(command, variables: variables, required: required)
        let stdoutURL = work.appendingPathComponent("stdout"), stderrURL = work.appendingPathComponent("stderr")
        guard manager.createFile(atPath: stdoutURL.path, contents: nil), manager.createFile(atPath: stderrURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        defer { try? stdout.close() }
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderr.close() }
        let exitStatus = try runShell(script: parsed.script, environment: environment.merging(parsed.environment) { _, new in new },
                                      directory: source?.deletingLastPathComponent() ?? work,
                                      stdout: stdout, stderr: stderr, isCancelled: isCancelled)
        try stdout.synchronize(); try stderr.synchronize()
        let out = String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self)
        let err = String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        if isCancelled() { throw CancellationError() }
        guard exitStatus == 0 else {
            throw CommandError.failed(err.isEmpty ? "zsh (\(exitStatus))" : err)
        }
        if case .file = destination {
            guard replacement != nil, let path = variables["outputPath"],
                  let attrs = try? manager.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeRegular else {
                throw PandocExportError.invalidConfiguration(L10n.tr("命令未生成输出文件"))
            }
            retained = true
            return Result(preparedURL: URL(fileURLWithPath: path), stdout: out, stderr: err)
        }
        return Result(preparedURL: nil, stdout: out, stderr: err)
    }
}
