import SwiftUI
import SwiftData

@main
struct ZPasteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppPreferences.registerDefaults()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .modelContainer(Store.container)
        } label: {
            Label("z-paste", systemImage: "doc.on.clipboard")
        }
        .menuBarExtraStyle(.window)
    }
}