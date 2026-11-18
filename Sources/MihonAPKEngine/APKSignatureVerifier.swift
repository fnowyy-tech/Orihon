import Foundation
import CryptoKit
import Security

// MARK: - APK Signature Scheme v2 / v3 verification
//
// What Android's package installer checks before it trusts an APK
// (https://source.android.com/docs/security/features/apksigning/v2): every signer's signature over its signed
// data, and the chunked content digest over the ZIP entries, the central directory and the end-of-central-directory
// record. A package that verifies is exactly what its signer built. Whom to trust is the caller's decision —
// upstream Mihon trusts an extension whose certificate SHA-256 equals its repo's `signingKeyFingerprint`
// (`TrustExtension.isTrusted`).

public struct APKSignatureVerification: Codable, Hashable, Sendable {
    /// Signature schemes whose blocks verified (`[2]`, `[2, 3]`, …).
    public var schemes: [Int]
    /// Lowercase hex SHA-256 of each signer's certificate (DER) — the format of a repo's `signingKeyFingerprint`.
    public var certificateFingerprints: [String]

    /// Whether one of the signers holds the key `fingerprint` names (case, `:` and spaces ignored).
    public func isSigned(by fingerprint: String) -> Bool {
        let wanted = Self.normalize(fingerprint)
        return wanted.count == 64 && certificateFingerprints.contains(wanted)
    }

    public static func normalize(_ fingerprint: String) -> String {
        fingerprint.lowercased().filter(\.isHexDigit)
    }
}

public enum APKSignatureError: Error, LocalizedError, Equatable {
    case notSigned
    case malformed(String)
    case unsupportedAlgorithm
    case invalidCertificate
    case invalidSignature
    case digestMismatch

    public var errorDescription: String? {
        switch self {
        case .notSigned: return "APK 没有 v2/v3 签名"
        case .malformed(let detail): return "APK 签名块结构异常（\(detail)）"
        case .unsupportedAlgorithm: return "APK 签名算法不受支持"
        case .invalidCertificate: return "APK 签名证书无法解析"
        case .invalidSignature: return "APK 签名与证书不符"
        case .digestMismatch: return "APK 内容与签名不一致（文件被改动过）"
        }
    }
}

public struct APKSignatureVerifier: Sendable {
    static let blockMagic = Array("APK Sig Block 42".utf8)
    static let v2BlockId: UInt32 = 0x7109_871A
    static let v3BlockId: UInt32 = 0xF053_68C0
    private static let chunkSize = 1 << 20

    public init() {}

    /// Verifies every v2 / v3 signer present; at least one scheme must be.
    public func verify(apkData: Data) throws -> APKSignatureVerification {
        let bytes = [UInt8](apkData)
        let zip = try ZipLayout(bytes)
        let block = try SigningBlock(bytes, centralDirectoryOffset: zip.centralDirectoryOffset)
        var digests = ContentDigests(bytes: bytes, signingBlockOffset: block.offset, zip: zip)
        var schemes: [Int] = []
        var fingerprints: [String] = []
        for (id, scheme) in [(Self.v2BlockId, 2), (Self.v3BlockId, 3)] {
            guard let value = block.pairs[id] else { continue }
            for fingerprint in try verifySigners(bytes, value, scheme: scheme, digests: &digests)
            where !fingerprints.contains(fingerprint) {
                fingerprints.append(fingerprint)
            }
            schemes.append(scheme)
        }
        guard !schemes.isEmpty else { throw APKSignatureError.notSigned }
        return APKSignatureVerification(schemes: schemes, certificateFingerprints: fingerprints)
    }

