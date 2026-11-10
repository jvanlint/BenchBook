import AppKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Turns dragged, pasted or shared `NSItemProvider`s into captured items.
/// Used by the app (drag and drop, paste) and by the Share extension.
nonisolated struct ItemProviderReader {
    private static let log = Logger(subsystem: "com.jasonvanlint.BenchBook", category: "Capture")

    struct Result {
        var items: [CapturedItem] = []
        /// Names of things that were offered but can't be saved.
        var skipped: [String] = []
    }

    /// File types worth copying, best first. The app re-checks contents on import.
    static let fileTypes: [UTType] = [
        .pdf, .jpeg, .png, .webP, .heic,
        UTType("net.daringfireball.markdown") ?? .plainText,
    ]

    /// Where files delivered as data or promises are written.
    let fileDirectory: URL
    /// The Share extension must copy shared files, because its access ends
    /// when the sheet closes. The app imports dropped files directly.
    let copiesFileURLs: Bool

    /// Reads one shared `NSExtensionItem`. Apps use its content text for
    /// either the page title or the selected text, so that's decided from
    /// what else is attached.
    func read(attachments: [NSItemProvider], title: String?, contentText: String?) async -> Result {
        Self.log.notice("Shared item offering: \(attachments.map(\.registeredTypeIdentifiers), privacy: .public)")
        let (providers, title) = Self.sharedProviders(attachments: attachments, title: title, contentText: contentText)
        return await read(providers, title: title)
    }

    /// The providers to read and the page title, from a shared item's parts.
    /// - Content text with text already attached is the same selection again.
    /// - A single line shared with a link or file, and no title, is the title.
    /// - Otherwise it's the text being shared.
    static func sharedProviders(attachments: [NSItemProvider], title: String?,
                                contentText: String?) -> (providers: [NSItemProvider], title: String?) {
        let title = title.flatMap(singleLine)
        guard let content = contentText, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (attachments, title)
        }
        if attachments.contains(where: carriesText) {
            return (attachments, title)
        }
        if title == nil, !attachments.isEmpty, let line = singleLine(content) {
            return (attachments, line)
        }
        if let title, singleLine(content) == title {
            return (attachments, title)
        }
        return (attachments + [NSItemProvider(object: content as NSString)], title)
    }

    /// Types a selection of text arrives as, plainest first.
    static let textTypes: [UTType] = [.plainText, .rtf, .rtfd, .flatRTFD, .html]

    private static func carriesText(_ provider: NSItemProvider) -> Bool {
        textTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    }

    /// Nil for blank or multi-line text, which isn't a usable title.
    private static func singleLine(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isNewline), value.count <= 300 else { return nil }
        return value
    }

    /// Reads one group of providers, such as one `NSExtensionItem` or one
    /// drop. `title` is a page title supplied alongside, if any.
    func read(_ providers: [NSItemProvider], title: String? = nil) async -> Result {
        var result = Result()
        var links: [(URL, String?)] = []
        var texts: [String] = []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadURL(provider, type: .fileURL), url.isFileURL {
                if let item = fileItem(for: url) {
                    result.items.append(item)
                } else {
                    result.skipped.append(url.lastPathComponent)
                }
            } else if let type = Self.fileTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }),
                      let url = await loadFile(provider, type: type) {
                let name = provider.suggestedName.map { name in
                    name.contains(".") ? name : "\(name).\(type.preferredFilenameExtension ?? "")"
                }
                let webURL = await webURL(alongside: provider)
                if !type.conforms(to: .image) || Self.isReadableImage(url) {
                    result.items.append(.file(url: url, originalFilename: name, resourceURL: webURL))
                } else {
                    // A browser can hand over an error page instead of the image,
                    // e.g. when a site refuses its re-download. Fall back to the
                    // pixels on screen, then to the address as a link.
                    try? FileManager.default.removeItem(at: url)
                    if let png = await loadImageAsPNG(provider, excluding: type) {
                        result.items.append(.file(url: png, originalFilename: name.map { "\(($0 as NSString).deletingPathExtension).png" }, resourceURL: webURL))
                    } else if let webURL {
                        links.append((webURL, name))
                    } else {
                        result.skipped.append(name ?? String(localized: "Image"))
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let url = await loadImageAsPNG(provider) {
                // Formats such as TIFF from some browsers: stored losslessly as PNG.
                result.items.append(.file(url: url, originalFilename: provider.suggestedName.map { "\($0).png" },
                                          resourceURL: await webURL(alongside: provider)))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await loadURL(provider, type: .url) {
                if url.isFileURL, let item = fileItem(for: url) {
                    result.items.append(item)
                } else {
                    links.append((url, nil))
                }
            } else if Self.carriesText(provider), let text = await loadText(provider) {
                if let url = Self.singleWebURL(in: text) {
                    links.append((url, nil))
                } else if !texts.contains(text) {
                    texts.append(text)
                }
            } else {
                Self.log.error("Skipped item offering: \(provider.registeredTypeIdentifiers, privacy: .public)")
                result.skipped.append(provider.suggestedName ?? String(localized: "Unsupported item"))
            }
        }

        // Text shared together with one page link is a snippet from that page.
        texts.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines) == title?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !texts.isEmpty, links.count == 1 {
            let source = links[0].0
            links.removeAll()
            for text in texts {
                result.items.append(.text(text, sourceURL: source, title: title))
            }
        } else {
            for text in texts {
                result.items.append(.text(text, sourceURL: nil, title: nil))
            }
        }
        for (url, linkTitle) in links {
            result.items.append(.link(url: url, title: linkTitle ?? (links.count == 1 ? title : nil)))
        }
        return result
    }

    /// True when ImageIO can read an image from the file.
    static func isReadableImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0
        else { return false }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
    }

    /// A trimmed string that is exactly one http(s) link, if it is one.
    static func singleWebURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil
        else { return nil }
        return url
    }

    // MARK: - Loading

    private func fileItem(for url: URL) -> CapturedItem? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              Self.fileTypes.contains(where: { type.conforms(to: $0) })
                || ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
        else { return nil }

        guard copiesFileURLs else {
            return .file(url: url, originalFilename: url.lastPathComponent, resourceURL: nil)
        }
        let destination = uniqueDestination(extension: url.pathExtension)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { return nil }
        return .file(url: destination, originalFilename: url.lastPathComponent, resourceURL: nil)
    }

    private func uniqueDestination(extension pathExtension: String) -> URL {
        let name = pathExtension.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(pathExtension)"
        return fileDirectory.appending(path: name, directoryHint: .notDirectory)
    }

    private func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: type.identifier) else { return nil }
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    /// The web address a browser attaches to a dragged image, if any.
    private func webURL(alongside provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
              let url = await loadURL(provider, type: .url),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else { return nil }
        return url
    }

    /// Plain text if offered, otherwise the text of rich text or HTML.
    private func loadText(_ provider: NSItemProvider) async -> String? {
        for type in Self.textTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            guard let item = try? await provider.loadItem(forTypeIdentifier: type.identifier) else { continue }
            let text: String? = switch item {
            case let string as String: string
            case let attributed as NSAttributedString: attributed.string
            case let data as Data: Self.text(from: data, type: type)
            default: nil
            }
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    private static func text(from data: Data, type: UTType) -> String? {
        if type.conforms(to: .plainText) { return String(data: data, encoding: .utf8) }
        let documentType: NSAttributedString.DocumentType = switch type {
        case .html: .html
        case .rtfd, .flatRTFD: .rtfd
        default: .rtf
        }
        return try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil).string
    }

    /// Copies the provider's file for `type` before the system deletes it.
    private func loadFile(_ provider: NSItemProvider, type: UTType) async -> URL? {
        let destination = uniqueDestination(extension: type.preferredFilenameExtension ?? "")
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url, (try? FileManager.default.copyItem(at: url, to: destination)) != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: destination)
            }
        }
    }

    /// The first image representation that decodes, saved losslessly as PNG.
    /// `excluding` skips a type already found to be unreadable.
    private func loadImageAsPNG(_ provider: NSItemProvider, excluding excluded: UTType? = nil) async -> URL? {
        let types = provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .filter { $0.conforms(to: .image) && $0 != excluded }
        for type in types {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            guard let data, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
                continue
            }
            let destination = uniqueDestination(extension: "png")
            if (try? png.write(to: destination)) != nil {
                return destination
            }
        }
        return nil
    }
}
