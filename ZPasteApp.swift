import SwiftUI

@main
struct ZPasteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppPreferences.registerDefaults()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Label("z-paste", systemImage: "doc.on.clipboard")
        }
        .menuBarExtraStyle(.window)
    }
}