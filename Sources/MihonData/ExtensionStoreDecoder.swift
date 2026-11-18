import Foundation
import MihonDomain
import MihonAPKEngine
import zlib

// MARK: - Keiyoushi `index.pb` Extension Store Decoder (1:1 with upstream `NetworkExtensionStore`)
//
// Since Mihon 0.20.1 the Keiyoushi repo publishes its catalogue as a gzip-compressed protobuf
// (`repo.json` → `index_v2`), while `index.min.json` only contains two "update your app" stubs.

public enum ExtensionStoreDecodingError: Error, LocalizedError {
    case malformedGzip
    case malformedProtobuf
    case indexTooLarge

    public var errorDescription: String? {
        switch self {
        case .malformedGzip: return "扩展仓库索引的 gzip 数据已损坏"
        case .malformedProtobuf: return "无法解析扩展仓库索引 (protobuf)"
        case .indexTooLarge: return "扩展仓库索引解压后过大，已拒绝"
        }
    }
}

public struct KeiyoushiExtensionStore: Sendable {
    public struct Source: Sendable {
        public var id: Int64
        public var name: String
        public var language: String
        public var homeUrl: String
    }

    public struct Extension: Sendable {
        public var name: String
        public var packageName: String
        public var apkUrl: String
        public var iconUrl: String
        public var extensionLib: String
        public var versionCode: Int64
        public var versionName: String
        /// 0 = unspecified, 1 = safe, 2 = mixed, 3 = NSFW
        public var contentWarning: Int
        public var sources: [Source]

        public var isNsfw: Bool { contentWarning == 3 }

        /// 1:1 with upstream `ExtensionList.toAvailableExtensions`.
        public func toExtensionModel(repoUrl: String, storeName: String) -> ExtensionModel {
            let languages = Set(sources.map(\.language))
            let lang = languages.count == 1 ? languages.first! : "all"
            let template = MihonNetworkClient.inferMultiSrcTemplate(
                pkg: packageName,
                sourceName: name,
                baseUrl: sources.first?.homeUrl ?? ""
            )
            let descriptors = sources.enumerated().map { idx, source in
                ExtensionSourceDescriptor(
                    id: source.id,
                    name: source.name,
                    lang: source.language,
                    baseUrl: source.homeUrl,
                    isNsfw: isNsfw,
                    className: "\(packageName).Source\(idx + 1)",
                    multiSrcTemplate: template
                )
            }
            let apkName = URL(string: apkUrl)?.lastPathComponent ?? "\(packageName).apk"
            return ExtensionModel(
                name: name.replacingOccurrences(of: "Tachiyomi: ", with: ""),
                pkgName: packageName,
                versionName: versionName,
                versionCode: Int(versionCode),
                libVersion: Double(extensionLib) ?? 1.4,
                lang: lang,
                isNsfw: isNsfw,
                apkName: apkName,
                apkUrl: apkUrl,
                iconUrl: iconUrl.isEmpty ? nil : iconUrl,
                repoUrl: repoUrl,
                installState: .available,
                sources: descriptors
            )
        }
    }

    public var name: String
    public var badgeLabel: String
    public var signingKey: String
    public var extensions: [Extension]
    public var extensionListUrl: String?
}

public enum KeiyoushiExtensionStoreDecoder {
    public static func decode(_ payload: Data) throws -> KeiyoushiExtensionStore {
        let bytes = try MihonGzip.isGzip(payload) ? MihonGzip.decompress(payload) : payload
        var reader = ProtobufReader(data: bytes)
        var store = KeiyoushiExtensionStore(name: "", badgeLabel: "", signingKey: "", extensions: [], extensionListUrl: nil)
        while let field = try reader.nextField() {
            switch (field.number, field.value) {
            case (1, .bytes(let d)): store.name = String(decoding: d, as: UTF8.self)
            case (2, .bytes(let d)): store.badgeLabel = String(decoding: d, as: UTF8.self)
            case (3, .bytes(let d)): store.signingKey = String(decoding: d, as: UTF8.self)
            case (101, .bytes(let d)): store.extensions = try decodeExtensionList(d)
            case (102, .bytes(let d)): store.extensionListUrl = String(decoding: d, as: UTF8.self)
            default: break
            }
        }
        return store
    }

