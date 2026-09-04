import Foundation

/// The bytes of a script file, plain or gzip, a chunk at a time.
///
/// A 5 GB dump is read in one-megabyte pieces and never mapped or loaded whole, which is
/// what keeps an import's memory flat however large the file is. Compression is
/// detected from the first two bytes, so a `.sql` that is really gzip still opens.
public final class ScriptByteSource {
    public let url: URL
    /// Size of the file on disk, compressed or not: what progress is measured against.
    public let totalBytes: Int64
    public let isCompressed: Bool
    /// Bytes of the file consumed so far — compressed bytes for a `.gz`.
    public private(set) var bytesRead: Int64 = 0
    private let handle: FileHandle
    private var inflater: GzipInflater?
    private var isAtEnd = false
    private var strippedByteOrderMark = false

    public static let chunkSize = 1 << 20

    public init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        totalBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let magic = try handle.read(upToCount: 2) ?? Data()
        isCompressed = magic.count == 2 && magic[magic.startIndex] == 0x1F && magic[magic.startIndex + 1] == 0x8B
        try handle.seek(toOffset: 0)
        if isCompressed { inflater = try GzipInflater() }
    }

    deinit {
        try? handle.close()
    }

    /// The next piece of decompressed text, or nil at the end of the file.
    public func next() throws -> Data? {
        while !isAtEnd {
            guard let raw = try handle.read(upToCount: Self.chunkSize), !raw.isEmpty else {
                isAtEnd = true
                try? handle.close()
                return nil
            }
            bytesRead += Int64(raw.count)
            var chunk = try inflater?.decompress(raw) ?? raw
            if !strippedByteOrderMark {
                strippedByteOrderMark = true
                if chunk.count >= 3, chunk[chunk.startIndex] == 0xEF, chunk[chunk.startIndex + 1] == 0xBB,
                    chunk[chunk.startIndex + 2] == 0xBF
                {
                    chunk = chunk.dropFirst(3)
                }
            }
            // A gzip header alone yields nothing; keep reading rather than report an end.
            if !chunk.isEmpty { return chunk }
        }
        return nil
    }
}
