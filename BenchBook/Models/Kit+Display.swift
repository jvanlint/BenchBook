import Foundation

/// How far along one kit is. Stored as `Kit.statusRaw`.
nonisolated enum KitStatus: String, CaseIterable, Identifiable, Sendable {
    /// Brand new in box: still sealed or untouched.
    case bnib
    case opened
    /// Work in progress, on the bench.
    case wip
    case built

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bnib: String(localized: "BNIB")
        case .opened: String(localized: "Opened")
        case .wip: String(localized: "WIP")
        case .built: String(localized: "Built")
        }
    }

    /// What BNIB stands for, for help tags and VoiceOver.
    var longName: String {
        switch self {
        case .bnib: String(localized: "Brand New in Box")
        case .opened: String(localized: "Opened")
        case .wip: String(localized: "Work in Progress")
        case .built: String(localized: "Built")
        }
    }
}

extension Kit {
    /// Unknown values, e.g. from a newer version, read as BNIB. Reading never
    /// changes the stored value; only setting a status does.
    var status: KitStatus {
        get { KitStatus(rawValue: statusRaw) ?? .bnib }
        set { statusRaw = newValue.rawValue }
    }

    /// The rating as stars, 1 to 5, or nil. Out-of-range stored values,
    /// e.g. from a newer version, read as no rating.
    var stars: Int? {
        get { rating.flatMap { Self.ratingRange.contains($0) ? $0 : nil } }
        set { rating = newValue.flatMap { Self.ratingRange.contains($0) ? $0 : nil } }
    }

    static let ratingRange = 1...5
}

extension Kit {
    /// e.g. "Italeri 1:72 Super Cobra (1234)".
    var displayName: String {
        [brand, scale, name].compactMap { $0?.trimmedOrNil }.joined(separator: " ")
            + (number?.trimmedOrNil.map { " (\($0))" } ?? "")
    }

    // Sort keys for the table. Optional values sort after filled ones.

    var scaleSortKey: String { scale ?? "" }
    var numberSortKey: String { number ?? "" }
    /// BNIB, Opened, WIP, Built, then kits that aren't owned.
    var statusSortKey: Int { isOwned ? (KitStatus.allCases.firstIndex(of: status) ?? 0) : KitStatus.allCases.count }
    /// Highest rating first, unrated last.
    var ratingSortKey: Int { 6 - (stars ?? 0) }
    var pricePaidSortKey: Decimal { pricePaid ?? .greatestFiniteMagnitude }
    var salePriceSortKey: Decimal { salePrice ?? .greatestFiniteMagnitude }
    var forSaleSortKey: Int { isForSale ? 0 : 1 }
}

/// When two kit entries are copies of the same kit.
nonisolated enum KitIdentity {
    /// Two entries are the same kit when they have the same Scalemates
    /// address, or the same brand, number and scale. Without a number,
    /// brand and scale alone are too loose, so only the address counts.
    static func isSameKit(
        brand: String, number: String?, scale: String?, link: URL?,
        as other: (brand: String, number: String?, scale: String?, link: URL?)
    ) -> Bool {
        if let key = scalematesKey(link), key == scalematesKey(other.link) { return true }
        guard let number = fold(number), !number.isEmpty else { return false }
        return fold(brand) == fold(other.brand) && number == fold(other.number) && (fold(scale) ?? "") == (fold(other.scale) ?? "")
    }

    /// A Scalemates page address without "www.", query or trailing slash,
    /// in lower case. Nil for other sites.
    static func scalematesKey(_ url: URL?) -> String? {
        guard let url, var host = url.host()?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard host == "scalemates.com" || host.hasSuffix(".scalemates.com") else { return nil }
        var path = url.path().lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }

    /// Lower case, without spaces.
    static func fold(_ text: String?) -> String? {
        text.map { $0.lowercased().filter { !$0.isWhitespace } }
    }
}

extension Kit {
    func isSameKit(as other: Kit) -> Bool {
        KitIdentity.isSameKit(brand: brand, number: number, scale: scale, link: link,
                              as: (other.brand, other.number, other.scale, other.link))
    }
}

