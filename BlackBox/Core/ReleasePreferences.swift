import Foundation

// Preserve model choices and favorites when upgrading from the development bundle ID.
enum ReleasePreferences {
    static func migrate(defaults: UserDefaults = .standard,
                        legacyDomain: String = "devplaceholder.XNWH5DNS.BlackBox") {
        let marker = "migratedDevelopmentPreferences"
        guard !defaults.bool(forKey: marker) else { return }
        let legacy = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        let keys = ["aiProvider"] + AIProvider.allCases.flatMap {
            [$0.modelPreferenceKey, $0.modelCatalogCacheKey,
             $0 == .openRouter ? "openRouterFavoriteModels" : "\($0.rawValue)FavoriteModels"]
        }
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy[key] { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: marker)
    }
}
