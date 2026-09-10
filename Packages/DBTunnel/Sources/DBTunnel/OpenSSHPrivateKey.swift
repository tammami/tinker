import CTinkerBcrypt
import Crypto
import Foundation
import _CryptoExtras

/// A private key read from a key file, in any format `ssh-keygen` has written.
///
/// The OpenSSH format (`-----BEGIN OPENSSH PRIVATE KEY-----`, the default since OpenSSH 7.8)
/// is parsed here, including the bcrypt-and-AES encryption a passphrase adds. The PEM
/// formats older releases wrote — `RSA PRIVATE KEY`, `EC PRIVATE KEY`, PKCS#8 `PRIVATE KEY`
/// — are decoded by swift-crypto; a passphrase on one of those uses OpenSSL's legacy MD5
/// scheme, which is implemented here for AES.
///
/// Citadel's own reader is not used because it keeps an RSA key's private numbers to itself,
/// and signing with SHA-2 needs them (see ADR-0039).
enum OpenSSHPrivateKey {
    case rsa(RSAKeyMaterial)
    case ed25519(Curve25519.Signing.PrivateKey)
    case ecdsaP256(P256.Signing.PrivateKey)
    case ecdsaP384(P384.Signing.PrivateKey)
    case ecdsaP521(P521.Signing.PrivateKey)

    /// Reads a key file's text. `passphrase` is used only when the key is encrypted.
    static func parse(_ text: String, passphrase: Data?) throws -> OpenSSHPrivateKey {
        guard let block = try PEMBlock(text: text) else { throw OpenSSHKeyError.unrecognisedFormat }
        switch block.label {
        case "OPENSSH PRIVATE KEY":
            return try parseOpenSSH(block.body, passphrase: passphrase)
        case "RSA PRIVATE KEY":
            let der = try block.decryptedBody(passphrase: passphrase)
            guard let key = try? _RSA.Signing.PrivateKey(unsafeDERRepresentation: der) else {
                throw block.isEncrypted ? OpenSSHKeyError.wrongPassphrase : OpenSSHKeyError.malformed("not an RSA key")
            }
            return .rsa(try RSAKeyMaterial(key: key))
        case "EC PRIVATE KEY":
            // SEC1, which CryptoKit does not read; the scalar and curve are lifted out by hand.
            let der = try block.decryptedBody(passphrase: passphrase)
            do {
                return try parseSEC1(der)
            } catch let error as OpenSSHKeyError {
                throw block.isEncrypted ? OpenSSHKeyError.wrongPassphrase : error
            }
        case "PRIVATE KEY":
            let der = try block.decryptedBody(passphrase: passphrase)
            if let key = try? _RSA.Signing.PrivateKey(unsafeDERRepresentation: der) {
                return .rsa(try RSAKeyMaterial(key: key))
            }
            if let key = try? P256.Signing.PrivateKey(derRepresentation: der) { return .ecdsaP256(key) }
            if let key = try? P384.Signing.PrivateKey(derRepresentation: der) { return .ecdsaP384(key) }
            if let key = try? P521.Signing.PrivateKey(derRepresentation: der) { return .ecdsaP521(key) }
            throw block.isEncrypted
                ? OpenSSHKeyError.wrongPassphrase
                : OpenSSHKeyError.unsupportedKeyType("this PKCS#8")
        case "ENCRYPTED PRIVATE KEY":
            throw OpenSSHKeyError.unsupportedEncryption("PKCS#8")
        default:
            throw OpenSSHKeyError.unrecognisedFormat
        }
    }

    // MARK: - OpenSSH format

