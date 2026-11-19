import SwiftUI

/// Five stars to set a rating from 1 to 5. Clicking a star sets the rating;
/// clicking the current one clears it. The arrow keys and 0–5 work while it
/// has keyboard focus, and VoiceOver adjusts it like a slider.
struct StarRatingControl: View {
    @Binding var stars: Int?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Kit.ratingRange, id: \.self) { value in
                Button {
                    stars = stars == value ? nil : value
                } label: {
                    StarImage(isFilled: value <= (stars ?? 0))
                }
                .buttonStyle(.plain)
                .help(stars == value ? "Clear the rating" : "Rate \(value) out of 5")
            }
        }
        .focusable()
        .onKeyPress(.rightArrow) { adjust(by: 1) }
        .onKeyPress(.upArrow) { adjust(by: 1) }
        .onKeyPress(.leftArrow) { adjust(by: -1) }
        .onKeyPress(.downArrow) { adjust(by: -1) }
        .onKeyPress(characters: CharacterSet(charactersIn: "012345")) { press in
            let value = Int(press.characters) ?? 0
            stars = value == 0 ? nil : value
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(StarRatingLabel.spokenText(stars))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = adjust(by: 1)
            case .decrement: _ = adjust(by: -1)
            @unknown default: break
            }
        }
    }

    private func adjust(by step: Int) -> KeyPress.Result {
        let value = min(max((stars ?? 0) + step, 0), Kit.ratingRange.upperBound)
        stars = value == 0 ? nil : value
        return .handled
    }
}

/// A rating shown as stars, or nothing when there's none.
struct StarRatingLabel: View {
    let stars: Int?

    var body: some View {
        if let stars {
            HStack(spacing: 1) {
                ForEach(Kit.ratingRange, id: \.self) { value in
                    StarImage(isFilled: value <= stars)
                        .imageScale(.small)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spokenText(stars))
        }
    }

    /// e.g. "3 stars", or "No rating".
    static func spokenText(_ stars: Int?) -> String {
        guard let stars else { return String(localized: "No rating") }
        return String(AttributedString(localized: "^[\(stars) star](inflect: true)").inflected().characters)
    }
}

private struct StarImage: View {
    let isFilled: Bool

    var body: some View {
        Image(systemName: isFilled ? "star.fill" : "star")
            .foregroundStyle(isFilled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    }
}
