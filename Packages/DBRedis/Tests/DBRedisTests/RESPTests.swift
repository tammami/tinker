import Foundation
import NIOCore
import XCTest

@testable import DBRedis

/// The protocol and the text around it, without a server.
final class RESPTests: XCTestCase {
    private func decodeAll(_ text: String) throws -> [RESPValue] {
        var buffer = ByteBuffer(string: text)
        var values: [RESPValue] = []
        while let value = try RESPCodec.decode(&buffer) { values.append(value) }
        XCTAssertEqual(buffer.readableBytes, 0, "everything consumed")
        return values
    }

    func testCommandsAreArraysOfBulkStrings() {
        var buffer = ByteBuffer()
        RESPCodec.encode(["SET", "key with space", RedisArgument(Data([0, 0xFF, 13, 10]))], into: &buffer)
        XCTAssertEqual(
            Array(buffer.readableBytesView),
            Array("*3\r\n$3\r\nSET\r\n$14\r\nkey with space\r\n$4\r\n".utf8) + [0, 0xFF, 13, 10] + Array("\r\n".utf8))
    }

    func testRESP2Replies() throws {
        XCTAssertEqual(
            try decodeAll("+OK\r\n-WRONGTYPE Operation against a key\r\n:42\r\n$5\r\nhe\r\no\r\n$-1\r\n*-1\r\n"),
            [
                .simpleString("OK"), .error("WRONGTYPE Operation against a key"), .integer(42),
                .bulkString(Data("he\r\no".utf8)), .null, .null,
            ])
        let nested = try decodeAll("*2\r\n$1\r\na\r\n*2\r\n:1\r\n$0\r\n\r\n")
        XCTAssertEqual(nested, [.array([.bulkString(Data("a".utf8)), .array([.integer(1), .bulkString(Data())])])])
    }

    func testRESP3RepliesAreUnderstoodToo() throws {
        let values = try decodeAll("%1\r\n+k\r\n:1\r\n~1\r\n,3.14\r\n#t\r\n_\r\n(123456789012345678901\r\n=8\r\ntxt:abcd\r\n")
        XCTAssertEqual(values[0], .map([.simpleString("k"), .integer(1)]))
        XCTAssertEqual(values[1], .set([.double("3.14")]))
        XCTAssertEqual(values[2], .boolean(true))
        XCTAssertEqual(values[3], .null)
        XCTAssertEqual(values[4], .bigNumber("123456789012345678901"))
        XCTAssertEqual(values[5], .verbatim("abcd"))
        XCTAssertEqual(values[0].pairs.first?.0, .simpleString("k"))
    }

    /// A reply cut anywhere is "wait for more", never a wrong value.
    func testAPartialReplyWaitsForTheRest() throws {
        let whole = Array("*3\r\n$3\r\nfoo\r\n:7\r\n$-1\r\n".utf8)
        for cut in 0 ..< whole.count {
            var buffer = ByteBuffer(bytes: whole[..<cut])
            XCTAssertNil(try RESPCodec.decode(&buffer), "cut at \(cut)")
            XCTAssertEqual(buffer.readableBytes, cut, "nothing consumed at \(cut)")
        }
        var buffer = ByteBuffer(bytes: whole)
        XCTAssertEqual(
            try RESPCodec.decode(&buffer), .array([.bulkString(Data("foo".utf8)), .integer(7), .null]))
    }

    func testGarbageIsAProtocolError() {
        var buffer = ByteBuffer(string: "?what\r\n")
        XCTAssertThrowsError(try RESPCodec.decode(&buffer))
        var deep = ByteBuffer(string: String(repeating: "*1\r\n", count: 100) + ":1\r\n")
        XCTAssertThrowsError(try RESPCodec.decode(&deep), "nesting is bounded")
    }

    // MARK: - Console

