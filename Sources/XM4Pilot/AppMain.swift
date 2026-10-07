import SwiftUI

@main
@MainActor
struct XM4PilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.environment.settings)
                .environmentObject(appDelegate.environment.headphones)
        }
    }
}