    /// The `openssh-key-v1` container: cipher, KDF, one public key, and a private section
    /// that is encrypted when the cipher is not `none`.
    private static func parseOpenSSH(_ bytes: Data, passphrase: Data?) throws -> OpenSSHPrivateKey {
        var reader = SSHReader(bytes)
        let magic = Array("openssh-key-v1\0".utf8)
        guard try reader.readBytes(magic.count) == magic else { throw OpenSSHKeyError.unrecognisedFormat }
        let cipher = try reader.readString()
        let kdf = try reader.readString()
        let kdfOptions = try reader.readBlob()
        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else { throw OpenSSHKeyError.malformed("\(keyCount) keys in one file") }
        _ = try reader.readBlob()  // the public key, repeated inside the private section
        let privateSection = try reader.readBlob()

        let plaintext: [UInt8]
        if cipher == "none" {
            plaintext = privateSection
        } else {
            guard let passphrase, !passphrase.isEmpty else { throw OpenSSHKeyError.passphraseRequired }
            guard kdf == "bcrypt" else { throw OpenSSHKeyError.unsupportedKDF(kdf) }
            guard let scheme = AESScheme(openSSHName: cipher) else { throw OpenSSHKeyError.unsupportedCipher(cipher) }
            var options = SSHReader(Data(kdfOptions))
            let salt = try options.readBlob()
            let rounds = try options.readUInt32()
            let derived = try bcryptPBKDF(passphrase, salt: salt, length: scheme.keyLength + AESScheme.blockSize, rounds: rounds)
            plaintext = try scheme.decrypt(
                privateSection, key: derived[..<scheme.keyLength], iv: derived[scheme.keyLength...], padded: false
            )
        }

        var body = SSHReader(Data(plaintext))
        let check1 = try body.readUInt32()
        let check2 = try body.readUInt32()
        guard check1 == check2 else {
            throw cipher == "none" ? OpenSSHKeyError.malformed("check bytes differ") : OpenSSHKeyError.wrongPassphrase
        }
        let type = try body.readString()
        switch type {
        case "ssh-rsa":
            let n = try body.readBlob()
            let e = try body.readBlob()
            let d = try body.readBlob()
            _ = try body.readBlob()  // iqmp; swift-crypto derives the CRT values itself
            let p = try body.readBlob()
            let q = try body.readBlob()
            let key: _RSA.Signing.PrivateKey
            do {
                key = try _RSA.Signing.PrivateKey(n: n, e: e, d: d, p: p, q: q)
            } catch {
                throw OpenSSHKeyError.malformed("the RSA numbers do not form a key")
            }
            return .rsa(try RSAKeyMaterial(key: key))
        case "ssh-ed25519":
            _ = try body.readBlob()  // public key
            let secret = try body.readBlob()  // 32-byte seed followed by the public key
            guard secret.count == 64 else { throw OpenSSHKeyError.malformed("an ed25519 secret of \(secret.count) bytes") }
            do {
                return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: secret[..<32]))
            } catch {
                throw OpenSSHKeyError.malformed("the ed25519 secret is not a key")
            }
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try body.readString()  // curve name, repeated from the type
            _ = try body.readBlob()  // public point
            let scalar = try body.readBlob()
            do {
                switch type {
                case "ecdsa-sha2-nistp256":
                    return .ecdsaP256(try P256.Signing.PrivateKey(rawRepresentation: fixedWidth(scalar, 32)))
                case "ecdsa-sha2-nistp384":
                    return .ecdsaP384(try P384.Signing.PrivateKey(rawRepresentation: fixedWidth(scalar, 48)))
                default:
                    return .ecdsaP521(try P521.Signing.PrivateKey(rawRepresentation: fixedWidth(scalar, 66)))
                }
            } catch {
                throw OpenSSHKeyError.malformed("the ECDSA scalar is not a key")
            }
        default:
            throw OpenSSHKeyError.unsupportedKeyType(type)
        }
    }

    // MARK: - SEC1

    /// RFC 5915's `ECPrivateKey`: `SEQUENCE { version 1, OCTET STRING scalar, [0] curve,
    /// [1] public key }`. The curve is read from its OID when it is named; `ssh-keygen -m PEM`
    /// spells the curve out as explicit parameters instead, and then the scalar's width says
    /// which of the three NIST curves it is — the only curves OpenSSH uses.
    private static func parseSEC1(_ der: Data) throws -> OpenSSHPrivateKey {
        var outer = DERReader(der)
        var sequence = DERReader(try outer.readElement(tag: 0x30))
        _ = try sequence.readElement(tag: 0x02)  // version
        let scalar = try sequence.readElement(tag: 0x04)
        var curve: String?
        if let parameters = try? sequence.readElement(tag: 0xA0), parameters.first == 0x06 {
            var inner = DERReader(parameters)
            let oid = try inner.readElement(tag: 0x06)
            switch Array(oid) {
            case [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]: curve = "nistp256"
            case [0x2B, 0x81, 0x04, 0x00, 0x22]: curve = "nistp384"
            case [0x2B, 0x81, 0x04, 0x00, 0x23]: curve = "nistp521"
            default: throw OpenSSHKeyError.unsupportedKeyType("an EC key on an unknown curve")
            }
        }
        do {
            switch (curve, scalar.count) {
            case ("nistp256", _), (nil, 32):
                return .ecdsaP256(try P256.Signing.PrivateKey(rawRepresentation: fixedWidth(Array(scalar), 32)))
            case ("nistp384", _), (nil, 48):
                return .ecdsaP384(try P384.Signing.PrivateKey(rawRepresentation: fixedWidth(Array(scalar), 48)))
            case ("nistp521", _), (nil, 66):
                return .ecdsaP521(try P521.Signing.PrivateKey(rawRepresentation: fixedWidth(Array(scalar), 66)))
            default:
                throw OpenSSHKeyError.unsupportedKeyType("an EC key on an unknown curve")
            }
        } catch let error as OpenSSHKeyError {
            throw error
        } catch {
            throw OpenSSHKeyError.malformed("the EC scalar is not a key")
        }
    }

    /// An `mpint` as a fixed-width unsigned number: leading zeros dropped, then left-padded.
    private static func fixedWidth(_ mpint: [UInt8], _ width: Int) -> [UInt8] {
        let magnitude = Array(mpint.drop { $0 == 0 })
        guard magnitude.count <= width else { return magnitude }
        return [UInt8](repeating: 0, count: width - magnitude.count) + magnitude
    }

    /// OpenBSD's bcrypt_pbkdf, the KDF behind every encrypted OpenSSH key.
    private static func bcryptPBKDF(_ passphrase: Data, salt: [UInt8], length: Int, rounds: UInt32) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: length)
        let status = passphrase.withUnsafeBytes { pass -> Int32 in
            guard let passBase = pass.baseAddress else { return -1 }
            return salt.withUnsafeBufferPointer { salt in
                output.withUnsafeMutableBufferPointer { out in
                    tinker_bcrypt_pbkdf(
                        passBase.assumingMemoryBound(to: UInt8.self), pass.count,
                        salt.baseAddress, salt.count, out.baseAddress, out.count, rounds
                    )
                }
            }
        }
        guard status == 0 else { throw OpenSSHKeyError.malformed("the key derivation parameters are out of range") }
        return output
    }
}