    func testCommandLineSplitsLikeRedisCli() throws {
        func split(_ line: String) throws -> [String] {
            try RedisCommandLine.split(line).map { String(decoding: $0, as: UTF8.self) }
        }
        XCTAssertEqual(try split("SET  user:1   hello"), ["SET", "user:1", "hello"])
        XCTAssertEqual(try split(#"SET k "hello world\n\"quoted\"""#), ["SET", "k", "hello world\n\"quoted\""])
        XCTAssertEqual(try split("SET k 'it\\'s raw \\n'"), ["SET", "k", "it's raw \\n"])
        XCTAssertEqual(try RedisCommandLine.split(#"SET k "\x00\xff""#)[2], Data([0, 0xFF]))
        XCTAssertEqual(try split(#"HSET h "" x"#), ["HSET", "h", "", "x"])
        XCTAssertEqual(try split("   "), [])
        XCTAssertThrowsError(try split(#"SET k "unterminated"#))
    }

    func testWritesAreRecognised() {
        for command in ["set", "DEL", "HSET", "FLUSHDB", "EXPIRE", "JSON.SET", "FT.CREATE", "XADD", "EVAL", "UNKNOWNCMD"] {
            XCTAssertTrue(RedisCommandLine.isWrite(command), command)
        }
        for command in ["get", "SCAN", "HGETALL", "INFO", "JSON.GET", "FT.SEARCH", "TS.RANGE", "XRANGE", "TTL"] {
            XCTAssertFalse(RedisCommandLine.isWrite(command), command)
        }
        XCTAssertTrue(RedisCommandLine.isStreaming("subscribe"))
        XCTAssertFalse(RedisCommandLine.isStreaming("publish"))
    }

    /// Whole families are not reads: the subcommand decides, and commands that would
    /// change or hold the console's connection are refused.
    func testTheSubcommandDecides() {
        func verdict(_ line: String) -> RedisCommandLine.Verdict {
            RedisCommandLine.verdict(line.split(separator: " ").map(String.init))
        }
        XCTAssertEqual(verdict("CONFIG GET maxmemory"), .read)
        XCTAssertEqual(verdict("config set maxmemory 1mb"), .write)
        XCTAssertEqual(verdict("CLIENT LIST"), .read)
        XCTAssertEqual(verdict("CLIENT KILL ID 3"), .write)
        XCTAssertEqual(verdict("SCRIPT FLUSH"), .write)
        XCTAssertEqual(verdict("FUNCTION FLUSH"), .write)
        XCTAssertEqual(verdict("ACL WHOAMI"), .read)
        XCTAssertEqual(verdict("ACL DELUSER app"), .write)
        XCTAssertEqual(verdict("DEBUG SLEEP 60"), .write)
        XCTAssertEqual(verdict("MODULE LOAD x.so"), .write)
        XCTAssertEqual(verdict("SLOWLOG RESET"), .write)
        XCTAssertEqual(verdict("SLOWLOG GET 10"), .read)
        XCTAssertEqual(verdict("XREAD COUNT 5 STREAMS s 0"), .read)
        for refused in ["RESET", "MULTI", "EXEC", "AUTH x", "HELLO 3", "CLIENT REPLY OFF", "BLPOP q 0", "XREAD BLOCK 0 STREAMS s $", "WAIT 1 0", "SUBSCRIBE news"] {
            guard case .refused = verdict(refused) else { return XCTFail("\(refused) should be refused") }
        }
    }

    /// A length or count no server sends is refused, not trusted: no overflow trap, no
    /// giant allocation.
    func testHostileLengthsAreRefused() {
        for frame in ["$9223372036854775807\r\n", "*4611686018427387904\r\n", "%4611686018427387904\r\n", "$-5\r\n", "$999999999999\r\n"] {
            var buffer = ByteBuffer(string: frame)
            XCTAssertThrowsError(try RESPCodec.decode(&buffer), frame)
            var scanner = RESPFrameScanner()
            XCTAssertThrowsError(try scanner.scan(ByteBuffer(string: frame)), frame)
        }
    }

    /// The frame scanner finds the same boundaries the decoder does, fed a byte at a time.
    func testTheScannerResumesAcrossReads() throws {
        let frames = "*3\r\n$3\r\nfoo\r\n*2\r\n:1\r\n$-1\r\n%1\r\n+k\r\n~1\r\n#t\r\n+OK\r\n|1\r\n+ttl\r\n:3\r\n:9\r\n"
        var scanner = RESPFrameScanner()
        var buffer = ByteBuffer()
        var found: [RESPValue] = []
        for byte in Array(frames.utf8) {
            buffer.writeInteger(byte)
            while let length = try scanner.scan(buffer), var frame = buffer.readSlice(length: length) {
                found.append(try XCTUnwrap(try RESPCodec.decode(&frame)))
            }
        }
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found[1], .simpleString("OK"))
        XCTAssertEqual(found[2], .integer(9), "an attribute is followed by the reply it describes")
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    /// A million-element reply delivered in 64 KiB pieces is scanned once, not re-parsed
    /// from the start at every piece.
    func testALargeReplyIsScannedLinearly() throws {
        var whole = ByteBuffer()
        whole.writeString("*1000000\r\n")
        for index in 0 ..< 1_000_000 { whole.writeString(":\(index)\r\n") }
        var scanner = RESPFrameScanner()
        var buffer = ByteBuffer()
        let started = Date()
        var result: Int?
        while whole.readableBytes > 0, result == nil {
            var piece = whole.readSlice(length: min(65_536, whole.readableBytes))!
            buffer.writeBuffer(&piece)
            result = try scanner.scan(buffer)
        }
        XCTAssertEqual(result, buffer.readableBytes)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "quadratic re-parsing would take far longer")
    }

    func testRepliesPrintLikeRedisCli() {
        XCTAssertEqual(RedisReplyFormatter.format(.simpleString("OK")), "OK")
        XCTAssertEqual(RedisReplyFormatter.format(.integer(3)), "(integer) 3")
        XCTAssertEqual(RedisReplyFormatter.format(.null), "(nil)")
        XCTAssertEqual(RedisReplyFormatter.format(.error("ERR nope")), "(error) ERR nope")
        XCTAssertEqual(RedisReplyFormatter.format(.bulkString(Data("a\"b\n".utf8))), #""a\"b\n""#)
        XCTAssertEqual(RedisReplyFormatter.format(.bulkString(Data([0x41, 0xFF]))), #""A\xff""#)
        XCTAssertEqual(RedisReplyFormatter.format(.array([])), "(empty array)")
        XCTAssertEqual(
            RedisReplyFormatter.format(
                .array([.bulkString(Data("a".utf8)), .array([.integer(1), .integer(2)])])),
            "1) \"a\"\n2) 1) (integer) 1\n   2) (integer) 2")
        let twelve = RedisReplyFormatter.format(.array((1 ... 12).map { .integer(Int64($0)) }))
        XCTAssertTrue(twelve.hasPrefix(" 1) (integer) 1\n"), twelve)
        XCTAssertTrue(twelve.hasSuffix("12) (integer) 12"), twelve)
    }

    // MARK: - Text

    func testKeysDisplayAndParseBack() {
        XCTAssertEqual(RedisText.display(Data("user:1".utf8)), "user:1")
        XCTAssertEqual(RedisText.display(Data("kunci:é".utf8)), "kunci:é")
        let binary = Data([0x61, 0x00, 0xFF, 0x5C])
        XCTAssertEqual(RedisText.display(binary), #"a\x00\xff\\"#)
        XCTAssertEqual(RedisText.parse(RedisText.display(binary)), binary)
        XCTAssertEqual(RedisText.parse("plain:key"), Data("plain:key".utf8))
        let doubled = Data(#"C:\\tmp"#.utf8)
        XCTAssertEqual(RedisText.parse(RedisText.display(doubled)), doubled, "backslashes survive a round trip")
        XCTAssertFalse(RedisText.isText(binary))
        XCTAssertTrue(RedisText.isText(Data("line\nline".utf8)))
        XCTAssertEqual(RedisText.globEscape("a*b?[c]"), #"a\*b\?\[c\]"#)
    }

    func testInfoParses() {
        let info = RedisInfo.parse("# Server\r\nredis_version:8.10.2\r\nredis_mode:standalone\r\n\r\n# Keyspace\r\ndb0:keys=3,expires=1,avg_ttl=0\r\n")
        XCTAssertEqual(info.sections.map(\.name), ["Server", "Keyspace"])
        XCTAssertEqual(info.values["redis_version"], "8.10.2")
        XCTAssertEqual(info.values["db0"], "keys=3,expires=1,avg_ttl=0")
    }

    func testKeyTypes() {
        XCTAssertEqual(RedisKeyType(typeName: "ReJSON-RL"), .json)
        XCTAssertEqual(RedisKeyType(typeName: "zset"), .zset)
        XCTAssertEqual(RedisKeyType(typeName: "TSDB-TYPE"), .other("TSDB-TYPE"))
        XCTAssertEqual(RedisKeyType.json.scanName, "ReJSON-RL")
    }
}
