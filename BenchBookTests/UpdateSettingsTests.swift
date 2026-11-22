import Foundation
import Testing
@testable import BenchBook

/// Sparkle's settings in the app's Info.plist. A mistake here can stop
/// every copy of BenchBook from updating, so they're checked on each run.
struct UpdateSettingsTests {
    private let info = Bundle.main.infoDictionary ?? [:]

    @Test func checksTheWebsiteFeed() {
        #expect(info["SUFeedURL"] as? String == "https://jvanlint.github.io/BenchBook-Site/appcast.xml")
    }

    @Test func hasAnEdDSAPublicKey() throws {
        let key = try #require(info["SUPublicEDKey"] as? String)
        #expect(Data(base64Encoded: key)?.count == 32, "SUPublicEDKey should be the key generate_keys prints")
    }

    @Test func updatesAreVerifiedAndNeverInstallSilently() {
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
        // Sparkle asks on the second launch whether to check automatically.
        #expect(info["SUEnableAutomaticChecks"] == nil)
    }

    @Test func installsFromTheSandbox() {
        #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
    }
}