/// An RSA key together with its public numbers in the `mpint` form the SSH wire uses.
struct RSAKeyMaterial: Sendable {
    let key: _RSA.Signing.PrivateKey
    let modulus: Data
    let publicExponent: Data

    init(key: _RSA.Signing.PrivateKey) throws {
        let primitives = try key.publicKey.getKeyPrimitives()
        self.key = key
        modulus = Self.mpint(primitives.modulus)
        publicExponent = Self.mpint(primitives.publicExponent)
    }

    /// The SSH `mpint` encoding of an unsigned number: no leading zeros, and one zero byte in
    /// front when the top bit is set, so that the number reads as positive.
    static func mpint(_ magnitude: Data) -> Data {
        let trimmed = Data(magnitude.drop { $0 == 0 })
        if let first = trimmed.first, first & 0x80 != 0 { return Data([0]) + trimmed }
        return trimmed
    }
}

/// Why a key file could not be turned into a key. `message(path:)` is what the user sees.
enum OpenSSHKeyError: Error, Equatable {
    case unrecognisedFormat
    case malformed(String)
    case passphraseRequired
    case wrongPassphrase
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case unsupportedKeyType(String)
    case unsupportedEncryption(String)

    func message(path: String) -> String {
        switch self {
        case .unrecognisedFormat:
            return "\(path) is not a private key Tinker can read. It reads the OpenSSH format "
                + "ssh-keygen writes, and PEM (RSA, EC, PKCS#8)."
        case let .malformed(detail):
            return "\(path) is damaged: \(detail)."
        case .passphraseRequired:
            return "\(path) is encrypted; enter its passphrase."
        case .wrongPassphrase:
            return "The passphrase for \(path) is wrong."
        case let .unsupportedCipher(name):
            return "\(path) is encrypted with \(name), which Tinker cannot decrypt. "
                + "`ssh-keygen -p -f \(path)` re-encrypts it with aes256-ctr."
        case let .unsupportedKDF(name):
            return "\(path) uses the \(name) key derivation, which Tinker does not know."
        case let .unsupportedKeyType(type):
            return "\(path) holds \(type.hasPrefix("sk-") ? "a hardware-token (\(type))" : "a \(type)") key, "
                + "which Tinker cannot use. Use an ed25519, ECDSA or RSA key."
        case let .unsupportedEncryption(scheme):
            return "\(path) is encrypted with \(scheme), which Tinker cannot decrypt. "
                + "`ssh-keygen -p -f \(path)` rewrites it in the OpenSSH format."
        }
    }
}

