import SwiftUI

@main
struct MarginApp: App {
    @State private var library = Library()
    @AppStorage("theme") private var theme = "system"
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(id: "library") {
            LibraryView(library: library)
                .preferredColorScheme(theme == "dark" ? .dark : theme == "light" ? .light : nil)
                .onChange(of: scenePhase) { _, phase in
                    LocalLLM.shared.setInBackground(phase == .background)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    LocalLLM.shared.unload()
                }
        }
    }
}
