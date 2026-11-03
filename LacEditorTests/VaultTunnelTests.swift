import Foundation
import XCTest
@testable import LacEditor

@MainActor
final class VaultTunnelTests: XCTestCase {
    private func settings(host: String = "vps.example", user: String = "me", sshPort: Int = 22,
                          identityFile: String? = nil, remotePort: Int = 8765) -> VaultTunnelSettings {
        VaultTunnelSettings(host: host, user: user, sshPort: sshPort, identityFile: identityFile, remoteAPIPort: remotePort)
    }

    private func issue(_ settings: VaultTunnelSettings, localPort: Int = 51234) -> VaultSettingsIssue? {
        do { _ = try VaultTunnelArguments.make(settings: settings, localPort: localPort); return nil } catch { return error as? VaultSettingsIssue }
    }

    // MARK: Аргументы

    func testArgumentsExactOrderAndForwarding() throws {
        let arguments = try VaultTunnelArguments.make(settings: settings(), localPort: 51234)
        XCTAssertEqual(arguments, ["-N", "-T", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                                   "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ConnectTimeout=10",
                                   "-L", "127.0.0.1:51234:127.0.0.1:8765", "--", "me@vps.example"])
        XCTAssertFalse(arguments.contains("-p"))
        XCTAssertFalse(arguments.contains("-i"))
    }

    func testArgumentsWithPortAndIdentity() throws {
        let arguments = try VaultTunnelArguments.make(settings: settings(sshPort: 2222, identityFile: "/Users/me/my keys/id ed25519", remotePort: 9000),
                                                      localPort: 40000)
        let tail = Array(arguments.suffix(10))
        XCTAssertEqual(tail, ["-L", "127.0.0.1:40000:127.0.0.1:9000", "-i", "/Users/me/my keys/id ed25519", "-o", "IdentitiesOnly=yes",
                              "-p", "2222", "--", "me@vps.example"])
    }

    func testRejectsDashLeadingHostAndUser() {
        for host in ["-oProxyCommand=x", "-J", "", "  ", "a b", "a\nb", "a;b"] {
            XCTAssertEqual(issue(settings(host: host))?.field, .host, host)
        }
        for user in ["-l", "-oX", "", "me@corp", "a b", "a\nb"] {
            XCTAssertEqual(issue(settings(user: user))?.field, .user, user)
        }
        XCTAssertNil(issue(settings(host: "::1")))
        XCTAssertNil(issue(settings(user: "me.name_1+x")))
    }

    func testRejectsBadPorts() {
        for port in [0, -1, 65536] {
            XCTAssertEqual(issue(settings(sshPort: port))?.field, .sshPort)
            XCTAssertEqual(issue(settings(remotePort: port))?.field, .remoteAPIPort)
            XCTAssertNotNil(issue(settings(), localPort: port))
        }
        for port in [1, 65535] {
            XCTAssertNil(issue(settings(sshPort: port, remotePort: port), localPort: port))
        }
    }

    func testBlankIdentityFileMeansNone() throws {
        XCTAssertFalse(try VaultTunnelArguments.make(settings: settings(identityFile: "  "), localPort: 40000).contains("-i"))
        XCTAssertEqual(issue(settings(identityFile: "/a\n/b"))?.field, .identityFile)
    }

    func testManualCommand() {
        XCTAssertEqual(VaultTunnelArguments.manualCommand(settings: settings()), "ssh -- me@vps.example")
        XCTAssertEqual(VaultTunnelArguments.manualCommand(settings: settings(sshPort: 2222, identityFile: "/k/my key")),
                       "ssh -p 2222 -i '/k/my key' -- me@vps.example")
        XCTAssertEqual(VaultTunnelArguments.manualCommand(settings: settings(identityFile: "~/.ssh/id_ed25519")),
                       "ssh -i ~/.ssh/id_ed25519 -- me@vps.example")
    }

    // MARK: Разбор вывода ssh

