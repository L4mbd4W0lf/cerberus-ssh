import XCTest

/// A `.ssh` folder inside the test's throwaway home, for the import sheets to read.
extension CerberusUITestCase {
    /// Makes `~/.ssh` with ed25519 keys (the names in `keys`, unprotected; the entries of `protected`,
    /// each with its passphrase), a `known_hosts` with one host if asked, and a `config` if given.
    @discardableResult
    func makeSSHFolder(keys: [String] = [], protected: [String: String] = [:], knownHost: String? = nil, config: String? = nil) throws -> URL {
        let ssh = testHome.appendingPathComponent(".ssh")
        try? FileManager.default.removeItem(at: ssh)   // the home is shared, so start from nothing
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func keygen(_ name: String, passphrase: String) throws {
            try UITestSSHD.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", passphrase, "-C", "\(name)@uitest", "-f", ssh.appendingPathComponent(name).path])
        }
        for name in keys { try keygen(name, passphrase: "") }
        for (name, passphrase) in protected { try keygen(name, passphrase: passphrase) }
        if let knownHost {
            // Any valid ed25519 public key will do as the host's key.
            try keygen("scratch-host-key", passphrase: "")
            let pub = try String(contentsOf: ssh.appendingPathComponent("scratch-host-key.pub"), encoding: .utf8)
                .split(separator: " ").prefix(2).joined(separator: " ")
            try "\(knownHost) \(pub)\n".write(to: ssh.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: ssh.appendingPathComponent("scratch-host-key"))
            try? FileManager.default.removeItem(at: ssh.appendingPathComponent("scratch-host-key.pub"))
        }
        if let config { try config.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8) }
        return ssh
    }
}