    /// Decodes a standalone `ExtensionList` message (served when a store sets `extensionListUrl`).
    public static func decodeExtensionList(_ data: Data) throws -> [KeiyoushiExtensionStore.Extension] {
        let bytes = try MihonGzip.isGzip(data) ? MihonGzip.decompress(data) : data
        var reader = ProtobufReader(data: bytes)
        var result: [KeiyoushiExtensionStore.Extension] = []
        result.reserveCapacity(1500)
        while let field = try reader.nextField() {
            if field.number == 1, case .bytes(let d) = field.value {
                result.append(try decodeExtension(d))
            }
        }
        return result
    }

    private static func decodeExtension(_ data: Data) throws -> KeiyoushiExtensionStore.Extension {
        var ext = KeiyoushiExtensionStore.Extension(
            name: "", packageName: "", apkUrl: "", iconUrl: "", extensionLib: "1.4",
            versionCode: 0, versionName: "", contentWarning: 0, sources: []
        )
        var reader = ProtobufReader(data: data)
        while let field = try reader.nextField() {
            switch (field.number, field.value) {
            case (1, .bytes(let d)): ext.name = String(decoding: d, as: UTF8.self)
            case (2, .bytes(let d)): ext.packageName = String(decoding: d, as: UTF8.self)
            case (3, .bytes(let d)):
                var res = ProtobufReader(data: d)
                while let r = try res.nextField() {
                    switch (r.number, r.value) {
                    case (1, .bytes(let v)): ext.apkUrl = String(decoding: v, as: UTF8.self)
                    case (2, .bytes(let v)): ext.iconUrl = String(decoding: v, as: UTF8.self)
                    default: break
                    }
                }
            case (4, .bytes(let d)): ext.extensionLib = String(decoding: d, as: UTF8.self)
            case (5, .varint(let v)): ext.versionCode = Int64(bitPattern: v)
            case (6, .bytes(let d)): ext.versionName = String(decoding: d, as: UTF8.self)
            case (7, .varint(let v)): ext.contentWarning = Int(truncatingIfNeeded: v)
            case (8, .bytes(let d)): ext.sources.append(try decodeSource(d))
            default: break
            }
        }
        return ext
    }

    private static func decodeSource(_ data: Data) throws -> KeiyoushiExtensionStore.Source {
        var source = KeiyoushiExtensionStore.Source(id: 0, name: "", language: "", homeUrl: "")
        var reader = ProtobufReader(data: data)
        while let field = try reader.nextField() {
            switch (field.number, field.value) {
            case (1, .varint(let v)): source.id = Int64(bitPattern: v)
            case (2, .bytes(let d)): source.name = String(decoding: d, as: UTF8.self)
            case (3, .bytes(let d)): source.language = String(decoding: d, as: UTF8.self)
            case (4, .bytes(let d)): source.homeUrl = String(decoding: d, as: UTF8.self)
            default: break
            }
        }
        return source
    }
}

// MARK: - Minimal protobuf wire-format reader

