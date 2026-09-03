import Crypto
import DBCore
import Foundation
import NIOCore
import NIOSSH

/// Reads and appends to OpenSSH's `known_hosts`, so DBStudio trusts the same host keys
/// the user's own `ssh` command already trusts.
public struct KnownHostsFile: Sendable {
    public let path: String

    public init(path: String = KnownHostsFile.defaultPath) {
        self.path = path
    }

    public static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/known_hosts")
    }

    /// One entry: the hosts it covers (plain or hashed) and the key itself.
    public struct Entry: Sendable {
        public let hostPattern: String
        public let keyType: String
        public let base64Key: String

        /// True when the host name is stored as an HMAC-SHA1 digest, which is OpenSSH's
        /// `HashKnownHosts yes` format.
        public var isHashed: Bool { hostPattern.hasPrefix("|1|") }
    }

    /// Every parsed entry. Unreadable or malformed lines are skipped rather than failing
    /// the connection, matching what `ssh` itself does.
    public func entries() -> [Entry] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            // A marker such as `@cert-authority` shifts the fields along by one.
            let offset = fields.first?.hasPrefix("@") == true ? 1 : 0
            guard fields.count >= offset + 3 else { return nil }
            return Entry(
                hostPattern: String(fields[offset]),
                keyType: String(fields[offset + 1]),
                base64Key: String(fields[offset + 2])
            )
        }
    }

    /// The keys recorded for `host` on `port`, in every form OpenSSH writes them.
    public func keys(forHost host: String, port: Int) -> [NIOSSHPublicKey] {
        // A non-default port is written as `[host]:port`.
        let candidates = port == 22 ? [host] : ["[\(host)]:\(port)", host]
        return entries().compactMap { entry -> NIOSSHPublicKey? in
            guard candidates.contains(where: { entry.matches(host: $0) }) else { return nil }
            return try? NIOSSHPublicKey(openSSHPublicKey: "\(entry.keyType) \(entry.base64Key)")
        }
    }

    /// True when `host` appears anywhere in the file, which is how `accept-new` tells a
    /// first sighting from a changed key.
    public func knows(host: String, port: Int) -> Bool {
        !keys(forHost: host, port: port).isEmpty
    }

    /// Appends a newly accepted key, creating `~/.ssh` if it does not exist.
    public func append(host: String, port: Int, key: NIOSSHPublicKey) throws {
        let name = port == 22 ? host : "[\(host)]:\(port)"
        var writer = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &writer)
        let blob = Data(writer.readBytes(length: writer.readableBytes) ?? [])
        // The key's own type name prefixes its blob as a length-prefixed SSH string.
        guard let keyType = Self.readSSHString(from: blob, at: 0) else {
            throw DBError.tunnelFailed(stage: .ssh, underlying: "Cannot serialise the host key")
        }
        let line = "\(name) \(keyType) \(blob.base64EncodedString())\n"

        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if let handle = FileHandle(forWritingAtPath: path) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    /// Reads a length-prefixed SSH string from the front of a serialised key blob.
    static func readSSHString(from data: Data, at offset: Int) -> String? {
        guard data.count >= offset + 4 else { return nil }
        let length = data[data.startIndex + offset ..< data.startIndex + offset + 4]
            .reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, data.count >= offset + 4 + length else { return nil }
        let start = data.startIndex + offset + 4
        return String(data: data[start ..< start + length], encoding: .utf8)
    }
}

extension KnownHostsFile.Entry {
    /// True when this entry covers `host`, handling both plain and hashed patterns.
    func matches(host: String) -> Bool {
        guard isHashed else {
            return hostPattern.split(separator: ",").contains { String($0) == host }
        }
        // `|1|<base64 salt>|<base64 HMAC-SHA1 of the host name>`
        let parts = hostPattern.split(separator: "|", omittingEmptySubsequences: true)
        guard parts.count >= 3,
              let salt = Data(base64Encoded: String(parts[1])),
              let expected = Data(base64Encoded: String(parts[2]))
        else { return false }
        let digest = Crypto.HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(host.utf8), using: SymmetricKey(data: salt)
        )
        return Data(digest) == expected
    }
}
