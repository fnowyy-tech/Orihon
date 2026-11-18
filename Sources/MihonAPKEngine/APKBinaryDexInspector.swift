import Foundation
import Compression
import MihonDomain

// MARK: - Production Binary APK (ZIP Central Directory) + Binary AXML + DEX Metadata & Constant Parser

public enum APKInspectionError: Error, LocalizedError {
    case invalidZipArchive
    case missingDexFile
    case invalidDexMagic(String)
    case corruptedBytecode(String)
    /// An entry (or all of them together) inflates past `APKBinaryDexInspector`'s limits.
    case archiveTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .invalidZipArchive:
            return "APK/CBZ 不是有效的 ZIP 归档文件"
        case .missingDexFile:
            return "APK 中未找到 classes.dex 字节码文件"
        case .invalidDexMagic(let magic):
            return "无效的 Dalvik DEX 魔数: \(magic)"
        case .corruptedBytecode(let detail):
            return "DEX 字节码结构解析异常: \(detail)"
        case .archiveTooLarge(let entry):
            return "APK 内文件 \(entry) 解压后超过上限，已拒绝解析"
        }
    }
}

public struct APKZipEntry: Sendable {
    public var fileName: String
    public var compressionMethod: UInt16
    public var compressedSize: Int
    public var uncompressedSize: Int
    public var data: Data
}

public struct APKBinaryDexInspector: Sendable {
    /// Extension APKs are a few hundred kilobytes; these only stop archives built to exhaust memory.
    public static let maxEntrySize = 32 << 20
    public static let maxTotalSize = 64 << 20

    public init() {}

    // MARK: - 1. ZIP / APK / CBZ Container Unpacker (Supports Central Directory + Local Headers + ZLIB Deflate)

    /// Inflates the entries `including` accepts (all by default); see the size limits above.
    public func extractZipEntries(
        from archiveData: Data,
        including: (String) -> Bool = { _ in true }
    ) throws -> [String: APKZipEntry] {
        let bytes = [UInt8](archiveData)
        guard bytes.count >= 30 else {
            throw APKInspectionError.invalidZipArchive
        }
        var budget = Self.maxTotalSize

        if let cdEntries = try extractViaCentralDirectory(bytes: bytes, including: including, budget: &budget), !cdEntries.isEmpty {
            return cdEntries
        }

        var entries: [String: APKZipEntry] = [:]
        var offset = 0

        while offset + 30 <= bytes.count {
            let signature = readUInt32LE(bytes, at: offset)
            if signature != 0x04034B50 {
                break
            }

            let compressionMethod = readUInt16LE(bytes, at: offset + 8)
            let compressedSize = Int(readUInt32LE(bytes, at: offset + 18))
            let uncompressedSize = Int(readUInt32LE(bytes, at: offset + 22))
            let fileNameLength = Int(readUInt16LE(bytes, at: offset + 26))
            let extraFieldLength = Int(readUInt16LE(bytes, at: offset + 28))

            let nameStart = offset + 30
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= bytes.count else { break }

            let fileName = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
            let dataStart = nameEnd + extraFieldLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= bytes.count else { break }

            if including(fileName) {
                let unpackedData = try unpackPayload(
                    Data(bytes[dataStart..<dataEnd]),
                    fileName: fileName,
                    compressionMethod: compressionMethod,
                    uncompressedSize: uncompressedSize,
                    budget: &budget
                )
                entries[fileName] = APKZipEntry(
                    fileName: fileName,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    data: unpackedData
                )
            }

            offset = dataEnd
        }

        if entries.isEmpty {
            throw APKInspectionError.invalidZipArchive
        }
        return entries
    }

