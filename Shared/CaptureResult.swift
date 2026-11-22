import Foundation

/// What happened to a capture, written by BenchBook after importing an
/// envelope from the Safari extension, so the extension can tell the user.
nonisolated struct CaptureResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case saved
        /// Everything in it is already in the project.
        case duplicate
        case failed
    }

    var envelopeID: UUID
    var status: Status
    var projectName: String?
    /// Why it failed, for `.failed`.
    var message: String?
    /// The References added or amended, so Change… can move them.
    var referenceIDs: [UUID] = []
}

/// Results waiting for the extension in the App Group, one file per envelope:
///
///     Results/<envelope id>.json
nonisolated struct CaptureResultStore: Sendable {
    let resultsURL: URL

    private func fileURL(for envelopeID: UUID) -> URL {
        resultsURL.appending(path: "\(envelopeID.uuidString).json", directoryHint: .notDirectory)
    }

    func write(_ result: CaptureResult) throws {
        try FileManager.default.createDirectory(at: resultsURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        try encoder.encode(result).write(to: fileURL(for: result.envelopeID), options: .atomic)
    }

    /// Reads and removes the result, if it has arrived.
    func take(_ envelopeID: UUID) -> CaptureResult? {
        let url = fileURL(for: envelopeID)
        guard let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(CaptureResult.self, from: data)
        else { return nil }
        try? FileManager.default.removeItem(at: url)
        return result
    }

    /// Removes results nobody collected, such as after the extension gave up waiting.
    func removeStale(now: Date = .now) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: resultsURL, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in contents {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) > 24 * 60 * 60 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