    func testParseRealOpenSSHMessages() {
        let denied = ["me@h: Permission denied (publickey,password).", "Permission denied, please try again.",
                      "Received disconnect from 1.2.3.4 port 22:2: Too many authentication failures"]
        for text in denied { XCTAssertEqual(VaultTunnelFailure.parse(stderr: text), .permissionDenied, text) }
        XCTAssertEqual(VaultTunnelFailure.parse(stderr: "Host key verification failed.\n"), .unknownHostKey)
        XCTAssertEqual(VaultTunnelFailure.parse(stderr: "No ED25519 host key is known for vps.example and you have requested strict checking.\nHost key verification failed.\r\n"),
                       .unknownHostKey)
        let changed = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        Offending ED25519 key in /Users/me/.ssh/known_hosts:3
        Host key verification failed.
        """
        XCTAssertEqual(VaultTunnelFailure.parse(stderr: changed), .hostKeyChanged)
        XCTAssertEqual(VaultTunnelFailure.parse(stderr: "ssh: Could not resolve hostname nosuch.example: Name or service not known"),
                       .unreachable("nosuch.example"))
        XCTAssertEqual(VaultTunnelFailure.parse(stderr: "ssh: Could not resolve hostname nosuch.example: nodename nor servname provided, or not known"),
                       .unreachable("nosuch.example"))
        for reason in ["Connection refused", "Operation timed out", "No route to host"] {
            XCTAssertEqual(VaultTunnelFailure.parse(stderr: "ssh: connect to host vps.example port 22: \(reason)"), .unreachable("vps.example"))
        }
        XCTAssertEqual(VaultTunnelFailure.parse(stderr: "kex_exchange_identification: read: Connection reset by peer"), .unreachable(""))
        let busy = "bind [127.0.0.1]:50000: Address already in use\nchannel_setup_fwd_listener_tcpip: cannot listen to port: 50000\nCould not request local forwarding.\n"
        XCTAssertEqual(VaultTunnelFailure.parse(stderr: busy), .portInUse)
        XCTAssertEqual(VaultTunnelFailure.parse(stderr: "Load key \"/k\": invalid format\n"), .other("Load key \"/k\": invalid format"))
        XCTAssertEqual(VaultTunnelFailure.parse(stderr: ""), .other(""))
        XCTAssertEqual(VaultTunnelFailure.parse(stderr: String(repeating: "x", count: 500)), .other(String(repeating: "x", count: 200)))
    }

    func testFailureFlags() {
        XCTAssertTrue(VaultTunnelFailure.permissionDenied.isPermanent)
        XCTAssertTrue(VaultTunnelFailure.unknownHostKey.isPermanent)
        XCTAssertTrue(VaultTunnelFailure.hostKeyChanged.isPermanent)
        XCTAssertFalse(VaultTunnelFailure.unreachable("h").isPermanent)
        XCTAssertFalse(VaultTunnelFailure.portInUse.isPermanent)
        XCTAssertFalse(VaultTunnelFailure.other("x").isPermanent)
        XCTAssertNotNil(VaultTunnelFailure.permissionDenied.recoveryHint)
        XCTAssertNil(VaultTunnelFailure.unknownHostKey.recoveryHint)
        XCTAssertNil(VaultTunnelFailure.other("x").recoveryHint)
        XCTAssertEqual(VaultTunnelFailure.permissionDenied.userMessage, L10n.tr("服务器不接受 SSH 密钥"))
        XCTAssertEqual(VaultTunnelFailure.unknownHostKey.userMessage, L10n.tr("此 Mac 尚未连接过该服务器。请在终端中连接一次以确认其密钥"))
        XCTAssertEqual(VaultTunnelFailure.hostKeyChanged.userMessage, L10n.tr("服务器密钥已更改。可能是服务器重装或遭到冒充。连接已停止"))
        XCTAssertEqual(VaultTunnelFailure.unreachable("h").userMessage, L10n.tr("无法连接到服务器 %@", "h"))
        XCTAssertEqual(VaultTunnelFailure.unreachable("").userMessage, L10n.tr("无法连接到服务器"))
        XCTAssertEqual(VaultTunnelFailure.portInUse.userMessage, L10n.tr("本地端口被占用"))
        XCTAssertEqual(VaultTunnelFailure.other("boom").userMessage, L10n.tr("SSH 连接失败：%@", "boom"))
    }

    func testRestartDelaySchedule() {
        XCTAssertEqual((0..<7).map { VaultTunnel.restartDelay(attempt: $0) }, [5, 10, 20, 40, 60, 60, 60])
    }

    func testBoundedBufferKeepsTail() {
        let buffer = VaultBoundedBuffer(limit: 16)
        buffer.append(Data("0123456789".utf8))
        buffer.append(Data("abcdefghij".utf8))
        XCTAssertEqual(buffer.text, "456789abcdefghij")
        buffer.append(Data([0xFF, 0xFE, 0x80]))
        XCTAssertFalse(buffer.text.isEmpty)
    }

    func testFreeLocalPortIsUsable() throws {
        let port = try VaultTunnel.freeLocalPort()
        XCTAssertTrue((1024...65535).contains(port))
        XCTAssertNoThrow(try VaultTunnel.freeLocalPort())
    }

    // MARK: Туннель с поддельным ssh

    private func script(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fake-ssh.sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }

    func testFakeSSHPermissionDenied() async throws {
        var configuration = VaultTunnel.Configuration()
        configuration.executableURL = try script("echo 'Permission denied (publickey).' >&2\nexit 255")
        configuration.healthCheck = { _ in false }
        let tunnel = VaultTunnel(settings: settings(), configuration: configuration)
        do {
            _ = try await tunnel.start()
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual(error as? VaultTunnelFailure, .permissionDenied)
        }
        XCTAssertEqual(tunnel.state, .failed(.permissionDenied))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(tunnel.state, .failed(.permissionDenied))
    }

    func testFakeSSHNeverReadyTimesOut() async throws {
        var configuration = VaultTunnel.Configuration()
        configuration.executableURL = try script("exec sleep 30")
        configuration.readyTimeout = 0.5
        configuration.healthCheck = { _ in false }
        let tunnel = VaultTunnel(settings: settings(), configuration: configuration)
        let started = Date()
        do {
            _ = try await tunnel.start()
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual(error as? VaultTunnelFailure, .unreachable("vps.example"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(tunnel.state, .failed(.unreachable("vps.example")))
    }

    func testFakeSSHReadyThenStop() async throws {
        let counter = Counter()
        var configuration = VaultTunnel.Configuration()
        configuration.executableURL = try script("exec sleep 30")
        configuration.healthCheck = { _ in counter.next() >= 2 }
        let tunnel = VaultTunnel(settings: settings(), configuration: configuration)
        let port = try await tunnel.start()
        XCTAssertEqual(tunnel.state, .ready(localPort: port))
        let again = try await tunnel.start()
        XCTAssertEqual(again, port)
        tunnel.stop()
        XCTAssertEqual(tunnel.state, .stopped)
        let second = try await tunnel.start()
        XCTAssertEqual(tunnel.state, .ready(localPort: second))
        tunnel.stop()
        XCTAssertEqual(tunnel.state, .stopped)
    }

    func testCancelledStartStopsTunnel() async throws {
        var configuration = VaultTunnel.Configuration()
        configuration.executableURL = try script("exec sleep 30")
        configuration.readyTimeout = 30
        configuration.healthCheck = { _ in false }
        let tunnel = VaultTunnel(settings: settings(), configuration: configuration)
        let task = Task { try await tunnel.start() }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("ожидалась отмена")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(tunnel.state, .stopped)
    }

    // MARK: Перезапуск, повторы, ожидание выхода

    private func pids(_ url: URL) -> [Int32] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) }
    }

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    private func waitUntil(_ seconds: TimeInterval = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func workFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testRestartNowReplacesProcessAndWaitsForOldOne() async throws {
        let folder = try workFolder()
        let pidFile = folder.appendingPathComponent("pids")
        var configuration = VaultTunnel.Configuration()
        configuration.executableURL = try script("echo $$ >> '\(pidFile.path)'\nexec sleep 30")
        configuration.healthCheck = { _ in true }
        let tunnel = VaultTunnel(settings: settings(), configuration: configuration)
        let port = try await tunnel.start()
        try await waitUntil { !self.pids(pidFile).isEmpty }
        let first = try XCTUnwrap(pids(pidFile).first)
        tunnel.restartNow()
        XCTAssertEqual(tunnel.state, .starting)
        try await waitUntil { tunnel.state == .ready(localPort: port) && self.pids(pidFile).count == 2 }
        XCTAssertEqual(tunnel.state, .ready(localPort: port))
        XCTAssertEqual(pids(pidFile).count, 2)
        XCTAssertFalse(isAlive(first), "старый ssh должен выйти до нового запуска")
        tunnel.stop()
    }

    func testRestartNowDoesNotCancelWaitingStart() async throws {
        let folder = try workFolder()
        let flag = folder.appendingPathComponent("flag")
        var configuration = VaultTunnel.Configuration()
        // Первый процесс «обрывается» после готовности, второй живёт.
        configuration.executableURL = try script("""
        if [ -e '\(flag.path)' ]; then exec sleep 30; fi
        touch '\(flag.path)'
        sleep 1
        echo 'Connection reset by peer' >&2
        exit 255
        """)
        configuration.healthCheck = { _ in true }
        let tunnel = VaultTunnel(settings: settings(), configuration: configuration)
        let port = try await tunnel.start()
        try await waitUntil { if case .restarting = tunnel.state { true } else { false } }
        guard case .restarting = tunnel.state else { return XCTFail("ожидался .restarting, а не \(tunnel.state)") }
        let waiter = Task { try await tunnel.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        tunnel.restartNow()
        let result = try await waiter.value
        XCTAssertEqual(result, port)
        XCTAssertEqual(tunnel.state, .ready(localPort: port))
        tunnel.stop()
    }

    func testExitAfterReadyGoesToRestartingWithBackoff() async throws {
        let folder = try workFolder()
        let flag = folder.appendingPathComponent("flag")
        var configuration = VaultTunnel.Configuration()
        configuration.executableURL = try script("""
        touch '\(flag.path)'
        sleep 1
        echo 'Connection reset by peer' >&2
        exit 255
        """)
        configuration.healthCheck = { _ in true }
        let tunnel = VaultTunnel(settings: settings(), configuration: configuration)
        _ = try await tunnel.start()
        try await waitUntil { if case .restarting = tunnel.state { true } else { false } }
        XCTAssertEqual(tunnel.state, .restarting(after: VaultTunnel.restartDelay(attempt: 0)))
        tunnel.stop()
        XCTAssertEqual(tunnel.state, .stopped)
    }

    func testPermanentExitAfterReadyFailsWithoutRestart() async throws {
        var configuration = VaultTunnel.Configuration()
        configuration.executableURL = try script("sleep 1\necho 'Permission denied (publickey).' >&2\nexit 255")
        configuration.healthCheck = { _ in true }
        let tunnel = VaultTunnel(settings: settings(), configuration: configuration)
        _ = try await tunnel.start()
        try await waitUntil { if case .failed = tunnel.state { true } else { false } }
        XCTAssertEqual(tunnel.state, .failed(.permissionDenied))
    }

    func testPortInUseRetriesWithNewPort() async throws {
        let folder = try workFolder()
        let flag = folder.appendingPathComponent("flag")
        let ready = folder.appendingPathComponent("ready")
        var configuration = VaultTunnel.Configuration()
        configuration.executableURL = try script("""
        if [ ! -e '\(flag.path)' ]; then
          touch '\(flag.path)'
          echo 'bind [127.0.0.1]:50000: Address already in use' >&2
          echo 'Could not request local forwarding.' >&2
          exit 255
        fi
        touch '\(ready.path)'
        exec sleep 30
        """)
        configuration.healthCheck = { _ in FileManager.default.fileExists(atPath: ready.path) }
        let tunnel = VaultTunnel(settings: settings(), configuration: configuration)
        let port = try await tunnel.start()
        XCTAssertEqual(tunnel.state, .ready(localPort: port))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flag.path))
        tunnel.stop()
    }

    func testDoubleStartSharesOneProcess() async throws {
        let folder = try workFolder()
        let pidFile = folder.appendingPathComponent("pids")
        let counter = Counter()
        var configuration = VaultTunnel.Configuration()
        configuration.executableURL = try script("echo $$ >> '\(pidFile.path)'\nexec sleep 30")
        configuration.healthCheck = { _ in counter.next() >= 3 }
        let tunnel = VaultTunnel(settings: settings(), configuration: configuration)
        async let first = tunnel.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        async let second = tunnel.start()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(pids(pidFile).count, 1)
        tunnel.stop()
    }

    func testStartAfterStopWaitsForOldProcessAndKillsStubbornOne() async throws {
        let folder = try workFolder()
        let pidFile = folder.appendingPathComponent("pids")
        var configuration = VaultTunnel.Configuration()
        // SIGTERM игнорируется: помочь может только SIGKILL.
        configuration.executableURL = try script("trap '' TERM\necho $$ >> '\(pidFile.path)'\nwhile :; do sleep 0.2; done")
        configuration.healthCheck = { _ in true }
        let tunnel = VaultTunnel(settings: settings(), configuration: configuration)
        _ = try await tunnel.start()
        try await waitUntil { !self.pids(pidFile).isEmpty }
        let first = try XCTUnwrap(pids(pidFile).first)
        tunnel.stop()
        XCTAssertEqual(tunnel.state, .stopped)
        let started = Date()
        let port = try await tunnel.start()
        XCTAssertEqual(tunnel.state, .ready(localPort: port))
        XCTAssertFalse(isAlive(first))
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.5)
        try await waitUntil { self.pids(pidFile).count == 2 }
        XCTAssertEqual(pids(pidFile).count, 2)
        tunnel.stop()
    }
}