// MARK: - PEM

/// One PEM block: its label, the headers OpenSSL puts above an encrypted body, and the body.
private struct PEMBlock {
    let label: String
    let headers: [String: String]
    let body: Data

    /// Nil when the text has no PEM armour at all.
    init?(text: String) throws {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") && $0.hasSuffix("-----") }) else {
            return nil
        }
        label = String(lines[begin].dropFirst("-----BEGIN ".count).dropLast("-----".count))
        var headers: [String: String] = [:]
        var base64 = ""
        for line in lines[(begin + 1)...] {
            if line.hasPrefix("-----END ") { break }
            if let colon = line.firstIndex(of: ":") {
                headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else if !line.isEmpty {
                base64 += line
            }
        }
        guard let body = Data(base64Encoded: base64) else { throw OpenSSHKeyError.malformed("the body is not base64") }
        self.headers = headers
        self.body = body
    }

    var isEncrypted: Bool { headers["Proc-Type"]?.contains("ENCRYPTED") == true }

    /// The DER inside, decrypted with OpenSSL's legacy scheme when `Proc-Type` says so:
    /// the key comes from MD5 over passphrase and salt (`EVP_BytesToKey`, one round), the
    /// salt is the first eight bytes of the IV in `DEK-Info`.
    func decryptedBody(passphrase: Data?) throws -> Data {
        guard isEncrypted else { return body }
        guard let dekInfo = headers["DEK-Info"] else { throw OpenSSHKeyError.malformed("no DEK-Info") }
        let parts = dekInfo.split(separator: ",")
        guard parts.count == 2, let iv = Data(hex: parts[1]) else { throw OpenSSHKeyError.malformed("DEK-Info \(dekInfo)") }
        let cipher = parts[0].uppercased()
        guard let scheme = AESScheme(pemName: cipher) else { throw OpenSSHKeyError.unsupportedEncryption(cipher) }
        guard iv.count == AESScheme.blockSize else { throw OpenSSHKeyError.malformed("an IV of \(iv.count) bytes") }
        guard let passphrase, !passphrase.isEmpty else { throw OpenSSHKeyError.passphraseRequired }

        var key = Data()
        var round = Data()
        while key.count < scheme.keyLength {
            round = Data(Insecure.MD5.hash(data: round + passphrase + iv.prefix(8)))
            key += round
        }
        do {
            return Data(try scheme.decrypt(Array(body), key: key.prefix(scheme.keyLength), iv: iv, padded: true))
        } catch {
            throw OpenSSHKeyError.wrongPassphrase
        }
    }
}

/// AES in the two modes key files use: CTR for OpenSSH keys, CBC for both.
private struct AESScheme {
    static let blockSize = 16

    enum Mode { case ctr, cbc }
    let keyLength: Int
    let mode: Mode

