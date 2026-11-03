import Combine
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Аргументы `/usr/bin/ssh` для туннеля (без оболочки, значения не склеиваются в одну строку).
enum VaultTunnelArguments {
    /// -N -T -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3
    /// -o ConnectTimeout=10 -L 127.0.0.1:<localPort>:127.0.0.1:<remoteAPIPort> [-i ключ -o IdentitiesOnly=yes] [-p порт, если не 22] -- пользователь@сервер
    static func make(settings: VaultTunnelSettings, localPort: Int) throws -> [String] {
        if let issue = settings.issues().first { throw issue }
        guard VaultTunnelSettings.isValidPort(localPort) else {
            throw VaultSettingsIssue(field: .remoteAPIPort, message: L10n.tr("端口应为 1–65535 的数字"))
        }
        var arguments = ["-N", "-T",
                         "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ConnectTimeout=10",
                         "-L", "127.0.0.1:\(localPort):127.0.0.1:\(settings.remoteAPIPort)"]
        // IdentitiesOnly: ssh-agent не подсовывает другие ключи, пробуется только указанный.
        if let key = settings.trimmedIdentityFile { arguments += ["-i", key, "-o", "IdentitiesOnly=yes"] }
        // Порт 22 не передаётся: иначе `-p 22` затёр бы Port из ~/.ssh/config.
        if settings.sshPort != 22 { arguments += ["-p", String(settings.sshPort)] }
        arguments += ["--", "\(settings.user.trimmingCharacters(in: .whitespacesAndNewlines))@\(settings.host.trimmingCharacters(in: .whitespacesAndNewlines))"]
        return arguments
    }

    static func validate(settings: VaultTunnelSettings) -> [VaultSettingsIssue] { settings.issues() }

    /// «ssh [-p порт] [-i ключ] пользователь@сервер» для вставки в Терминал.
    static func manualCommand(settings: VaultTunnelSettings) -> String {
        var parts = ["ssh"]
        if settings.sshPort != 22 { parts += ["-p", String(settings.sshPort)] }
        if let key = settings.trimmedIdentityFile {
            parts += ["-i", key.hasPrefix("~/") ? "~/" + quoted(String(key.dropFirst(2))) : quoted(key)]
        }
        parts.append("--")
        parts.append(quoted("\(settings.user.trimmingCharacters(in: .whitespacesAndNewlines))@\(settings.host.trimmingCharacters(in: .whitespacesAndNewlines))"))
        return parts.joined(separator: " ")
    }

    /// Значения с небезопасными для оболочки символами берутся в одинарные кавычки.
    private static func quoted(_ value: String) -> String {
        let safe = value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122) || "@%+=:,./_-".unicodeScalars.contains(scalar)
        }
        if safe, !value.isEmpty { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum VaultTunnelFailure: Error, Equatable {
    case permissionDenied, unknownHostKey, hostKeyChanged, unreachable(String), portInUse, other(String)

    /// Разбор вывода ошибок OpenSSH. Порядок: hostKeyChanged, unknownHostKey, permissionDenied, portInUse, unreachable, other.
    static func parse(stderr: String) -> VaultTunnelFailure {
        let text = stderr.lowercased()
        func has(_ markers: String...) -> Bool { markers.contains { text.contains($0) } }
        if has("remote host identification has changed", "possible dns spoofing") || (text.contains("offending") && text.contains("key in")) {
            return .hostKeyChanged
        }
        if has("host key verification failed") || (text.contains("no ") && text.contains("host key is known")) {
            return .unknownHostKey
        }
        if has("permission denied", "too many authentication failures") { return .permissionDenied }
        if has("address already in use", "cannot listen to port", "could not request local forwarding") { return .portInUse }
        if has("could not resolve hostname", "connect to host", "connection refused", "connection timed out",
               "operation timed out", "no route to host", "network is unreachable", "connection closed by",
               "connection reset by", "kex_exchange_identification", "ssh_exchange_identification", "nodename nor servname") {
            return .unreachable(hostName(in: stderr))
        }
        let last = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        return .other(String(last.prefix(200)))
    }

    /// Имя сервера из «hostname X:» или «connect to host X port»; иначе пустая строка.
    private static func hostName(in stderr: String) -> String {
        for (marker, terminator) in [("hostname ", ":"), ("connect to host ", " port")] {
            guard let range = stderr.range(of: marker, options: .caseInsensitive) else { continue }
            let rest = stderr[range.upperBound...]
            if let end = rest.range(of: terminator) {
                let name = rest[..<end.lowerBound].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !name.contains(where: \.isNewline) { return name }
            }
        }
        return ""
    }

    var userMessage: String {
        switch self {
        case .permissionDenied: L10n.tr("服务器不接受 SSH 密钥")
        case .unknownHostKey: L10n.tr("此 Mac 尚未连接过该服务器。请在终端中连接一次以确认其密钥")
        case .hostKeyChanged: L10n.tr("服务器密钥已更改。可能是服务器重装或遭到冒充。连接已停止")
        case .unreachable(let name): name.isEmpty ? L10n.tr("无法连接到服务器") : L10n.tr("无法连接到服务器 %@", name)
        case .portInUse: L10n.tr("本地端口被占用")
        case .other(let line): line.isEmpty ? L10n.tr("无法连接到服务器") : L10n.tr("SSH 连接失败：%@", line)
        }
    }

    /// Для permissionDenied: что сделать, если у ключа есть пароль.
    var recoveryHint: String? {
        guard self == .permissionDenied else { return nil }
        return L10n.tr("若密钥设有密码，请在终端运行：%@", "ssh-add --apple-use-keychain ~/.ssh/id_ed25519")
    }

    /// Без автоповтора: пароль ssh не спросит, ключ сам не появится.
    var isPermanent: Bool {
        switch self {
        case .permissionDenied, .unknownHostKey, .hostKeyChanged: true
        default: false
        }
    }
}

/// Ограниченный буфер вывода ошибок ssh: последние байты; потокобезопасный; в журнал не пишется.
final class VaultBoundedBuffer: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var storage = Data()

    init(limit: Int = 8 * 1024) { self.limit = limit }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(data)
        if storage.count > limit { storage = Data(storage.suffix(limit)) }
    }

    /// UTF-8 с заменой повреждённых байтов.
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }
}

