import Foundation
import MihonDomain

// MARK: - Android APK Extension Package Metadata Schema

public enum APKDetailLevel: String, Codable, Sendable {
    case summary = "summary"
    case complete = "complete"
}

public struct APKManifestMetaData: Codable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct APKManifestProjection: Codable, Hashable, Sendable {
    public var packageName: String
    public var versionName: String
    public var versionCode: Int
    public var minSdkVersion: Int
    public var targetSdkVersion: Int
    public var applicationLabel: String
    public var permissions: [String]
    public var activities: [String]
    public var services: [String]
    public var receivers: [String]
    public var providers: [String]
    public var metaData: [APKManifestMetaData]

    public var tachiyomiExtensionClass: String? {
        metaData.first(where: { $0.name == "tachiyomi.extension.class" })?.value
    }

    public var tachiyomiIsNsfw: Bool {
        metaData.first(where: { $0.name == "tachiyomi.extension.nsfw" })?.value == "1"
    }

    public init(
        packageName: String,
        versionName: String,
        versionCode: Int,
        minSdkVersion: Int = 21,
        targetSdkVersion: Int = 34,
        applicationLabel: String,
        permissions: [String] = ["android.permission.INTERNET"],
        activities: [String] = [],
        services: [String] = [],
        receivers: [String] = [],
        providers: [String] = [],
        metaData: [APKManifestMetaData] = []
    ) {
        self.packageName = packageName
        self.versionName = versionName
        self.versionCode = versionCode
        self.minSdkVersion = minSdkVersion
        self.targetSdkVersion = targetSdkVersion
        self.applicationLabel = applicationLabel
        self.permissions = permissions
        self.activities = activities
        self.services = services
        self.receivers = receivers
        self.providers = providers
        self.metaData = metaData
    }
}

public struct APKDexMetrics: Codable, Hashable, Sendable {
    public var dexFileName: String
    public var dexVersion: String
    public var fileSize: Int
    public var stringIdsCount: Int
    public var typeIdsCount: Int
    public var protoIdsCount: Int
    public var fieldIdsCount: Int
    public var methodIdsCount: Int
    public var classDefsCount: Int

    public init(
        dexFileName: String = "classes.dex",
        dexVersion: String = "035",
        fileSize: Int,
        stringIdsCount: Int,
        typeIdsCount: Int,
        protoIdsCount: Int,
        fieldIdsCount: Int,
        methodIdsCount: Int,
        classDefsCount: Int
    ) {
        self.dexFileName = dexFileName
        self.dexVersion = dexVersion
        self.fileSize = fileSize
        self.stringIdsCount = stringIdsCount
        self.typeIdsCount = typeIdsCount
        self.protoIdsCount = protoIdsCount
        self.fieldIdsCount = fieldIdsCount
        self.methodIdsCount = methodIdsCount
        self.classDefsCount = classDefsCount
    }
}

/// Output of APK package inspection
public struct APKAndroidPackageInspection: Codable, Hashable, Sendable {
    public var tool: String
    public var evidenceId: String
    public var artifactPath: String
    public var provider: String
    public var detailLevel: APKDetailLevel
    public var manifest: APKManifestProjection
    public var dexMetrics: [APKDexMetrics]
    public var discoveredClasses: [APKAndroidClassDossier]
    public var extractedStringPool: [String]
    public var limitations: [String]
    public var inspectedAt: Date
    /// The package's verified APK signature; nil for synthetic packages or ones that were not verified.
    public var signature: APKSignatureVerification?

    public init(
        tool: String = "inspect_android_package",
        evidenceId: String = "apk-id-\(UUID().uuidString.prefix(8).lowercased())",
        artifactPath: String,
        provider: String = "mihon-ios-apk-loader",
        detailLevel: APKDetailLevel = .complete,
        manifest: APKManifestProjection,
        dexMetrics: [APKDexMetrics],
        discoveredClasses: [APKAndroidClassDossier],
        extractedStringPool: [String],
        limitations: [String] = [],
        inspectedAt: Date = Date()
    ) {
        self.tool = tool
        self.evidenceId = evidenceId
        self.artifactPath = artifactPath
        self.provider = provider
        self.detailLevel = detailLevel
        self.manifest = manifest
        self.dexMetrics = dexMetrics
        self.discoveredClasses = discoveredClasses
        self.extractedStringPool = extractedStringPool
        self.limitations = limitations
        self.inspectedAt = inspectedAt
    }
}

/// Output of class metadata inspection
public struct APKAndroidClassDossier: Codable, Hashable, Identifiable, Sendable {
    public var id: String { descriptor }
    public var descriptor: String
    public var className: String
    public var superclassDescriptor: String
    public var interfaces: [String]
    public var fields: [String]
    public var methods: [APKAndroidMethodDossier]
    public var decompiledPseudocode: String

    public init(
        descriptor: String,
        className: String,
        superclassDescriptor: String,
        interfaces: [String] = [],
        fields: [String] = [],
        methods: [APKAndroidMethodDossier] = [],
        decompiledPseudocode: String = ""
    ) {
        self.descriptor = descriptor
        self.className = className
        self.superclassDescriptor = superclassDescriptor
        self.interfaces = interfaces
        self.fields = fields
        self.methods = methods
        self.decompiledPseudocode = decompiledPseudocode
    }
}

/// Output of method metadata inspection
public struct APKAndroidMethodDossier: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(className)#\(methodName)\(signature)" }
    public var className: String
    public var methodName: String
    public var signature: String
    public var returnType: String
    public var stringConstants: [String]
    public var pseudocodeBody: String

    public init(
        className: String,
        methodName: String,
        signature: String,
        returnType: String,
        stringConstants: [String] = [],
        pseudocodeBody: String = ""
    ) {
        self.className = className
        self.methodName = methodName
        self.signature = signature
        self.returnType = returnType
        self.stringConstants = stringConstants
        self.pseudocodeBody = pseudocodeBody
    }
}

/// Output of symbol reference inspection
public struct APKAndroidReferenceTrace: Codable, Hashable, Sendable {
    public var targetSymbol: String
    public var callers: [String]
    public var callees: [String]
    public var referencedStrings: [String]

    public init(
        targetSymbol: String,
        callers: [String],
        callees: [String],
        referencedStrings: [String]
    ) {
        self.targetSymbol = targetSymbol
        self.callers = callers
        self.callees = callees
        self.referencedStrings = referencedStrings
    }
}
