import SwiftUI

@main
struct VideoScribeApp: App {
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup("VideoScribe") {
            ContentView()
                .environmentObject(settings)
                .frame(minWidth: 640, minHeight: 480)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .frame(width: 520)
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { settings.save() }
    }

    init() {
        self.settings = AppSettings.load()
    }
}
