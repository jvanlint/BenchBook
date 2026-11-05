import Foundation

/// What kind of part an aftermarket item is. Stored as `AftermarketItem.typeRaw`.
nonisolated enum AftermarketType: String, CaseIterable, Identifiable, Sendable {
    case decals, resin, photoEtch, printed3D, masks, metal, wheels, figures, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .decals: String(localized: "Decals")
        case .resin: String(localized: "Resin")
        case .photoEtch: String(localized: "Photo-etch")
        case .printed3D: String(localized: "3D printed")
        case .masks: String(localized: "Masks")
        case .metal: String(localized: "Metal parts")
        case .wheels: String(localized: "Wheels")
        case .figures: String(localized: "Figures")
        case .other: String(localized: "Other")
        }
    }
}

/// Where an aftermarket item stands for this build. Stored as
/// `AftermarketItem.statusRaw`, in the order a part usually moves through.
nonisolated enum AftermarketStatus: String, CaseIterable, Identifiable, Sendable {
    case considering, ordered, inStash, using, used, notUsing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .considering: String(localized: "Considering")
        case .ordered: String(localized: "Ordered")
        case .inStash: String(localized: "In stash")
        case .using: String(localized: "Using")
        case .used: String(localized: "Used")
        case .notUsing: String(localized: "Not using")
        }
    }

    var systemImage: String {
        switch self {
        case .considering: "lightbulb"
        case .ordered: "shippingbox"
        case .inStash: "archivebox"
        case .using: "hammer"
        case .used: "checkmark.circle"
        case .notUsing: "xmark.circle"
        }
    }

    /// For sorting: earlier in a build's life first.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

extension AftermarketItem {
    /// Nil if the store holds a type this version doesn't know about.
    var type: AftermarketType? { AftermarketType(rawValue: typeRaw) }
    var status: AftermarketStatus? { AftermarketStatus(rawValue: statusRaw) }

    var typeName: String { type?.displayName ?? typeRaw }
    var statusName: String { status?.displayName ?? statusRaw }
    /// Unknown statuses sort last.
    var statusRank: Int { status?.rank ?? AftermarketStatus.allCases.count }

    /// e.g. "Galaxy Models · G48-012".
    var secondaryLine: String {
        [manufacturer, productNumber ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// e.g. "Galaxy Models 50th Anniversary 2015".
    var displayName: String {
        manufacturer.isEmpty ? productName : "\(manufacturer) \(productName)"
    }
}

extension Project {
    /// By status (considering first), then name.
    var sortedAftermarketItems: [AftermarketItem] {
        aftermarketItems.sorted { lhs, rhs in
            lhs.statusRank != rhs.statusRank
                ? lhs.statusRank < rhs.statusRank
                : lhs.productName.localizedStandardCompare(rhs.productName) == .orderedAscending
        }
    }
}

/// Editable copy of an aftermarket item's fields. The editor changes this,
/// so nothing touches the store until the user saves.
struct AftermarketDraft: Equatable {
    var productName = ""
    var manufacturer = ""
    var productNumber = ""
    var type = AftermarketType.decals
    var status = AftermarketStatus.considering
    var scaleCompatibility = ""
    var productURL = ""
    var notes = ""

    init() {}

    /// A new item for `project`, starting with the project's scale.
    init(project: Project) {
        scaleCompatibility = project.scale
    }

    init(item: AftermarketItem) {
        productName = item.productName
        manufacturer = item.manufacturer
        productNumber = item.productNumber ?? ""
        type = item.type ?? .other
        status = item.status ?? .considering
        scaleCompatibility = item.scaleCompatibility ?? ""
        productURL = item.productURL?.absoluteString ?? ""
        notes = item.notes ?? ""
    }

    var hasValidName: Bool { productName.trimmedOrNil != nil }

    /// The product page, adding "https://" if it was left off. Nil when
    /// the field is empty or isn't a web address.
    var parsedURL: URL? {
        guard var text = productURL.trimmedOrNil else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host(), host.contains(".")
        else { return nil }
        return url
    }

    var hasValidURL: Bool { productURL.trimmedOrNil == nil || parsedURL != nil }
}
