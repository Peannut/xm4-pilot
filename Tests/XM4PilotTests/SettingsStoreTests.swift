import Foundation
import Testing
@testable import XM4Pilot

@MainActor
struct SettingsStoreTests {
    @Test func defaultsAndPersistence() throws {
        let suiteName = "local.xm4pilot.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        #expect(settings.reconnectAutomatically)
        #expect(settings.globalShortcutEnabled)
        #expect(settings.customEqualizerDraft == .flat)

        settings.reconnectAutomatically = false
        settings.globalShortcutEnabled = false
        settings.customEqualizerDraft = EqualizerSettings(clearBass: 4, bands: [1, 2, 3, 4, 5])
        let profile = settings.saveEqualizerProfile(named: "Night")

        #expect(!SettingsStore(defaults: defaults).reconnectAutomatically)
        #expect(!SettingsStore(defaults: defaults).globalShortcutEnabled)
        let restored = SettingsStore(defaults: defaults)
        #expect(restored.customEqualizerDraft == settings.customEqualizerDraft)
        #expect(restored.equalizerProfiles == [profile])
    }
}
