import Foundation
import zlib

/// What zlib refused, with the stage it happened at.
public struct GzipError: Error, Hashable, CustomStringConvertible, Sendable {
    public let code: Int32
    public let stage: String

    public var description: String { "gzip \(stage) failed (zlib \(code))" }
}

/// Streaming gzip compression over the zlib that ships with macOS.
///
/// A dump is pushed through in the chunks it is produced in and never held whole; the
/// output is a standard `.gz` member any tool can open.
public final class GzipDeflater {
    private var stream = z_stream()
    private var isOpen = false
    private static let outputChunk = 256 * 1_024

    /// - Parameters:
    ///   - level: zlib's 1 (fastest) to 9 (smallest); 6 is the usual balance.
    ///   - raw: a bare deflate stream with no wrapper, which is what a zip entry holds.
    public init(level: Int32 = 6, raw: Bool = false) throws {
        // Window bits 15 + 16 ask for the gzip wrapper rather than zlib's own; -15 for none.
        let status = deflateInit2_(
            &stream, level, Z_DEFLATED, raw ? -15 : 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw GzipError(code: status, stage: "deflateInit") }
        isOpen = true
    }

    deinit {
        if isOpen { deflateEnd(&stream) }
    }

    /// Compresses `input`. With `finish`, the gzip trailer is written and the stream is
    /// closed; nothing may follow.
    public func compress(_ input: Data, finish: Bool = false) throws -> Data {
        guard isOpen else { throw GzipError(code: Z_STREAM_ERROR, stage: "deflate after finish") }
        var output = Data()
        let flush = finish ? Z_FINISH : Z_NO_FLUSH
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.baseAddress?.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = UInt32(raw.count)
            var buffer = [UInt8](repeating: 0, count: Self.outputChunk)
            repeat {
                let produced = try buffer.withUnsafeMutableBufferPointer { out -> Int in
                    stream.next_out = out.baseAddress
                    stream.avail_out = UInt32(out.count)
                    let status = deflate(&stream, flush)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw GzipError(code: status, stage: "deflate")
                    }
                    return out.count - Int(stream.avail_out)
                }
                output.append(contentsOf: buffer[0 ..< produced])
            } while stream.avail_out == 0
        }
        if finish {
            deflateEnd(&stream)
            isOpen = false
        }
        return output
    }
}

/// Streaming gzip decompression. Accepts gzip and zlib wrappers alike, and files made of
/// several concatenated members, as `gzip` itself produces when files are appended.
public final class GzipInflater {
    private var stream = z_stream()
    private var isOpen = false
    /// True once the last member's trailer has been read.
    public private(set) var isFinished = false
    private static let outputChunk = 512 * 1_024

    public init() throws {
        // Window bits 15 + 32 detect the gzip or zlib wrapper automatically.
        let status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw GzipError(code: status, stage: "inflateInit") }
        isOpen = true
    }

    deinit {
        if isOpen { inflateEnd(&stream) }
    }

    /// Decompresses whatever `input` holds, which may be any slice of the file: the
    /// stream keeps its own state between calls.
    /// The most one call may produce. A 1 MiB piece of a dump inflates to a few MiB;
    /// only a crafted file inflates to gigabytes, and it is refused rather than held.
    public static let outputLimit = 64 * 1_024 * 1_024

    public func decompress(_ input: Data) throws -> Data {
        guard isOpen, !isFinished else { return Data() }
        var output = Data()
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.baseAddress?.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = UInt32(raw.count)
            var buffer = [UInt8](repeating: 0, count: Self.outputChunk)
            while stream.avail_in > 0 || stream.avail_out == 0 {
                var ended = false
                let produced = try buffer.withUnsafeMutableBufferPointer { out -> Int in
                    stream.next_out = out.baseAddress
                    stream.avail_out = UInt32(out.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    switch status {
                    case Z_OK, Z_BUF_ERROR:
                        break
                    case Z_STREAM_END:
                        ended = true
                    default:
                        throw GzipError(code: status, stage: "inflate")
                    }
                    return out.count - Int(stream.avail_out)
                }
                output.append(contentsOf: buffer[0 ..< produced])
                guard output.count <= Self.outputLimit else {
                    throw GzipError(
                        code: Z_DATA_ERROR, stage: "inflate (output over \(Self.outputLimit >> 20) MiB per piece)")
                }
                if ended {
                    if stream.avail_in > 0 {
                        // Another member follows; start it where this one ended.
                        let status = inflateReset(&stream)
                        guard status == Z_OK else { throw GzipError(code: status, stage: "inflateReset") }
                        continue
                    }
                    isFinished = true
                    break
                }
                if stream.avail_in == 0, stream.avail_out != 0 { break }
            }
        }
        return output
    }
}
