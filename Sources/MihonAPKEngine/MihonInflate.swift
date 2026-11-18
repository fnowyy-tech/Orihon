import Foundation
import Compression

// MARK: - Bounded DEFLATE

/// Raw DEFLATE (`COMPRESSION_ZLIB`) with an output ceiling. ZIP and gzip headers declare the uncompressed size,
/// but downloaded archives are untrusted: a few kilobytes can claim — or actually inflate to — gigabytes.
public enum MihonInflate {
    public enum Failure: Error, Equatable {
        case invalidStream
        case tooLarge
    }

    /// Inflates into a buffer sized from `sizeHint` (the declared size). `compression_decode_buffer` stops when
    /// the buffer is full, so output that fills it was cut off: it is retried once with room for `limit + 1`
    /// bytes, and output that fills even that is `tooLarge`.
    public static func inflate(_ input: Data, sizeHint: Int, limit: Int) throws -> Data {
        guard !input.isEmpty else { return Data() }
        var capacity = min(max(min(max(sizeHint, 0), limit) + 8192, 262_144), limit + 1)
        while true {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination in
                input.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!, input.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            guard written > 0 else { throw Failure.invalidStream }
            if written < capacity {
                output.count = written
                return output
            }
            guard capacity <= limit else { throw Failure.tooLarge }
            capacity = limit + 1
        }
    }
}