/// SSH-туннель до сервера: процесс `ssh -N -L …`, готовность по `/healthz`, перезапуск при обрыве.
@MainActor
final class VaultTunnel: ObservableObject {
    enum State: Equatable {
        case stopped, starting, ready(localPort: Int), restarting(after: TimeInterval), failed(VaultTunnelFailure)
    }

    struct Configuration {
        var executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var readyTimeout: TimeInterval = 10
        /// Проверка готовности: по умолчанию настоящий `/healthz` через локальный порт.
        var healthCheck: @Sendable (_ localPort: Int) async -> Bool = Configuration.defaultHealthCheck

        static let defaultHealthCheck: @Sendable (Int) async -> Bool = { port in
            guard let url = URL(string: "http://127.0.0.1:\(port)") else { return false }
            do {
                try await VaultClient(baseURL: url, token: "").health(timeout: 2)
                return true
            } catch {
                return false
            }
        }
    }

    /// Запущенный процесс ssh и всё, что к нему относится.
    private final class Running {
        let process = Process()
        let errors = VaultBoundedBuffer()
        /// Процесс завершился и его вывод ошибок прочитан до конца.
        var exited = false
        var terminated = false
        var streamEnded = false
        var isReady = false
    }

    @Published private(set) var state: State = .stopped

    private let settings: VaultTunnelSettings
    private let configuration: Configuration
    private var running: Running?
    private var localPort: Int?
    private var attempt = 0
    /// Меняется при stop()/новом start(): устаревшие ожидания сами прекращаются.
    private var generation = 0
    private var restartTask: Task<Void, Never>?
    /// Меняется только при stop(): ожидающие start() прекращаются лишь тогда, а не при restartNow().
    private var stopCount = 0
    /// Последний остановленный ssh: новый запуск ждёт его выхода, чтобы не упереться в занятый порт.
    private var lastRetired: Running?

    init(settings: VaultTunnelSettings, configuration: Configuration = Configuration()) {
        self.settings = settings
        self.configuration = configuration
    }

    nonisolated static func restartDelay(attempt: Int) -> TimeInterval {
        min(60, 5 * pow(2, Double(max(0, min(attempt, 10)))))
    }

