import SwiftUI

/// The viewer's Info tab: facts about the original image and where it came from.
struct ImageInfoPanel: View {
    let reference: Reference
    /// Nil until the image has loaded.
    let loaded: ImageLoader.Loaded?

    var body: some View {
        Form {
            if let metadata = loaded?.metadata {
                Section("Image") {
                    LabeledContent("Dimensions", value: Self.dimensions(metadata.pixelWidth, metadata.pixelHeight))
                    LabeledContent("Megapixels", value: metadata.megapixels.formatted(.number.precision(.fractionLength(1))) + " MP")
                    if let profile = metadata.colorProfile ?? metadata.colorModel {
                        LabeledContent("Colour", value: profile)
                    }
                    if let bits = metadata.bitsPerComponent {
                        LabeledContent("Bit Depth", value: String(localized: "\(bits) bits per channel"))
                    }
                    if let dpi = metadata.dpi {
                        LabeledContent("Resolution", value: String(localized: "\(dpi) dpi"))
                    }
                    if metadata.hasAlpha {
                        LabeledContent("Transparency", value: String(localized: "Yes"))
                    }
                }

                if metadata.camera != nil || metadata.lensModel != nil || metadata.dateTaken != nil {
                    Section("Camera") {
                        if let camera = metadata.camera {
                            LabeledContent("Camera", value: camera)
                        }
                        if let lens = metadata.lensModel {
                            LabeledContent("Lens", value: lens)
                        }
                        if let date = metadata.dateTaken {
                            LabeledContent("Taken", value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
            }

            if let asset = reference.asset {
                Section {
                    LabeledContent("Format", value: Self.formatName(asset.mimeType))
                    LabeledContent("Size", value: asset.byteCount.formatted(.byteCount(style: .file)))
                    if let filename = asset.originalFilename {
                        LabeledContent("File Name", value: filename)
                    }
                    LabeledContent("Added", value: reference.capturedAt.formatted(date: .abbreviated, time: .shortened))
                } header: {
                    Text("File")
                } footer: {
                    if let loaded, loaded.isDownscaled {
                        Text("Shown at \(Self.dimensions(loaded.image.width, loaded.image.height)) because the original is larger than the display can handle. The original is unchanged.")
                    }
                }
            }

            if reference.sourcePageURL != nil || reference.originalResourceURL != nil {
                Section("Source") {
                    if let page = reference.sourcePageURL {
                        LabeledContent("Page") {
                            Link(page.host() ?? page.absoluteString, destination: page)
                        }
                    }
                    if let resource = reference.originalResourceURL {
                        LabeledContent("Image") {
                            Link(resource.lastPathComponent, destination: resource)
                        }
                    }
                }
            }

            if !reference.tags.isEmpty {
                Section("Tags") {
                    TagChips(tags: reference.tags, limit: 50)
                }
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if loaded == nil {
                ProgressView()
            }
        }
    }

    static func dimensions(_ width: Int, _ height: Int) -> String {
        String(localized: "\(width.formatted()) × \(height.formatted()) pixels")
    }

    static func formatName(_ mimeType: String) -> String {
        switch mimeType {
        case "image/jpeg": "JPEG"
        case "image/png": "PNG"
        case "image/webp": "WebP"
        case "image/heic": "HEIC"
        default: mimeType
        }
    }
}
