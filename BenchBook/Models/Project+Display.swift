import Foundation

extension Project {
    /// A short line such as "Tamiya · 1:48 · F-16CJ Block 50", skipping blank fields.
    var summary: String {
        [manufacturer, scale, subject]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
