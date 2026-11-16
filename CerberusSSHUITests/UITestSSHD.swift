import Foundation
import Darwin

/// The throwaway `sshd` the live UI tests connect to.
///
/// A UI-test bundle runs in a sandbox that may not listen on a port, and neither may anything it
/// starts, so the server is started from outside by the test-sshd script, which the shared
/// scheme runs before the tests and after them. This reads what the script left behind.
final class UITestSSHD {
    static let directory = URL(fileURLWithPath: "/tmp/cerberus-uitest-sshd")

    let port: Int
    /// A second free port, for a forward that leads to the server.
    let forwardPort: Int
    let userKeyPath: String
    /// The server's host key as an `authorized_keys`-style line.
    let hostKeyLine: String
    /// A different host key, which the server does not use.
    let otherKeyLine: String
    let userName: String
    /// The container with a one-time-code server (and a plain one behind it), if Docker and its image
    /// were there when the script ran.
    let totp: TOTPServer?
    /// The second server, which offers SFTP (and runs no forced command), when the script started it.
    let sftpPort: Int?

    struct TOTPServer {
        let port: Int
        let targetPort: Int
        let secret: String
        let hostKeyLine: String
    }

    /// `nil` when the script did not start a server (it was not run, or this Mac has no `sshd`),
    /// or the server is not answering.
    static func connect() -> UITestSSHD? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("server.env"), encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        var totp: TOTPServer?
        if let p = values["TOTP_PORT"].flatMap(Int.init), let t = values["TOTP_TARGET_PORT"].flatMap(Int.init),
           let secret = values["TOTP_SECRET"], let key = values["TOTP_HOSTKEY"] {
            totp = TOTPServer(port: p, targetPort: t, secret: secret, hostKeyLine: key)
        }
        guard let port = values["PORT"].flatMap(Int.init), let forward = values["FORWARD_PORT"].flatMap(Int.init),
              let key = values["KEY"], let hostKey = values["HOSTKEY"], let other = values["OTHERKEY"], let user = values["USER_NAME"],
              banner(port: port)?.hasPrefix("SSH-") == true else { return nil }
        return UITestSSHD(port: port, forwardPort: forward, userKeyPath: key, hostKeyLine: hostKey, otherKeyLine: other, userName: user, totp: totp,
                          sftpPort: values["SFTP_PORT"].flatMap(Int.init))
    }

    private init(port: Int, forwardPort: Int, userKeyPath: String, hostKeyLine: String, otherKeyLine: String, userName: String, totp: TOTPServer?, sftpPort: Int?) {
        self.port = port
        self.forwardPort = forwardPort
        self.userKeyPath = userKeyPath
        self.hostKeyLine = hostKeyLine
        self.otherKeyLine = otherKeyLine
        self.userName = userName
        self.totp = totp
        self.sftpPort = sftpPort
    }

    /// How many sessions the server is running right now. Each session leaves a file in `sessions/`
    /// while it lives (see the script), so this is how a test tells whether the app really closed a
    /// connection, not just hid it.
    func liveSessions() -> Int { sessionIDs().count }

    /// The running sessions' ids (the wrapper's process ids), which tell a new session from an old one.
    func sessionIDs() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: Self.directory.appendingPathComponent("sessions").path)) ?? [])
    }

    /// A file the remote shell can write to, for tests that type a command and check its effect.
    var scratchDirectory: URL { Self.directory }

    // MARK: Plumbing

    /// Runs a tool and throws if it fails.
    static func run(_ tool: String, _ arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw NSError(domain: "UITestSSHD", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(tool) failed"]) }
    }

    static func output(_ tool: String, _ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Opens a TCP connection to the loopback port, and reads up to `banner` bytes if asked.
    static func canConnect(port: Int) -> Bool { connect(port: port, readBanner: false) != nil }

    /// The first line the server on `port` sends (an SSH server sends its version), or `nil` if
    /// nothing is listening.
    static func banner(port: Int) -> String? { connect(port: port, readBanner: true) }

    private static func connect(port: Int, readBanner: Bool) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { return nil }
        guard readBanner else { return "" }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
    }
}
