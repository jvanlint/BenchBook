import Foundation

/// Paints to buy: not owned, and needed by a project that isn't Completed.
/// Grouped by brand, and saved as a plain-text checklist.
nonisolated struct PaintShoppingList: Equatable {
    struct Use: Equatable {
        let project: String
        let usedFor: String?
    }

    struct Item: Identifiable, Equatable {
        /// The paint's id.
        let id: UUID
        let brand: String
        let range: String
        let code: String
        let name: String
        let standard: String
        let swatchHex: String?
        let uses: [Use]

        /// e.g. "XF-54 Dark Sea Grey".
        var title: String { [code, name].filter { !$0.isEmpty }.joined(separator: " ") }

        /// e.g. "Acrylic XF · BS 640".
        var detail: String { [range, standard].filter { !$0.isEmpty }.joined(separator: " · ") }

        /// e.g. "F-16C (upper surfaces), Spitfire".
        var usesLine: String {
            uses.map { use in use.usedFor.map { "\(use.project) (\($0))" } ?? use.project }
                .joined(separator: ", ")
        }
    }

    struct BrandGroup: Identifiable, Equatable {
        /// The brand folded with `PaintIdentity.words`.
        let id: String
        let name: String
        let items: [Item]
    }

    /// Brands by name; each brand's paints by code.
    let groups: [BrandGroup]

    init(items: [Item]) {
        let names = Dictionary(
            PaintFilterOption.options(for: items.map(\.brand)).map { ($0.key, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        groups = Dictionary(grouping: items) { PaintIdentity.words($0.brand) }
            .map { key, items in
                BrandGroup(
                    id: key, name: names[key] ?? key,
                    items: items.sorted { $0.code.localizedStandardCompare($1.code) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Built from the projects' paint lists, so it only looks at paints
    /// that some project uses, however big the catalogue is.
    @MainActor
    init(selections: [ProjectPaint]) {
        var seen = Set<UUID>()
        let paints = selections.compactMap(\.selectedPaint).filter { seen.insert($0.id).inserted }
        self.init(items: paints.filter(\.isToBuy).map { paint in
            let uses = paint.unfinishedProjectSelections
                .compactMap { selection in
                    selection.project.map { Use(project: $0.name, usedFor: selection.usedFor?.trimmedOrNil) }
                }
                .sorted { $0.project.localizedStandardCompare($1.project) == .orderedAscending }
            return Item(id: paint.id, brand: paint.brand, range: paint.range, code: paint.code, name: paint.name,
                        standard: paint.standardCode, swatchHex: paint.swatchHex, uses: uses)
        })
    }

    var items: [Item] { groups.flatMap(\.items) }
    var isEmpty: Bool { groups.isEmpty }
    var projectCount: Int { Set(items.flatMap { $0.uses.map(\.project) }).count }

    /// e.g. "9 paints for 3 projects".
    var summary: String {
        String(AttributedString(
            localized: "^[\(items.count) paint](inflect: true) for ^[\(projectCount) project](inflect: true)"
        ).inflected().characters)
    }

    /// e.g. "Paint Shopping List 2026-11-09" (the Save dialog adds .txt).
    static func filename(on date: Date = .now) -> String {
        String(localized: "Paint Shopping List \(date.formatted(.iso8601.year().month().day()))")
    }

    /// A checklist grouped by brand, e.g.
    ///
    ///     Tamiya
    ///     ☐ XF-54 Dark Sea Grey · Acrylic XF · BS 640
    ///         F-16C (upper surfaces), Spitfire
    func text(on date: Date = .now) -> String {
        var lines = [
            String(localized: "Paint Shopping List"),
            "\(date.formatted(date: .long, time: .omitted)) · \(summary)",
        ]
        for group in groups {
            lines.append("")
            lines.append(group.name)
            for item in group.items {
                lines.append("☐ " + [item.title, item.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                if !item.uses.isEmpty {
                    lines.append("    \(item.usesLine)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