struct ProtobufReader {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    struct Field {
        let number: Int
        let value: Value
    }

    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) {
        self.bytes = [UInt8](data)
    }

    mutating func nextField() throws -> Field? {
        guard offset < bytes.count else { return nil }
        let key = try readVarint()
        let number = Int(key >> 3)
        // Field 0 does not exist (upstream's reader rejects it too); a run of zero bytes would otherwise parse.
        guard number > 0 else { throw ExtensionStoreDecodingError.malformedProtobuf }
        switch key & 0x7 {
        case 0:
            return Field(number: number, value: .varint(try readVarint()))
        case 1:
            guard offset + 8 <= bytes.count else { throw ExtensionStoreDecodingError.malformedProtobuf }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
            offset += 8
            return Field(number: number, value: .fixed64(v))
        case 2:
            // Checked as UInt64 first: a length near 2⁶⁴ must not trap on the conversion or overflow the sum.
            let raw = try readVarint()
            guard raw <= UInt64(bytes.count - offset) else { throw ExtensionStoreDecodingError.malformedProtobuf }
            let length = Int(raw)
            let slice = Data(bytes[offset..<(offset + length)])
            offset += length
            return Field(number: number, value: .bytes(slice))
        case 5:
            guard offset + 4 <= bytes.count else { throw ExtensionStoreDecodingError.malformedProtobuf }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * UInt32(i)) }
            offset += 4
            return Field(number: number, value: .fixed32(v))
        default:
            throw ExtensionStoreDecodingError.malformedProtobuf
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
            if shift > 63 { break }
        }
        throw ExtensionStoreDecodingError.malformedProtobuf
    }
}

// MARK: - gzip (RFC 1952) container → raw DEFLATE via Apple's Compression framework

public enum MihonGzip {
    public static func isGzip(_ data: Data) -> Bool {
        data.count > 18 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    public static func decompress(_ data: Data, limit: Int = maxDecompressedSize) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw ExtensionStoreDecodingError.malformedGzip
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else { throw ExtensionStoreDecodingError.malformedGzip }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < bytes.count - 8 else { throw ExtensionStoreDecodingError.malformedGzip }

        let trailer = bytes.count - 4
        // ISIZE: the uncompressed size modulo 2³², declared by the (untrusted) sender — only a buffer size hint.
        let declaredSize = Int(bytes[trailer]) | Int(bytes[trailer + 1]) << 8 | Int(bytes[trailer + 2]) << 16 | Int(bytes[trailer + 3]) << 24
        do {
            return try MihonInflate.inflate(
                Data(bytes[offset..<(bytes.count - 8)]),
                sizeHint: max(declaredSize, bytes.count * 8),
                limit: limit
            )
        } catch MihonInflate.Failure.tooLarge {
            throw ExtensionStoreDecodingError.indexTooLarge
        } catch {
            throw ExtensionStoreDecodingError.malformedGzip
        }
    }

    /// Keiyoushi's index inflates to a few megabytes.
    public static let maxDecompressedSize = 64 << 20

    /// gzip around raw DEFLATE, as upstream writes `.tachibk` (okio `gzip()`): no name, no time, CRC-32 and size
    /// at the end.
    public static func compress(_ data: Data) -> Data {
        // An empty final stored block when there is nothing to compress.
        let deflated = data.isEmpty ? Data([0x03, 0x00]) : (try? (data as NSData).compressed(using: .zlib) as Data) ?? stored(data)
        var gzip = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
        gzip.append(deflated)
        let checksum = data.withUnsafeBytes { bytes in
            UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
        }
        withUnsafeBytes(of: checksum.littleEndian) { gzip.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).littleEndian) { gzip.append(contentsOf: $0) }
        return gzip
    }

    /// DEFLATE's stored blocks (no compression), should the compressor fail.
    static func stored(_ data: Data) -> Data {
        var output = Data()
        var offset = data.startIndex
        repeat {
            let length = min(0xFFFF, data.endIndex - offset)
            let isLast = offset + length == data.endIndex
            output.append(isLast ? 1 : 0)
            withUnsafeBytes(of: UInt16(length).littleEndian) { output.append(contentsOf: $0) }
            withUnsafeBytes(of: (~UInt16(length)).littleEndian) { output.append(contentsOf: $0) }
            output.append(data[offset..<(offset + length)])
            offset += length
        } while offset < data.endIndex
        return output
    }
}
