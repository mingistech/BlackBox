import XCTest
@testable import BlackBoxCore

final class ReleasePreferencesTests: XCTestCase {
    func testMigrationPreservesChoicesWithoutOverwritingNewPreferences() {
        let name = "ReleasePreferencesTests.\(UUID().uuidString)"
        let legacy = name + ".legacy"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            defaults.removePersistentDomain(forName: legacy)
        }
        defaults.setPersistentDomain(["aiProvider": "openAI", "openAIModel": "gpt-5.6-sol",
                                      "openAIFavoriteModels": ["gpt-5.6-sol"], "unrelated": "ignore"], forName: legacy)
        defaults.set("anthropic", forKey: "aiProvider")
        ReleasePreferences.migrate(defaults: defaults, legacyDomain: legacy)
        XCTAssertEqual(defaults.string(forKey: "aiProvider"), "anthropic")
        XCTAssertEqual(defaults.string(forKey: "openAIModel"), "gpt-5.6-sol")
        XCTAssertEqual(defaults.stringArray(forKey: "openAIFavoriteModels"), ["gpt-5.6-sol"])
        XCTAssertNil(defaults.object(forKey: "unrelated"))
        defaults.removeObject(forKey: "openAIFavoriteModels")
        ReleasePreferences.migrate(defaults: defaults, legacyDomain: legacy)
        XCTAssertNil(defaults.object(forKey: "openAIFavoriteModels"))
    }
}