/// Amounts of money typed by the user or read from a file.
nonisolated enum KitPrice {
    /// Reads "25", "25.00", "25,00", "$18.50", "1,250.00" or "1.250,00".
    /// Nil for empty, negative or unreadable text.
    ///
    /// - With both "." and ",", the last one is the decimal point.
    /// - One separator used more than once groups thousands: "1,250,000".
    /// - One separator used once is the decimal point, unless it has one to
    ///   three digits before it and exactly three after: "1,250" is 1250.
    static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("-") else { return nil }
        // Leaves out currency symbols and codes, and spaces grouping thousands.
        let kept = trimmed.filter { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }
        guard kept.contains(where: \.isNumber) else { return nil }

        let separatorKinds = Set(kept.filter { $0 == "." || $0 == "," })
        let decimalPoint: Character?
        if separatorKinds.count == 2 {
            decimalPoint = kept.last { $0 == "." || $0 == "," }
        } else if let only = separatorKinds.first {
            let parts = kept.split(separator: only, omittingEmptySubsequences: false)
            let groupsThousands = parts.count > 2
                || (parts.count == 2 && (1...3).contains(parts[0].count) && parts[0] != "0" && parts[1].count == 3)
            decimalPoint = groupsThousands ? nil : only
        } else {
            decimalPoint = nil
        }

        let plain = String(kept.compactMap { character -> Character? in
            if character.isNumber { return character }
            return character == decimalPoint ? "." : nil
        })
        return Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// A plain number with a full stop and two decimals, e.g. "25.00", for
    /// files and backups.
    static func plain(_ amount: Decimal) -> String {
        amount.formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// In the Mac's currency and format, e.g. "$18.50".
    static func display(_ amount: Decimal, locale: Locale = .current) -> String {
        amount.formatted(.currency(code: locale.currency?.identifier ?? "USD").locale(locale))
    }
}

/// The kit editor's fields, as typed. Nothing is saved until Save.
struct KitDraft: Equatable {
    var brand = ""
    var name = ""
    var scale = ""
    var number = ""
    var isOwned = true
    var status = KitStatus.bnib
    var stars: Int?
    var link = ""
    var pricePaid = ""
    var isForSale = false
    var salePrice = ""
    var notes = ""

    init() {}

    init(kit: Kit) {
        brand = kit.brand
        name = kit.name
        scale = kit.scale ?? ""
        number = kit.number ?? ""
        isOwned = kit.isOwned
        status = kit.status
        stars = kit.stars
        link = kit.link?.absoluteString ?? ""
        pricePaid = kit.pricePaid.map(KitPrice.plain) ?? ""
        isForSale = kit.isForSale
        salePrice = kit.salePrice.map(KitPrice.plain) ?? ""
        notes = kit.notes ?? ""
    }

    var hasValidBrand: Bool { brand.trimmedOrNil != nil }
    var hasValidName: Bool { name.trimmedOrNil != nil }
    var parsedLink: URL? { WebAddress.parse(link) }
    var hasValidLink: Bool { link.trimmedOrNil == nil || parsedLink != nil }
    var hasValidPricePaid: Bool { pricePaid.trimmedOrNil == nil || KitPrice.parse(pricePaid) != nil }
    var hasValidSalePrice: Bool { salePrice.trimmedOrNil == nil || KitPrice.parse(salePrice) != nil }

    var isValid: Bool {
        hasValidBrand && hasValidName && hasValidLink && hasValidPricePaid && hasValidSalePrice
    }
}

/// Which kits the Kits screen shows.
struct KitFilter: Equatable {
    enum Ownership: String, CaseIterable, Identifiable {
        case all, owned, notOwned, forSale
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: String(localized: "All Kits")
            case .owned: String(localized: "Owned")
            case .notOwned: String(localized: "Not Owned")
            case .forSale: String(localized: "For Sale")
            }
        }
    }

    /// A `PaintFilterOption.key`; nil shows every brand.
    var brand: String?
    /// A `PaintFilterOption.key`; nil shows every scale.
    var scale: String?
    /// Only owned kits have a status, so choosing one shows owned kits only.
    var status: KitStatus?
    var ownership = Ownership.all

    var isActive: Bool { brand != nil || scale != nil || status != nil || ownership != .all }

    func includes(_ kit: Kit) -> Bool {
        (brand == nil || PaintIdentity.words(kit.brand) == brand)
            && (scale == nil || PaintIdentity.words(kit.scale ?? "") == scale)
            && (status == nil || (kit.isOwned && kit.status == status))
            && includesOwnership(of: kit)
    }

    private func includesOwnership(of kit: Kit) -> Bool {
        switch ownership {
        case .all: true
        case .owned: kit.isOwned
        case .notOwned: !kit.isOwned
        case .forSale: kit.isForSale
        }
    }
}