    nonisolated static func freeLocalPort() throws -> Int {
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        let descriptor = socket(AF_INET, streamType, 0)
        guard descriptor >= 0 else { throw VaultTunnelFailure.portInUse }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw VaultTunnelFailure.portInUse }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw VaultTunnelFailure.portInUse }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    // MARK: Управление

    /// Запускает ssh и ждёт готовности `/healthz`. Бросает `VaultTunnelFailure` (state → .failed) или `CancellationError` (state → .stopped).
    func start() async throws -> Int {
        switch state {
        case .ready(let port):
            return port
        case .starting, .restarting:
            return try await waitForSettledState()
        case .stopped, .failed:
            break
        }
        restartTask?.cancel()
        restartTask = nil
        generation += 1
        let token = generation
        attempt = 0
        state = .starting
        do {
            return try await launchUntilReady(generation: token)
        } catch let failure as VaultTunnelFailure {
            // Если за время запуска вызвали stop(), состояние уже выставлено им.
            if token == generation { state = .failed(failure) }
            throw failure
        }
    }

    func stop() {
        generation += 1
        stopCount += 1
        restartTask?.cancel()
        restartTask = nil
        terminateRunning()
        state = .stopped
    }

    /// Пробуждение Mac, смена сети, «Повторить»: сразу, без паузы. Из .stopped и во время запуска ничего не делает.
    func restartNow() {
        switch state {
        case .stopped, .starting: return
        default: break
        }
        restartTask?.cancel()
        terminateRunning()
        attempt = 0
        generation += 1
        let token = generation
        state = .starting
        restartTask = Task { [weak self] in await self?.restart(generation: token) }
    }

    // MARK: Запуск

    private func waitForSettledState() async throws -> Int {
        let stops = stopCount
        while true {
            try Task.checkCancellation()
            switch state {
            case .ready(let port): return port
            case .failed(let failure): throw failure
            case .stopped: throw CancellationError()
            case .starting, .restarting:
                if stops != stopCount { throw CancellationError() }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Запускает ssh (при занятом порте — с новым портом, до 3 раз) и ждёт готовности.
    private func launchUntilReady(generation token: Int) async throws -> Int {
        var portRetries = 0
        while true {
            let port: Int
            if let known = localPort { port = known } else {
                port = try Self.freeLocalPort()
                localPort = port
            }
            do {
                await Self.waitForExit(lastRetired)
                if token != generation || Task.isCancelled { throw CancellationError() }
                try await launch(port: port, generation: token)
                attempt = 0
                state = .ready(localPort: port)
                return port
            } catch VaultTunnelFailure.portInUse where portRetries < 3 {
                portRetries += 1
                localPort = nil
            } catch is CancellationError {
                if token == generation { terminateRunning(); state = .stopped }
                throw CancellationError()
            }
        }
    }

    private func launch(port: Int, generation token: Int) async throws {
        let arguments: [String]
        do { arguments = try VaultTunnelArguments.make(settings: settings, localPort: port) } catch {
            throw VaultTunnelFailure.other((error as? VaultSettingsIssue)?.message ?? "")
        }
        let box = Running()
        let process = box.process
        process.executableURL = configuration.executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe
        let errors = box.errors
        // Вывод читается одним способом: до конца потока; разбор — только после него.
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak box] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                Task { @MainActor in self?.streamDidEnd(box) }
            } else {
                errors.append(data)
            }
        }
        // box слабая ссылка: процесс не держит владельца обработчика, круговой ссылки нет.
        process.terminationHandler = { [weak self, weak box] _ in
            Task { @MainActor in self?.processDidTerminate(box) }
        }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw VaultTunnelFailure.other(error.localizedDescription)
        }
        running = box

        let deadline = Date().addingTimeInterval(configuration.readyTimeout)
        while true {
            if token != generation || Task.isCancelled {
                running = nil
                retire(box)
                throw CancellationError()
            }
            if box.exited {
                running = nil
                throw VaultTunnelFailure.parse(stderr: box.errors.text)
            }
            if await configuration.healthCheck(port) {
                if token != generation || Task.isCancelled {
                    running = nil
                    retire(box)
                    throw CancellationError()
                }
                if box.exited {
                    running = nil
                    throw VaultTunnelFailure.parse(stderr: box.errors.text)
                }
                box.isReady = true
                return
            }
            if Date() >= deadline {
                running = nil
                retire(box)
                throw VaultTunnelFailure.unreachable(settings.host)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// SIGTERM; если ssh не вышел за ~2 с, добавляется SIGKILL. Новый запуск ждёт выхода (`lastRetired`).
    private func retire(_ box: Running) {
        if box.process.isRunning { box.process.terminate() }
        lastRetired = box
        Task { await Self.waitForExit(box) }
    }

    private static func waitForExit(_ box: Running?) async {
        guard let box, !box.terminated else { return }
        let killAt = Date().addingTimeInterval(2)
        var killed = false
        while !box.terminated {
            if !killed, Date() >= killAt {
                if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
                killed = true
            }
            if killed, Date() >= killAt.addingTimeInterval(2) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
        }
    }

    private func terminateRunning() {
        guard let box = running else { return }
        running = nil
        box.isReady = false
        retire(box)
    }

    // MARK: Выход процесса и перезапуск

    private func processDidTerminate(_ box: Running?) {
        guard let box else { return }
        box.terminated = true
        // Если вывод не закрылся (дочерний процесс держит канал), ждём его не дольше секунды.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.streamDidEnd(box)
        }
        finishIfDone(box)
    }

    private func streamDidEnd(_ box: Running?) {
        guard let box else { return }
        box.streamEnded = true
        finishIfDone(box)
    }

    private func finishIfDone(_ box: Running) {
        guard box.terminated, box.streamEnded, !box.exited else { return }
        box.process.terminationHandler = nil
        processExited(box)
    }

    private func processExited(_ box: Running) {
        box.exited = true
        // До готовности выход разбирает launch; ушедший в сторону процесс (stop, restartNow) игнорируется.
        guard box.isReady, running === box else { return }
        running = nil
        let failure = VaultTunnelFailure.parse(stderr: box.errors.text)
        if failure.isPermanent {
            state = .failed(failure)
        } else {
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        let delay = Self.restartDelay(attempt: attempt)
        attempt += 1
        state = .restarting(after: delay)
        let token = generation
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.restart(generation: token)
        }
    }

    private func restart(generation token: Int) async {
        guard token == generation else { return }
        state = .starting
        do {
            _ = try await launchUntilReady(generation: token)
        } catch is CancellationError {
            return
        } catch let failure as VaultTunnelFailure {
            guard token == generation else { return }
            if failure.isPermanent { state = .failed(failure) } else { scheduleRestart() }
        } catch {
            return
        }
    }
}