    /// v2: signers → [signed data, signatures, public key]; v3 adds min/max SDK after the signed data.
    private func verifySigners(_ bytes: [UInt8], _ value: Range<Int>, scheme: Int, digests: inout ContentDigests) throws -> [String] {
        var outer = ByteReader(bytes, value)
        var signers = try outer.lengthPrefixed()
        var fingerprints: [String] = []
        while !signers.isAtEnd {
            var signer = try signers.lengthPrefixed()
            let signedData = try signer.lengthPrefixed()
            if scheme == 3 { _ = try signer.uint32(); _ = try signer.uint32() }
            var signatureList = try signer.lengthPrefixed()

            var data = signedData
            var digestList = try data.lengthPrefixed()
            var certificates = try data.lengthPrefixed()
            let certificate = try certificates.lengthPrefixed()

            var offered: [(algorithm: UInt32, signature: Range<Int>)] = []
            while !signatureList.isAtEnd {
                var record = try signatureList.lengthPrefixed()
                let algorithm = try record.uint32()
                offered.append((algorithm, try record.lengthPrefixed().range))
            }
            var expectedDigests: [UInt32: Range<Int>] = [:]
            while !digestList.isAtEnd {
                var record = try digestList.lengthPrefixed()
                let algorithm = try record.uint32()
                expectedDigests[algorithm] = try record.lengthPrefixed().range
            }
            guard Set(offered.map(\.algorithm)) == Set(expectedDigests.keys) else {
                throw APKSignatureError.malformed("签名与摘要的算法列表不一致")
            }
            guard let algorithm = SignatureAlgorithm.allCases.first(where: { candidate in
                offered.contains { $0.algorithm == candidate.rawValue }
            }), let signature = offered.first(where: { $0.algorithm == algorithm.rawValue })?.signature else {
                throw APKSignatureError.unsupportedAlgorithm
            }

            // The certificate's key must have signed the signed data (which carries the digests and itself).
            let certificateData = Data(bytes[certificate.range])
            guard let secCertificate = SecCertificateCreateWithData(nil, certificateData as CFData),
                  let key = SecCertificateCopyKey(secCertificate) else {
                throw APKSignatureError.invalidCertificate
            }
            guard SecKeyIsAlgorithmSupported(key, .verify, algorithm.secKeyAlgorithm) else {
                throw APKSignatureError.unsupportedAlgorithm
            }
            var error: Unmanaged<CFError>?
            guard SecKeyVerifySignature(
                key, algorithm.secKeyAlgorithm,
                Data(bytes[signedData.range]) as CFData, Data(bytes[signature]) as CFData, &error
            ) else {
                throw APKSignatureError.invalidSignature
            }

            // …and the signed digest must be the one of the bytes we hold.
            guard let expected = expectedDigests[algorithm.rawValue],
                  Array(bytes[expected]) == digests.digest(sha512: algorithm.usesSHA512) else {
                throw APKSignatureError.digestMismatch
            }
            fingerprints.append(SHA256.hash(data: certificateData).map { String(format: "%02x", $0) }.joined())
        }
        guard !fingerprints.isEmpty else { throw APKSignatureError.malformed("没有签名者") }
        return fingerprints
    }
}

/// The algorithms Security.framework can verify, strongest first. DSA and the "verity" variants (which digest a
/// Merkle tree instead) are not supported; a signer that offers only those is rejected.
private enum SignatureAlgorithm: UInt32, CaseIterable {
    case rsaPSSSHA512 = 0x0102
    case rsaPKCS1SHA512 = 0x0104
    case ecdsaSHA512 = 0x0202
    case rsaPSSSHA256 = 0x0101
    case rsaPKCS1SHA256 = 0x0103
    case ecdsaSHA256 = 0x0201

    var secKeyAlgorithm: SecKeyAlgorithm {
        switch self {
        case .rsaPSSSHA256: return .rsaSignatureMessagePSSSHA256
        case .rsaPSSSHA512: return .rsaSignatureMessagePSSSHA512
        case .rsaPKCS1SHA256: return .rsaSignatureMessagePKCS1v15SHA256
        case .rsaPKCS1SHA512: return .rsaSignatureMessagePKCS1v15SHA512
        case .ecdsaSHA256: return .ecdsaSignatureMessageX962SHA256
        case .ecdsaSHA512: return .ecdsaSignatureMessageX962SHA512
        }
    }

    var usesSHA512: Bool {
        self == .rsaPSSSHA512 || self == .rsaPKCS1SHA512 || self == .ecdsaSHA512
    }
}

// MARK: - Layout

/// The end-of-central-directory record and the central directory it points to.
private struct ZipLayout {
    let centralDirectoryOffset: Int
    let eocdOffset: Int

    init(_ b: [UInt8]) throws {
        guard b.count >= 22 else { throw APKSignatureError.malformed("不是 ZIP 文件") }
        // The record's comment length must reach exactly the end of the file, or a match is a false positive.
        var found: Int?
        var cursor = b.count - 22
        let lowest = max(0, b.count - 22 - 0xFFFF)
        while cursor >= lowest {
            if le32(b, cursor) == 0x0605_4B50, cursor + 22 + Int(le16(b, cursor + 20)) == b.count {
                found = cursor
                break
            }
            cursor -= 1
        }
        guard let eocd = found else { throw APKSignatureError.malformed("找不到 ZIP 目录结尾") }
        let size = Int(le32(b, eocd + 12))
        let offset = Int(le32(b, eocd + 16))
        guard offset + size == eocd else { throw APKSignatureError.malformed("中央目录与目录结尾不相接") }
        centralDirectoryOffset = offset
        eocdOffset = eocd
    }
}