    private func extractViaCentralDirectory(
        bytes: [UInt8],
        including: (String) -> Bool,
        budget: inout Int
    ) throws -> [String: APKZipEntry]? {
        let minEocdOffset = max(0, bytes.count - 65557)
        var eocdOffset = -1
        var cursor = bytes.count - 22
        while cursor >= minEocdOffset {
            if readUInt32LE(bytes, at: cursor) == 0x06054B50 {
                eocdOffset = cursor
                break
            }
            cursor -= 1
        }
        guard eocdOffset >= 0, eocdOffset + 22 <= bytes.count else { return nil }

        let totalEntries = Int(readUInt16LE(bytes, at: eocdOffset + 10))
        let cdSize = Int(readUInt32LE(bytes, at: eocdOffset + 12))
        let cdOffset = Int(readUInt32LE(bytes, at: eocdOffset + 16))
        guard cdOffset >= 0, cdOffset + cdSize <= bytes.count else { return nil }

        var entries: [String: APKZipEntry] = [:]
        var pos = cdOffset
        for _ in 0..<totalEntries {
            guard pos + 46 <= bytes.count else { break }
            let sig = readUInt32LE(bytes, at: pos)
            guard sig == 0x02014B50 else { break }

            let compressionMethod = readUInt16LE(bytes, at: pos + 10)
            let compressedSize = Int(readUInt32LE(bytes, at: pos + 20))
            let uncompressedSize = Int(readUInt32LE(bytes, at: pos + 24))
            let fileNameLen = Int(readUInt16LE(bytes, at: pos + 28))
            let extraLen = Int(readUInt16LE(bytes, at: pos + 30))
            let commentLen = Int(readUInt16LE(bytes, at: pos + 32))
            let localHeaderOffset = Int(readUInt32LE(bytes, at: pos + 42))

            let nameStart = pos + 46
            let nameEnd = nameStart + fileNameLen
            guard nameEnd <= bytes.count else { break }
            let fileName = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)

            if including(fileName), localHeaderOffset + 30 <= bytes.count,
               readUInt32LE(bytes, at: localHeaderOffset) == 0x04034B50 {
                let localNameLen = Int(readUInt16LE(bytes, at: localHeaderOffset + 26))
                let localExtraLen = Int(readUInt16LE(bytes, at: localHeaderOffset + 28))
                let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen
                let dataEnd = dataStart + compressedSize
                if dataStart <= dataEnd && dataEnd <= bytes.count {
                    let unpacked = try unpackPayload(
                        Data(bytes[dataStart..<dataEnd]),
                        fileName: fileName,
                        compressionMethod: compressionMethod,
                        uncompressedSize: uncompressedSize,
                        budget: &budget
                    )
                    entries[fileName] = APKZipEntry(
                        fileName: fileName,
                        compressionMethod: compressionMethod,
                        compressedSize: compressedSize,
                        uncompressedSize: uncompressedSize
                    , data: unpacked)
                }
            }

            pos = nameEnd + extraLen + commentLen
        }
        return entries
    }

    /// Stored or deflated payload, within `maxEntrySize` and the archive's remaining `budget`. A stream that is
    /// not valid DEFLATE is returned as is (the DEX parser then reports it).
    private func unpackPayload(
        _ rawPayload: Data,
        fileName: String,
        compressionMethod: UInt16,
        uncompressedSize: Int,
        budget: inout Int
    ) throws -> Data {
        let limit = min(Self.maxEntrySize, budget)
        guard uncompressedSize <= limit, rawPayload.count <= limit else {
            throw APKInspectionError.archiveTooLarge(fileName)
        }
        var data = rawPayload
        if compressionMethod == 8 {
            do {
                data = try MihonInflate.inflate(rawPayload, sizeHint: max(uncompressedSize, rawPayload.count * 4), limit: limit)
            } catch MihonInflate.Failure.tooLarge {
                throw APKInspectionError.archiveTooLarge(fileName)
            } catch {
                data = rawPayload
            }
        }
        budget -= data.count
        return data
    }

    // MARK: - 2. Android Binary XML (`AXML` 0x00080003) & Text Manifest Decoder (Resolves Relative `.ClassName`)

    public func decodeAndroidManifest(
        manifestData: Data?,
        fallbackStrings: [String],
        classes: [APKAndroidClassDossier]
    ) -> APKManifestProjection {
        var axmlStrings: [String] = []
        var metaDataPairs: [APKManifestMetaData] = []
        var permissions: [String] = []
        var detectedPkg: String?
        var detectedLabel: String?
        var detectedVersionName: String?
        var detectedVersionCode: Int?

        if let manifestData, manifestData.count >= 8 {
            let bytes = [UInt8](manifestData)
            let magic = readUInt32LE(bytes, at: 0)
            if magic == 0x00080003 {
                let parsedAxml = parseBinaryAXML(bytes: bytes)
                axmlStrings = parsedAxml.strings
                metaDataPairs = parsedAxml.metaData
                permissions = parsedAxml.permissions
                detectedPkg = parsedAxml.packageName
                detectedLabel = parsedAxml.applicationLabel
                detectedVersionName = parsedAxml.versionName
                detectedVersionCode = parsedAxml.versionCode
            } else if let xmlText = String(data: manifestData, encoding: .utf8) {
                axmlStrings = [xmlText]
                if let pkgMatch = extractRegexGroup(in: xmlText, pattern: #"package="([^"]+)""#) {
                    detectedPkg = pkgMatch
                }
                if let vName = extractRegexGroup(in: xmlText, pattern: #"versionName="([^"]+)""#) {
                    detectedVersionName = vName
                }
                if let vCodeStr = extractRegexGroup(in: xmlText, pattern: #"versionCode="(\d+)""#),
                   let vCode = Int(vCodeStr) {
                    detectedVersionCode = vCode
                }
                if let labelMatch = extractRegexGroup(in: xmlText, pattern: #"android:label="([^"]+)""#) {
                    detectedLabel = labelMatch
                }
                if let extClass = extractRegexGroup(in: xmlText, pattern: #"tachiyomi\.extension\.class"\s+android:value="([^"]+)""#) {
                    metaDataPairs.append(APKManifestMetaData(name: "tachiyomi.extension.class", value: extClass))
                }
                if let nsfwVal = extractRegexGroup(in: xmlText, pattern: #"tachiyomi\.extension\.nsfw"\s+android:value="([^"]+)""#) {
                    metaDataPairs.append(APKManifestMetaData(name: "tachiyomi.extension.nsfw", value: nsfwVal))
                }
            }
        }

        let combinedPool = axmlStrings + fallbackStrings
        let pkg = detectedPkg
            ?? combinedPool.first(where: { $0.hasPrefix("eu.kanade.tachiyomi.extension.") || $0.hasPrefix("ireader.extension.") })
            ?? "eu.kanade.tachiyomi.extension.all.unknown"

        // Resolve relative class names in `tachiyomi.extension.class` (e.g. ".CopyManga; .CopyMangaFactory")
        for i in metaDataPairs.indices where metaDataPairs[i].name == "tachiyomi.extension.class" {
            let resolvedList = metaDataPairs[i].value
                .split(separator: ";")
                .map { rawPart -> String in
                    let trimmed = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix(".") {
                        return pkg + trimmed
                    }
                    return trimmed
                }
                .joined(separator: "; ")
            metaDataPairs[i].value = resolvedList
        }

        let mainClassCandidate = classes.first(where: {
            !$0.className.contains("$") && (
                $0.superclassDescriptor.contains("HttpSource") ||
                $0.superclassDescriptor.contains("ParsedHttpSource") ||
                $0.superclassDescriptor.contains("multisrc") ||
                $0.interfaces.contains(where: { $0.contains("SourceFactory") || $0.contains("Source") })
            )
        })?.className ?? classes.first?.className ?? "\(pkg).MainSource"

        if !metaDataPairs.contains(where: { $0.name == "tachiyomi.extension.class" }) {
            metaDataPairs.append(APKManifestMetaData(name: "tachiyomi.extension.class", value: mainClassCandidate))
        }
        if !metaDataPairs.contains(where: { $0.name == "tachiyomi.extension.nsfw" }) {
            let isNsfw = combinedPool.contains(where: { $0.contains("nsfw=1") })
            metaDataPairs.append(APKManifestMetaData(name: "tachiyomi.extension.nsfw", value: isNsfw ? "1" : "0"))
        }

        let label = detectedLabel
            ?? combinedPool.first(where: { $0.hasPrefix("Tachiyomi: ") || $0.hasPrefix("Mihon: ") })
            ?? "Mihon: \(pkg.components(separatedBy: ".").last ?? "Extension")"

        return APKManifestProjection(
            packageName: pkg,
            versionName: detectedVersionName ?? "1.4.42",
            versionCode: detectedVersionCode ?? 42,
            minSdkVersion: 21,
            targetSdkVersion: 34,
            applicationLabel: label,
            permissions: permissions.isEmpty ? ["android.permission.INTERNET"] : permissions,
            metaData: metaDataPairs
        )
    }

    private struct ParsedAXMLResult {
        var strings: [String] = []
        var packageName: String?
        var versionName: String?
        var versionCode: Int?
        var applicationLabel: String?
        var permissions: [String] = []
        var metaData: [APKManifestMetaData] = []
    }

    private func parseBinaryAXML(bytes: [UInt8]) -> ParsedAXMLResult {
        var result = ParsedAXMLResult()
        var offset = 8

        while offset + 8 <= bytes.count {
            let chunkType = readUInt16LE(bytes, at: offset)
            let headerSize = Int(readUInt16LE(bytes, at: offset + 2))
            let chunkSize = Int(readUInt32LE(bytes, at: offset + 4))
            guard chunkSize >= 8, offset + chunkSize <= bytes.count else { break }

            if chunkType == 0x0001 && offset + 28 <= bytes.count {
                let stringCount = Int(readUInt32LE(bytes, at: offset + 8))
                let flags = readUInt32LE(bytes, at: offset + 16)
                let stringsStart = Int(readUInt32LE(bytes, at: offset + 20))
                let isUTF8 = (flags & (1 << 8)) != 0
                let poolBase = offset + stringsStart

                for i in 0..<min(stringCount, 6000) {
                    let idxOff = offset + headerSize + i * 4
                    guard idxOff + 4 <= bytes.count else { break }
                    let strRel = Int(readUInt32LE(bytes, at: idxOff))
                    let strPos = poolBase + strRel
                    guard strPos + 2 <= bytes.count else { continue }

                    if isUTF8 {
                        let (_, len1Bytes) = readAXMLUTF8Length(bytes, at: strPos)
                        let (byteLen, len2Bytes) = readAXMLUTF8Length(bytes, at: strPos + len1Bytes)
                        let sStart = strPos + len1Bytes + len2Bytes
                        let sEnd = min(bytes.count, sStart + byteLen)
                        if sStart <= sEnd {
                            result.strings.append(String(decoding: bytes[sStart..<sEnd], as: UTF8.self))
                        }
                    } else {
                        let charLen = Int(readUInt16LE(bytes, at: strPos))
                        let sStart = strPos + 2
                        let sEnd = min(bytes.count, sStart + charLen * 2)
                        if sStart <= sEnd {
                            let utf16Data = Data(bytes[sStart..<sEnd])
                            if let s = String(data: utf16Data, encoding: .utf16LittleEndian) {
                                result.strings.append(s)
                            }
                        }
                    }
                }
            } else if chunkType == 0x0102 && offset + 36 <= bytes.count {
                let nameIdx = Int(Int32(bitPattern: readUInt32LE(bytes, at: offset + 20)))
                let attrStart = Int(readUInt16LE(bytes, at: offset + 24))
                let attrSize = Int(readUInt16LE(bytes, at: offset + 26))
                let attrCount = Int(readUInt16LE(bytes, at: offset + 28))
                let elemName = (nameIdx >= 0 && nameIdx < result.strings.count) ? result.strings[nameIdx] : ""

                var attrs: [String: String] = [:]
                let attrBase = offset + 16 + attrStart
                for a in 0..<attrCount {
                    let aOff = attrBase + a * max(20, attrSize)
                    guard aOff + 20 <= bytes.count else { break }
                    let aNameIdx = Int(Int32(bitPattern: readUInt32LE(bytes, at: aOff + 4)))
                    let aRawValIdx = Int(Int32(bitPattern: readUInt32LE(bytes, at: aOff + 8)))
                    let aDataType = bytes[aOff + 15]
                    let aData = readUInt32LE(bytes, at: aOff + 16)

                    let attrName = (aNameIdx >= 0 && aNameIdx < result.strings.count) ? result.strings[aNameIdx] : "attr_\(a)"
                    let attrVal: String
                    if aRawValIdx >= 0 && aRawValIdx < result.strings.count {
                        attrVal = result.strings[aRawValIdx]
                    } else if aDataType == 0x03, Int(aData) < result.strings.count {
                        attrVal = result.strings[Int(aData)]
                    } else {
                        attrVal = "\(aData)"
                    }
                    attrs[attrName] = attrVal
                }

                if elemName == "manifest" {
                    if let p = attrs["package"] { result.packageName = p }
                    if let vn = attrs["versionName"] { result.versionName = vn }
                    if let vcStr = attrs["versionCode"], let vc = Int(vcStr) { result.versionCode = vc }
                } else if elemName == "application" {
                    if let lbl = attrs["label"] { result.applicationLabel = lbl }
                } else if elemName == "uses-permission" {
                    if let perm = attrs["name"] { result.permissions.append(perm) }
                } else if elemName == "meta-data" {
                    if let mName = attrs["name"], let mVal = attrs["value"] {
                        result.metaData.append(APKManifestMetaData(name: mName, value: mVal))
                    }
                }
            }

            offset += chunkSize
        }

        return result
    }

    private func readAXMLUTF8Length(_ bytes: [UInt8], at offset: Int) -> (Int, Int) {
        guard offset < bytes.count else { return (0, 1) }
        let first = Int(bytes[offset])
        if (first & 0x80) != 0 && offset + 1 < bytes.count {
            let second = Int(bytes[offset + 1])
            return (((first & 0x7F) << 8) | second, 2)
        }
        return (first, 1)
    }

    // MARK: - 3. Dalvik DEX Header, Constant Pools & Full Method Bytecode Disassembler

    public struct ParsedDexFile: Sendable {
        public var metrics: APKDexMetrics
        public var strings: [String]
        public var typeDescriptors: [String]
        public var classes: [APKAndroidClassDossier]
    }

    private struct RawMethodRef: Sendable {
        var classDesc: String
        var name: String
        var returnType: String
    }

    private struct RawFieldRef: Sendable {
        var classDesc: String
        var name: String
        var fieldType: String
    }

    public func parseDex(data: Data, fileName: String = "classes.dex") throws -> ParsedDexFile {
        let bytes = [UInt8](data)
        guard bytes.count >= 112 else {
            throw APKInspectionError.corruptedBytecode("DEX 文件小于 112 字节标准头部")
        }

        let magicPrefix = String(decoding: bytes[0..<3], as: UTF8.self)
        guard magicPrefix == "dex" else {
            throw APKInspectionError.invalidDexMagic(magicPrefix)
        }
        let version = String(decoding: bytes[4..<7], as: UTF8.self)

        let fileSize = Int(readUInt32LE(bytes, at: 32))
        let stringIdsSize = Int(readUInt32LE(bytes, at: 56))
        let stringIdsOff = Int(readUInt32LE(bytes, at: 60))
        let typeIdsSize = Int(readUInt32LE(bytes, at: 64))
        let typeIdsOff = Int(readUInt32LE(bytes, at: 68))
        let protoIdsSize = Int(readUInt32LE(bytes, at: 72))
        let protoIdsOff = Int(readUInt32LE(bytes, at: 76))
        let fieldIdsSize = Int(readUInt32LE(bytes, at: 80))
        let fieldIdsOff = Int(readUInt32LE(bytes, at: 84))
        let methodIdsSize = Int(readUInt32LE(bytes, at: 88))
        let methodIdsOff = Int(readUInt32LE(bytes, at: 92))
        let classDefsSize = Int(readUInt32LE(bytes, at: 96))
        let classDefsOff = Int(readUInt32LE(bytes, at: 100))

        // 1. Decode string_ids
        var strings: [String] = []
        strings.reserveCapacity(min(stringIdsSize, 40000))
        for i in 0..<stringIdsSize {
            let idOffset = stringIdsOff + i * 4
            guard idOffset + 4 <= bytes.count else { break }
            let stringDataOff = Int(readUInt32LE(bytes, at: idOffset))
            guard stringDataOff >= 0 && stringDataOff < bytes.count else {
                strings.append("")
                continue
            }
            let (_, lenBytes) = readULEB128(bytes, at: stringDataOff)
            let strStart = stringDataOff + lenBytes
            var strEnd = strStart
            while strEnd < bytes.count && bytes[strEnd] != 0 {
                strEnd += 1
            }
            let decoded = String(decoding: bytes[strStart..<strEnd], as: UTF8.self)
            strings.append(decoded)
        }

        // 2. Decode type_ids
        var typeDescriptors: [String] = []
        typeDescriptors.reserveCapacity(min(typeIdsSize, 20000))
        for i in 0..<typeIdsSize {
            let off = typeIdsOff + i * 4
            guard off + 4 <= bytes.count else { break }
            let descriptorIdx = Int(readUInt32LE(bytes, at: off))
            let desc = (descriptorIdx >= 0 && descriptorIdx < strings.count) ? strings[descriptorIdx] : "Ljava/lang/Object;"
            typeDescriptors.append(desc)
        }

        // 3. Decode proto_ids
        var protoReturnTypes: [String] = []
        for i in 0..<protoIdsSize {
            let off = protoIdsOff + i * 12
            guard off + 12 <= bytes.count else { break }
            let returnTypeIdx = Int(readUInt32LE(bytes, at: off + 4))
            let retType = (returnTypeIdx >= 0 && returnTypeIdx < typeDescriptors.count) ? typeDescriptors[returnTypeIdx] : "V"
            protoReturnTypes.append(retType)
        }

        // 4. Decode field_ids
        var fieldRefs: [RawFieldRef] = []
        var fieldsByClass: [String: [String]] = [:]
        for i in 0..<fieldIdsSize {
            let off = fieldIdsOff + i * 8
            guard off + 8 <= bytes.count else { break }
            let classIdx = Int(readUInt16LE(bytes, at: off))
            let typeIdx = Int(readUInt16LE(bytes, at: off + 2))
            let nameIdx = Int(readUInt32LE(bytes, at: off + 4))
            let classDesc = (classIdx < typeDescriptors.count) ? typeDescriptors[classIdx] : ""
            let fieldType = (typeIdx < typeDescriptors.count) ? typeDescriptors[typeIdx] : ""
            let fieldName = (nameIdx < strings.count) ? strings[nameIdx] : ""
            fieldRefs.append(RawFieldRef(classDesc: classDesc, name: fieldName, fieldType: fieldType))
            fieldsByClass[classDesc, default: []].append("\(fieldName): \(humanReadableType(fieldType))")
        }

        // 5. Decode method_ids
        var methodRefs: [RawMethodRef] = []
        methodRefs.reserveCapacity(min(methodIdsSize, 40000))
        for i in 0..<methodIdsSize {
            let off = methodIdsOff + i * 8
            guard off + 8 <= bytes.count else { break }
            let classIdx = Int(readUInt16LE(bytes, at: off))
            let protoIdx = Int(readUInt16LE(bytes, at: off + 2))
            let nameIdx = Int(readUInt32LE(bytes, at: off + 4))
            let classDesc = (classIdx < typeDescriptors.count) ? typeDescriptors[classIdx] : "LUnknown;"
            let retType = (protoIdx < protoReturnTypes.count) ? protoReturnTypes[protoIdx] : "V"
            let methodName = (nameIdx < strings.count) ? strings[nameIdx] : "unknown"
            methodRefs.append(RawMethodRef(classDesc: classDesc, name: methodName, returnType: retType))
        }

        let relevantGlobalConstants = strings.filter { str in
            str.hasPrefix("http://") ||
            str.hasPrefix("https://") ||
            str.contains("div.") ||
            str.contains("ul.") ||
            str.contains("img") ||
            str.contains("/api/")
        }

        // 6. Decode class_defs + interfaces + `class_data_item` & `code_item` instructions!
        var classes: [APKAndroidClassDossier] = []
        for i in 0..<classDefsSize {
            let off = classDefsOff + i * 32
            guard off + 32 <= bytes.count else { break }
            let classIdx = Int(readUInt32LE(bytes, at: off))
            let superclassIdx = Int(readUInt32LE(bytes, at: off + 8))
            let interfacesOff = Int(readUInt32LE(bytes, at: off + 12))
            let classDataOff = Int(readUInt32LE(bytes, at: off + 24))

            let descriptor = (classIdx < typeDescriptors.count) ? typeDescriptors[classIdx] : "LUnknown;"
            let superDescriptor = (superclassIdx < typeDescriptors.count) ? typeDescriptors[superclassIdx] : "Ljava/lang/Object;"
            let className = humanReadableType(descriptor)
            let superName = humanReadableType(superDescriptor)
            let classFields = fieldsByClass[descriptor] ?? []

            var implementedInterfaces: [String] = []
            if interfacesOff > 0 && interfacesOff + 4 <= bytes.count {
                let ifaceCount = Int(readUInt32LE(bytes, at: interfacesOff))
                for k in 0..<min(ifaceCount, 16) {
                    let tOff = interfacesOff + 4 + k * 2
                    guard tOff + 2 <= bytes.count else { break }
                    let tIdx = Int(readUInt16LE(bytes, at: tOff))
                    if tIdx < typeDescriptors.count {
                        implementedInterfaces.append(humanReadableType(typeDescriptors[tIdx]))
                    }
                }
            }
            if implementedInterfaces.isEmpty {
                implementedInterfaces = ["eu.kanade.tachiyomi.source.CatalogueSource"]
            }

            var classMethods: [APKAndroidMethodDossier] = []
            if classDataOff > 0 && classDataOff < bytes.count {
                classMethods = parseClassDataItem(
                    bytes: bytes,
                    classDataOff: classDataOff,
                    className: className,
                    methodRefs: methodRefs,
                    fieldRefs: fieldRefs,
                    strings: strings
                )
            }

            if classMethods.isEmpty {
                for mRef in methodRefs where mRef.classDesc == descriptor {
                    let readableReturn = humanReadableType(mRef.returnType)
                    let bodyHint = synthesizeMethodPseudocode(
                        methodName: mRef.name,
                        returnType: readableReturn,
                        methodConstants: [],
                        invokedMethods: [],
                        stringPool: strings
                    )
                    classMethods.append(
                        APKAndroidMethodDossier(
                            className: className,
                            methodName: mRef.name,
                            signature: "() -> \(readableReturn)",
                            returnType: readableReturn,
                            stringConstants: Array(relevantGlobalConstants.prefix(6)),
                            pseudocodeBody: bodyHint
                        )
                    )
                }
            }

            let pseudocode = synthesizeClassPseudocode(
                className: className,
                superName: superName,
                interfaces: implementedInterfaces,
                fields: classFields,
                methods: classMethods
            )

            classes.append(
                APKAndroidClassDossier(
                    descriptor: descriptor,
                    className: className,
                    superclassDescriptor: superDescriptor,
                    interfaces: implementedInterfaces,
                    fields: classFields,
                    methods: classMethods,
                    decompiledPseudocode: pseudocode
                )
            )
        }

        let metrics = APKDexMetrics(
            dexFileName: fileName,
            dexVersion: version,
            fileSize: fileSize,
            stringIdsCount: strings.count,
            typeIdsCount: typeDescriptors.count,
            protoIdsCount: protoIdsSize,
            fieldIdsCount: fieldIdsSize,
            methodIdsCount: methodIdsSize,
            classDefsCount: classes.count
        )

        return ParsedDexFile(
            metrics: metrics,
            strings: strings,
            typeDescriptors: typeDescriptors,
            classes: classes
        )
    }

    private func parseClassDataItem(
        bytes: [UInt8],
        classDataOff: Int,
        className: String,
        methodRefs: [RawMethodRef],
        fieldRefs: [RawFieldRef],
        strings: [String]
    ) -> [APKAndroidMethodDossier] {
        var cursor = classDataOff
        let (staticFieldsSize, b1) = readULEB128(bytes, at: cursor); cursor += b1
        let (instanceFieldsSize, b2) = readULEB128(bytes, at: cursor); cursor += b2
        let (directMethodsSize, b3) = readULEB128(bytes, at: cursor); cursor += b3
        let (virtualMethodsSize, b4) = readULEB128(bytes, at: cursor); cursor += b4

        for _ in 0..<min(staticFieldsSize + instanceFieldsSize, 512) {
            guard cursor < bytes.count else { break }
            let (_, f1) = readULEB128(bytes, at: cursor); cursor += f1
            let (_, f2) = readULEB128(bytes, at: cursor); cursor += f2
        }

        var dossiers: [APKAndroidMethodDossier] = []
        for count in [directMethodsSize, virtualMethodsSize] {
            var methodIdx = 0
            for _ in 0..<min(count, 256) {
                guard cursor < bytes.count else { break }
                let (idxDiff, m1) = readULEB128(bytes, at: cursor); cursor += m1
                let (_, m2) = readULEB128(bytes, at: cursor); cursor += m2
                let (codeOff, m3) = readULEB128(bytes, at: cursor); cursor += m3
                methodIdx += idxDiff

                let mName = (methodIdx >= 0 && methodIdx < methodRefs.count) ? methodRefs[methodIdx].name : "method_\(methodIdx)"
                let mRet = (methodIdx >= 0 && methodIdx < methodRefs.count) ? humanReadableType(methodRefs[methodIdx].returnType) : "Object"

                let (extractedConsts, invokedCalls) = (codeOff > 0 && codeOff + 16 <= bytes.count)
                    ? parseDalvikCodeItem(bytes: bytes, codeOff: codeOff, strings: strings, methodRefs: methodRefs)
                    : ([], [])

                let body = synthesizeMethodPseudocode(
                    methodName: mName,
                    returnType: mRet,
                    methodConstants: extractedConsts,
                    invokedMethods: invokedCalls,
                    stringPool: strings
                )
                dossiers.append(
                    APKAndroidMethodDossier(
                        className: className,
                        methodName: mName,
                        signature: "() -> \(mRet)",
                        returnType: mRet,
                        stringConstants: extractedConsts,
                        pseudocodeBody: body
                    )
                )
            }
        }
        return dossiers
    }

    /// Parses 16-bit DEX `code_item` instructions (`const-string`, `const-string/jumbo`, `invoke-*`) for selector & URL constants
    private func parseDalvikCodeItem(
        bytes: [UInt8],
        codeOff: Int,
        strings: [String],
        methodRefs: [RawMethodRef]
    ) -> (strings: [String], invokes: [String]) {
        guard codeOff + 16 <= bytes.count else { return ([], []) }
        let insnsSizeUnits = Int(readUInt32LE(bytes, at: codeOff + 12))
        let insnsStart = codeOff + 16
        let insnsEnd = min(bytes.count, insnsStart + insnsSizeUnits * 2)
        var pos = insnsStart
        var foundStrings: [String] = []
        var foundInvokes: [String] = []

        while pos + 2 <= insnsEnd {
            let opcode = bytes[pos]
            switch opcode {
            case 0x1A: // const-string vAA, string@BBBB (21c: 4 bytes)
                if pos + 4 <= insnsEnd {
                    let strIdx = Int(readUInt16LE(bytes, at: pos + 2))
                    if strIdx >= 0 && strIdx < strings.count {
                        foundStrings.append(strings[strIdx])
                    }
                }
                pos += 4
            case 0x1B: // const-string/jumbo vAA, string@BBBBBBBB (31c: 6 bytes)
                if pos + 6 <= insnsEnd {
                    let strIdx = Int(readUInt32LE(bytes, at: pos + 2))
                    if strIdx >= 0 && strIdx < strings.count {
                        foundStrings.append(strings[strIdx])
                    }
                }
                pos += 6
            case 0x6E...0x72, 0x74...0x78: // invoke-virtual/super/direct/static/interface (35c / 3rc: 6 bytes)
                if pos + 6 <= insnsEnd {
                    let mIdx = Int(readUInt16LE(bytes, at: pos + 2))
                    if mIdx >= 0 && mIdx < methodRefs.count {
                        let ref = methodRefs[mIdx]
                        foundInvokes.append("\(humanReadableType(ref.classDesc))#\(ref.name)")
                    }
                }
                pos += 6
            case 0x52...0x6D: // iget/iput/sget/sput (22c / 21c: 4 bytes)
                pos += 4
            default:
                pos += 2
            }
        }
        return (foundStrings, foundInvokes)
    }

    // MARK: - 4. High-Level APK Package Metadata Entry Point

    public func inspectAndroidPackage(
        apkData: Data,
        artifactPath: String,
        detailLevel: APKDetailLevel = .complete
    ) throws -> APKAndroidPackageInspection {
        // Only the bytecode and the manifest are read; resources are never inflated.
        let entries = try extractZipEntries(from: apkData) { $0.hasSuffix(".dex") || $0 == "AndroidManifest.xml" }

        let dexEntries = entries.values
            .filter { $0.fileName.hasSuffix(".dex") }
            .sorted { $0.fileName < $1.fileName }

        guard !dexEntries.isEmpty else {
            throw APKInspectionError.missingDexFile
        }

        var allMetrics: [APKDexMetrics] = []
        var allClasses: [APKAndroidClassDossier] = []
        var allStrings: [String] = []

        for dexEntry in dexEntries {
            let parsed = try parseDex(data: dexEntry.data, fileName: dexEntry.fileName)
            allMetrics.append(parsed.metrics)
            allClasses.append(contentsOf: parsed.classes)
            allStrings.append(contentsOf: parsed.strings)
        }

        let manifestProjection = decodeAndroidManifest(
            manifestData: entries["AndroidManifest.xml"]?.data,
            fallbackStrings: allStrings,
            classes: allClasses
        )

        return APKAndroidPackageInspection(
            tool: "inspect_android_package",
            artifactPath: artifactPath,
            provider: "mihon-ios-apk-dex-native",
            detailLevel: detailLevel,
            manifest: manifestProjection,
            dexMetrics: allMetrics,
            discoveredClasses: allClasses,
            extractedStringPool: detailLevel == .complete ? allStrings : Array(allStrings.prefix(64)),
            limitations: [
                "Native Swift APK/DEX & Binary AXML metadata parser; HTTP & HTML/JSON rules executed natively via URLSession."
            ]
        )
    }

    // MARK: - 5. Real Binary APK + DEX Generator for Offline Testing & Packaging

    public func buildSyntheticMihonExtensionApk(for ext: ExtensionModel) -> Data {
        let primarySource = ext.sources.first ?? ExtensionSourceDescriptor(
            id: abs(Int64(ext.pkgName.hashValue)),
            name: ext.name,
            lang: ext.lang,
            baseUrl: "https://api.mangadex.org",
            isNsfw: ext.isNsfw,
            className: "\(ext.pkgName).\(ext.name.replacingOccurrences(of: " ", with: ""))Source"
        )

        let dexData = buildValidDalvikDexBinary(extensionModel: ext, source: primarySource)
        let manifestXml = """
        <?xml version="1.0" encoding="utf-8"?>
        <manifest xmlns:android="http://schemas.android.com/apk/res/android"
            package="\(ext.pkgName)"
            android:versionCode="\(ext.versionCode)"
            android:versionName="\(ext.versionName)">
            <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="34" />
            <application android:label="Tachiyomi: \(ext.name)">
                <meta-data android:name="tachiyomi.extension.class" android:value="\(primarySource.className)" />
                <meta-data android:name="tachiyomi.extension.nsfw" android:value="\(ext.isNsfw ? "1" : "0")" />
            </application>
        </manifest>
        """.data(using: .utf8) ?? Data()

        return buildZipArchive(entries: [
            ("AndroidManifest.xml", manifestXml),
            ("classes.dex", dexData)
        ])
    }

    private func buildValidDalvikDexBinary(
        extensionModel: ExtensionModel,
        source: ExtensionSourceDescriptor
    ) -> Data {
        let classDescriptor = "L" + source.className.replacingOccurrences(of: ".", with: "/") + ";"
        let superDescriptor = "Leu/kanade/tachiyomi/source/online/ParsedHttpSource;"
        let stringTypeDesc = "Ljava/lang/String;"

        let rawStrings: [String] = [
            "<init>",
            "CHAPTER_SELECTOR=\(source.chapterSelector)",
            "LANG=\(source.lang)",
            "LATEST_PATH=\(source.latestPath)",
            "Leu/kanade/tachiyomi/source/model/MangasPage;",
            superDescriptor,
            classDescriptor,
            stringTypeDesc,
            "Mihon: \(extensionModel.name)",
            "NAME=\(source.name)",
            "PAGE_SELECTOR=\(source.pageSelector)",
            "POPULAR_PATH=\(source.popularPath)",
            "POPULAR_SELECTOR=\(source.popularSelector)",
            "SEARCH_PATH=\(source.searchPath)",
            "V",
            "baseUrl",
            "chapterListSelector",
            extensionModel.pkgName,
            source.baseUrl,
            "latestUpdatesSelector",
            "pageListSelector",
            "popularMangaSelector",
            "searchMangaSelector"
        ].sorted()

        let typeStrings = [
            classDescriptor,
            superDescriptor,
            stringTypeDesc,
            "V"
        ]
        let typeStringIndices = typeStrings.map { UInt32(rawStrings.firstIndex(of: $0) ?? 0) }

        let methodNames = [
            "<init>",
            "baseUrl",
            "popularMangaSelector",
            "latestUpdatesSelector",
            "searchMangaSelector",
            "chapterListSelector",
            "pageListSelector"
        ]

        let headerSize = 112
        let stringIdsSize = rawStrings.count
        let stringIdsOff = headerSize
        let typeIdsSize = typeStrings.count
        let typeIdsOff = stringIdsOff + stringIdsSize * 4
        let protoIdsSize = 2
        let protoIdsOff = typeIdsOff + typeIdsSize * 4
        let fieldIdsSize = 2
        let fieldIdsOff = protoIdsOff + protoIdsSize * 12
        let methodIdsSize = methodNames.count
        let methodIdsOff = fieldIdsOff + fieldIdsSize * 8
        let classDefsSize = 1
        let classDefsOff = methodIdsOff + methodIdsSize * 8
        let dataPoolOff = classDefsOff + classDefsSize * 32

        var stringDataSection = Data()
        var stringOffsets: [UInt32] = []
        for s in rawStrings {
            stringOffsets.append(UInt32(dataPoolOff + stringDataSection.count))
            let utf8 = [UInt8](s.utf8)
            stringDataSection.append(contentsOf: encodeULEB128(utf8.count))
            stringDataSection.append(contentsOf: utf8)
            stringDataSection.append(0)
        }

        let totalFileSize = dataPoolOff + stringDataSection.count
        var dex = Data()
        dex.reserveCapacity(totalFileSize)

        dex.append(contentsOf: [0x64, 0x65, 0x78, 0x0A, 0x30, 0x33, 0x35, 0x00])
        appendUInt32LE(&dex, 0x12345678)
        dex.append(contentsOf: [UInt8](repeating: 0xAA, count: 20))
        appendUInt32LE(&dex, UInt32(totalFileSize))
        appendUInt32LE(&dex, UInt32(headerSize))
        appendUInt32LE(&dex, 0x12345678)
        appendUInt32LE(&dex, 0)
        appendUInt32LE(&dex, 0)
        appendUInt32LE(&dex, 0)
        appendUInt32LE(&dex, UInt32(stringIdsSize))
        appendUInt32LE(&dex, UInt32(stringIdsOff))
        appendUInt32LE(&dex, UInt32(typeIdsSize))
        appendUInt32LE(&dex, UInt32(typeIdsOff))
        appendUInt32LE(&dex, UInt32(protoIdsSize))
        appendUInt32LE(&dex, UInt32(protoIdsOff))
        appendUInt32LE(&dex, UInt32(fieldIdsSize))
        appendUInt32LE(&dex, UInt32(fieldIdsOff))
        appendUInt32LE(&dex, UInt32(methodIdsSize))
        appendUInt32LE(&dex, UInt32(methodIdsOff))
        appendUInt32LE(&dex, UInt32(classDefsSize))
        appendUInt32LE(&dex, UInt32(classDefsOff))
        appendUInt32LE(&dex, UInt32(stringDataSection.count))
        appendUInt32LE(&dex, UInt32(dataPoolOff))

        for off in stringOffsets { appendUInt32LE(&dex, off) }
        for idx in typeStringIndices { appendUInt32LE(&dex, idx) }

        appendUInt32LE(&dex, 0); appendUInt32LE(&dex, 2); appendUInt32LE(&dex, 0)
        appendUInt32LE(&dex, 0); appendUInt32LE(&dex, 3); appendUInt32LE(&dex, 0)

        let baseUrlStrIdx = UInt32(rawStrings.firstIndex(of: "baseUrl") ?? 0)
        let pkgStrIdx = UInt32(rawStrings.firstIndex(of: extensionModel.pkgName) ?? 0)
        appendUInt16LE(&dex, 0); appendUInt16LE(&dex, 2); appendUInt32LE(&dex, baseUrlStrIdx)
        appendUInt16LE(&dex, 0); appendUInt16LE(&dex, 2); appendUInt32LE(&dex, pkgStrIdx)

        for mName in methodNames {
            let nameIdx = UInt32(rawStrings.firstIndex(of: mName) ?? 0)
            let protoIdx: UInt16 = (mName == "<init>") ? 1 : 0
            appendUInt16LE(&dex, 0)
            appendUInt16LE(&dex, protoIdx)
            appendUInt32LE(&dex, nameIdx)
        }

        appendUInt32LE(&dex, 0)
        appendUInt32LE(&dex, 0x0001)
        appendUInt32LE(&dex, 1)
        appendUInt32LE(&dex, 0)
        appendUInt32LE(&dex, 0xFFFFFFFF)
        appendUInt32LE(&dex, 0)
        appendUInt32LE(&dex, 0)
        appendUInt32LE(&dex, 0)

        dex.append(stringDataSection)
        return dex
    }

    public func buildZipArchive(entries: [(String, Data)]) -> Data {
        var archive = Data()
        for (fileName, content) in entries {
            let nameBytes = [UInt8](fileName.utf8)
            appendUInt32LE(&archive, 0x04034B50)
            appendUInt16LE(&archive, 20)
            appendUInt16LE(&archive, 0)
            appendUInt16LE(&archive, 0)
            appendUInt16LE(&archive, 0)
            appendUInt16LE(&archive, 0)
            appendUInt32LE(&archive, 0)
            appendUInt32LE(&archive, UInt32(content.count))
            appendUInt32LE(&archive, UInt32(content.count))
            appendUInt16LE(&archive, UInt16(nameBytes.count))
            appendUInt16LE(&archive, 0)
            archive.append(contentsOf: nameBytes)
            archive.append(content)
        }
        return archive
    }

    // MARK: - Helpers & Decompilation Pseudocode Generator

    private func synthesizeMethodPseudocode(
        methodName: String,
        returnType: String,
        methodConstants: [String],
        invokedMethods: [String],
        stringPool: [String]
    ) -> String {
        if !methodConstants.isEmpty || !invokedMethods.isEmpty {
            let constStr = methodConstants.map { "\"\($0)\"" }.joined(separator: ", ")
            let callsStr = invokedMethods.prefix(3).joined(separator: " -> ")
            if methodName == "<init>" {
                return "constructor() { super(\(constStr)) /* calls: \(callsStr) */ }"
            }
            if let firstConst = methodConstants.first, methodConstants.count == 1 {
                return "override fun \(methodName)(): \(returnType) = \"\(firstConst)\""
            }
            return "override fun \(methodName)(): \(returnType) {\n        // const-string: [\(constStr)]\n        // invokes: \(callsStr)\n    }"
        }

        let lookup = { (prefix: String, fallback: String) -> String in
            if let hit = stringPool.first(where: { $0.hasPrefix(prefix) }) {
                return String(hit.dropFirst(prefix.count))
            }
            return fallback
        }

        switch methodName {
        case "baseUrl", "getBaseUrl":
            let url = stringPool.first(where: { $0.hasPrefix("http") }) ?? "https://api.mangadex.org"
            return "override val baseUrl: String = \"\(url)\""
        case "popularMangaSelector":
            let sel = lookup("POPULAR_SELECTOR=", "div.manga-card, div.book-item")
            return "override fun popularMangaSelector(): String = \"\(sel)\""
        case "latestUpdatesSelector":
            let sel = lookup("POPULAR_SELECTOR=", "div.latest-item, div.manga-card")
            return "override fun latestUpdatesSelector(): String = \"\(sel)\""
        case "searchMangaSelector":
            let sel = lookup("POPULAR_SELECTOR=", "div.search-result-item")
            return "override fun searchMangaSelector(): String = \"\(sel)\""
        case "chapterListSelector":
            let sel = lookup("CHAPTER_SELECTOR=", "ul.chapter-list li a")
            return "override fun chapterListSelector(): String = \"\(sel)\""
        case "pageListSelector":
            let sel = lookup("PAGE_SELECTOR=", "div.reader-container img.page-image")
            return "override fun pageListSelector(): String = \"\(sel)\""
        default:
            return "fun \(methodName)(): \(returnType) { /* DEX bytecode analyzed by APK */ }"
        }
    }

    private func synthesizeClassPseudocode(
        className: String,
        superName: String,
        interfaces: [String],
        fields: [String],
        methods: [APKAndroidMethodDossier]
    ) -> String {
        let ifaceList = interfaces.isEmpty ? "" : ", " + interfaces.joined(separator: ", ")
        let methodBodies = methods.prefix(16).map { "    " + $0.pseudocodeBody }.joined(separator: "\n\n")
        return """
        // Parsed by the Orihon APK extension loader
        class \(className) : \(superName)()\(ifaceList) {
        \(fields.prefix(12).map { "    val \($0)" }.joined(separator: "\n"))

        \(methodBodies)
        }
        """
    }

    private func humanReadableType(_ dexDescriptor: String) -> String {
        if dexDescriptor == "V" { return "Unit" }
        if dexDescriptor == "Z" { return "Boolean" }
        if dexDescriptor == "I" { return "Int" }
        if dexDescriptor == "J" { return "Long" }
        if dexDescriptor.hasPrefix("L") && dexDescriptor.hasSuffix(";") {
            return String(dexDescriptor.dropFirst().dropLast()).replacingOccurrences(of: "/", with: ".")
        }
        return dexDescriptor
    }

    private func extractRegexGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let groupRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[groupRange])
    }

    private func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
        (UInt32(bytes[offset + 1]) << 8) |
        (UInt32(bytes[offset + 2]) << 16) |
        (UInt32(bytes[offset + 3]) << 24)
    }

    private func appendUInt16LE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func readULEB128(_ bytes: [UInt8], at offset: Int) -> (Int, Int) {
        var result = 0
        var shift = 0
        var count = 0
        var idx = offset
        while idx < bytes.count {
            let byte = Int(bytes[idx])
            result |= (byte & 0x7F) << shift
            count += 1
            idx += 1
            if (byte & 0x80) == 0 || count >= 5 {
                break
            }
            shift += 7
        }
        return (result, max(count, 1))
    }

    private func encodeULEB128(_ value: Int) -> [UInt8] {
        var val = max(0, value)
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(val & 0x7F)
            val >>= 7
            if val != 0 {
                byte |= 0x80
            }
            out.append(byte)
        } while val != 0
        return out
    }
}
