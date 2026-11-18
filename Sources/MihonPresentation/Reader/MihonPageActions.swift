import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import MihonDomain
import MihonData
#if canImport(UIKit)
import UIKit
import Photos
#else
import AppKit
#endif

// MARK: - Page actions (upstream `ReaderPageActionsDialog`)

extension EnvironmentValues {
    /// The title the reader shows (for 设为封面).
    @Entry var mihonReaderMangaId: Int64?
}

/// Long-pressing a page offers upstream's page actions — set as cover, share, save, copy — as the iOS context menu,
/// which leaves the reader's taps, pinch and scrolling alone. They work on the page's original bytes.
struct MihonPageContextMenu: ViewModifier {
    let page: Page
    let mangaTitle: String
    let chapterTitle: String
    /// Only for a page that loaded.
    let enabled: Bool
    @Environment(MihonRepositoryStore.self) private var store: MihonRepositoryStore?
    @Environment(\.mihonReaderMangaId) private var mangaId

    func body(content: Content) -> some View {
        content.contextMenu {
            if enabled, let url = page.imageUrl {
                // Upstream: only a title in the library gets a custom cover.
                if let mangaId, store?.manga(id: mangaId)?.favorite == true {
                    Button {
                        Task {
                            await run { data in
                                try store?.setCustomCover(mangaId: mangaId, data: data)
                                return "已设为封面"
                            }
                        }
                    } label: {
                        Label("设为封面", systemImage: "photo")
                    }
                }
                let file = MihonPageImageFile(url: url, fileName: fileName)
                ShareLink(item: file, preview: SharePreview(fileName)) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                #if os(iOS)
                Button {
                    Task { await run { try await MihonPageActions.saveToPhotos($0) ; return "已保存到相册" } }
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                }
                #endif
                Button {
                    Task { await run { MihonPageActions.copy($0); return "已复制图片" } }
                } label: {
                    Label("复制图片", systemImage: "doc.on.doc")
                }
            }
        }
    }

    /// Upstream's file name: "<title> - <chapter> - <page>".
    private var fileName: String {
        let name = "\(mangaTitle) - \(chapterTitle) - \(page.index + 1)"
            .replacingOccurrences(of: "/", with: "／")
            .replacingOccurrences(of: ":", with: "：")
        return name + ".jpg"
    }

    private func run(_ action: (Data) async throws -> String) async {
        guard let url = page.imageUrl, let data = await MihonPageImageFile.jpegData(url: url) else {
            store?.showStatusBanner("无法读取这一页的图片")
            return
        }
        do {
            store?.showStatusBanner(try await action(data))
        } catch {
            store?.showStatusBanner(error.localizedDescription)
        }
    }
}

/// A page to share: its JPEG, made when the receiving app asks for it.
struct MihonPageImageFile: Transferable {
    let url: String
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { file in
            guard let data = await jpegData(url: file.url) else { throw CocoaError(.fileReadUnknown) }
            return data
        }
        .suggestedFileName { $0.fileName }
    }

    /// JPEG as is; other formats (WebP, PNG…) converted, since Photos and many apps take JPEG only.
    static func jpegData(url: String) async -> Data? {
        guard let data = await MihonTwoTierImageCache.shared.originalData(url: url) else { return nil }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return data }
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? output as Data : nil
        }.value
    }
}

enum MihonPageActions {
    enum Failure: LocalizedError {
        case photosDenied

        var errorDescription: String? {
            "没有相册权限：请在「设置 › Orihon › 照片」里允许添加照片"
        }
    }

    #if os(iOS)
    /// Add-only access: the app never reads the photo library.
    static func saveToPhotos(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.photosDenied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
    #endif

    /// The JPEG as it is: setting an image would re-encode it as PNG, on the main thread.
    static func copy(_ data: Data) {
        #if canImport(UIKit)
        UIPasteboard.general.setData(data, forPasteboardType: UTType.jpeg.identifier)
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        #endif
    }
}