/// `uint64 size · (uint64 length · uint32 id · value)* · uint64 size · "APK Sig Block 42"`, right before the
/// central directory.
private struct SigningBlock {
    let offset: Int
    let pairs: [UInt32: Range<Int>]

    init(_ b: [UInt8], centralDirectoryOffset cd: Int) throws {
        guard cd >= 32, Array(b[(cd - 16)..<cd]) == APKSignatureVerifier.blockMagic else {
            throw APKSignatureError.notSigned
        }
        let size = le64(b, cd - 24)
        guard size >= 24, size <= UInt64(cd - 8) else { throw APKSignatureError.malformed("签名块大小") }
        let start = cd - Int(size) - 8
        guard le64(b, start) == size else { throw APKSignatureError.malformed("签名块首尾大小不一致") }
        var pairs: [UInt32: Range<Int>] = [:]
        var position = start + 8
        let end = cd - 24
        while position < end {
            guard end - position >= 12 else { throw APKSignatureError.malformed("签名块条目被截断") }
            let length = le64(b, position)
            guard length >= 4, length <= UInt64(end - position - 8) else { throw APKSignatureError.malformed("签名块条目长度") }
            let id = le32(b, position + 8)
            if pairs[id] == nil { pairs[id] = (position + 12)..<(position + 8 + Int(length)) }
            position += 8 + Int(length)
        }
        offset = start
        self.pairs = pairs
    }
}

/// Chunked content digests, computed once per hash and shared by every signer.
private struct ContentDigests {
    let sections: [ArraySlice<UInt8>]
    private var cache: [Bool: [UInt8]] = [:]

    init(bytes: [UInt8], signingBlockOffset: Int, zip: ZipLayout) {
        // The digested end record points the central directory at the signing block, as if the block were absent.
        var eocd = Array(bytes[zip.eocdOffset...])
        let offset = UInt32(signingBlockOffset)
        for k in 0..<4 { eocd[16 + k] = UInt8(truncatingIfNeeded: offset >> (8 * UInt32(k))) }
        sections = [bytes[0..<signingBlockOffset], bytes[zip.centralDirectoryOffset..<zip.eocdOffset], eocd[...]]
    }

    mutating func digest(sha512: Bool) -> [UInt8] {
        if let hit = cache[sha512] { return hit }
        let value = sha512 ? Self.chunked(SHA512.self, sections) : Self.chunked(SHA256.self, sections)
        cache[sha512] = value
        return value
    }

    /// Each 1 MiB chunk: H(0xa5 · uint32 length · chunk); top: H(0x5a · uint32 count · chunk digests).
    private static func chunked<H: HashFunction>(_: H.Type, _ sections: [ArraySlice<UInt8>]) -> [UInt8] {
        var chunkDigests: [UInt8] = []
        var count: UInt32 = 0
        for section in sections {
            var start = section.startIndex
            while start < section.endIndex {
                let end = min(start + (1 << 20), section.endIndex)
                var hasher = H()
                hasher.update(data: [0xA5] + littleEndian(UInt32(end - start)))
                section[start..<end].withUnsafeBytes { hasher.update(bufferPointer: $0) }
                chunkDigests += hasher.finalize()
                count += 1
                start = end
            }
        }
        var top = H()
        top.update(data: [0x5A] + littleEndian(count))
        top.update(data: chunkDigests)
        return Array(top.finalize())
    }
}

/// Bounds-checked little-endian reader over a range of the APK.
private struct ByteReader {
    let bytes: [UInt8]
    private(set) var position: Int
    let end: Int

    init(_ bytes: [UInt8], _ range: Range<Int>) {
        self.bytes = bytes
        position = range.lowerBound
        end = range.upperBound
    }

    var isAtEnd: Bool { position >= end }
    var range: Range<Int> { position..<end }

    mutating func uint32() throws -> UInt32 {
        guard end - position >= 4 else { throw APKSignatureError.malformed("数据被截断") }
        defer { position += 4 }
        return le32(bytes, position)
    }

    /// A uint32 length and that many bytes.
    mutating func lengthPrefixed() throws -> ByteReader {
        let length = Int(try uint32())
        guard length <= end - position else { throw APKSignatureError.malformed("长度超出范围") }
        defer { position += length }
        return ByteReader(bytes, position..<(position + length))
    }
}

private func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
private func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}
private func le64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32 }
private func littleEndian(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
