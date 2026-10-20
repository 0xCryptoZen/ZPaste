import SwiftUI
import SwiftData

@main
struct PasteCloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .modelContainer(Store.container)
        } label: {
            Label("PasteClone", systemImage: "doc.on.clipboard")
        }
        .menuBarExtraStyle(.window)
    }
}