    init?(openSSHName name: String) {
        switch name {
        case "aes128-ctr": self.init(keyLength: 16, mode: .ctr)
        case "aes192-ctr": self.init(keyLength: 24, mode: .ctr)
        case "aes256-ctr": self.init(keyLength: 32, mode: .ctr)
        case "aes128-cbc": self.init(keyLength: 16, mode: .cbc)
        case "aes192-cbc": self.init(keyLength: 24, mode: .cbc)
        case "aes256-cbc": self.init(keyLength: 32, mode: .cbc)
        default: return nil
        }
    }

    init?(pemName name: String) {
        switch name {
        case "AES-128-CBC": self.init(keyLength: 16, mode: .cbc)
        case "AES-192-CBC": self.init(keyLength: 24, mode: .cbc)
        case "AES-256-CBC": self.init(keyLength: 32, mode: .cbc)
        default: return nil
        }
    }

    private init(keyLength: Int, mode: Mode) {
        self.keyLength = keyLength
        self.mode = mode
    }

    /// `padded` says whether PKCS#7 padding is to be removed: OpenSSL adds it, OpenSSH pads
    /// the private section itself with 1, 2, 3… and leaves it in place.
    func decrypt(_ ciphertext: [UInt8], key: some Sequence<UInt8>, iv: some Collection<UInt8>, padded: Bool) throws -> [UInt8] {
        let symmetricKey = SymmetricKey(data: Data(key))
        switch mode {
        case .ctr:
            return Array(try AES._CTR.decrypt(ciphertext, using: symmetricKey, nonce: try AES._CTR.Nonce(nonceBytes: iv)))
        case .cbc:
            return Array(
                try AES._CBC.decrypt(ciphertext, using: symmetricKey, iv: try AES._CBC.IV(ivBytes: iv), noPadding: !padded))
        }
    }
}

// MARK: - Binary reading

/// Reads DER elements one at a time: a tag, a length in short or long form, the contents.
private struct DERReader {
    private let bytes: Data
    private var offset: Int

    init(_ bytes: Data) {
        self.bytes = bytes
        offset = bytes.startIndex
    }

    /// The contents of the next element, which must carry `tag`.
    mutating func readElement(tag: UInt8) throws -> Data {
        guard offset < bytes.endIndex, bytes[offset] == tag else { throw OpenSSHKeyError.malformed("unexpected DER") }
        offset += 1
        guard offset < bytes.endIndex else { throw OpenSSHKeyError.malformed("truncated DER") }
        var length = Int(bytes[offset])
        offset += 1
        if length & 0x80 != 0 {
            let lengthBytes = length & 0x7F
            guard lengthBytes > 0, lengthBytes <= 4, bytes.endIndex - offset >= lengthBytes else {
                throw OpenSSHKeyError.malformed("a DER length out of range")
            }
            length = 0
            for _ in 0 ..< lengthBytes {
                length = length << 8 | Int(bytes[offset])
                offset += 1
            }
        }
        guard bytes.endIndex - offset >= length else { throw OpenSSHKeyError.malformed("truncated DER") }
        defer { offset += length }
        return bytes[offset ..< offset + length]
    }
}

/// Reads the SSH wire encodings: big-endian `uint32`, and `string` as a length-prefixed blob.
private struct SSHReader {
    private let bytes: Data
    private var offset: Int

    init(_ bytes: Data) {
        self.bytes = bytes
        offset = bytes.startIndex
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, bytes.endIndex - offset >= count else { throw OpenSSHKeyError.malformed("truncated") }
        defer { offset += count }
        return Array(bytes[offset ..< offset + count])
    }

    mutating func readUInt32() throws -> UInt32 {
        let raw = try readBytes(4)
        return UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3])
    }

    mutating func readBlob() throws -> [UInt8] {
        let length = try readUInt32()
        return try readBytes(Int(length))
    }

    mutating func readString() throws -> String {
        String(decoding: try readBlob(), as: UTF8.self)
    }
}

extension Data {
    /// Bytes from hex digits; nil when the text is not hex or has an odd length.
    fileprivate init?(hex: Substring) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
