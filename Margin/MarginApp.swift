import SwiftUI
import os

@main
struct MarginApp: App {
    @State private var library = Library()
    @AppStorage("theme") private var theme = "system"
    @Environment(\.scenePhase) private var scenePhase

    // The library's titles are the one place Margin speaks in its own voice, like a heading on a notebook's cover.
    private static let serifTitles: Void = {
        let title = UIFont.preferredFont(forTextStyle: .largeTitle)
        let serif = title.fontDescriptor.withDesign(.serif)?.withSymbolicTraits(.traitBold)
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: UIFont(descriptor: serif ?? title.fontDescriptor, size: 34))]
    }()

    var body: some Scene {
        WindowGroup(id: "library") {
            let _ = Self.serifTitles
            LibraryView(library: library)
                .preferredColorScheme(theme == "dark" ? .dark : theme == "light" ? .light : nil)
                .onChange(of: scenePhase) { _, phase in
                    LocalLLM.shared.setInBackground(phase == .background)
                    if phase == .active { Task { await library.sync() } }
                    if phase == .background { syncBeforeSuspending() }
                }
                .task { await library.sync() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    // iOS warns the moment the writing model is busy, long before Margin is in danger.
                    // Reloading it on every warning would make each question start from nothing.
                    guard os_proc_available_memory() < 500_000_000 else { return }
                    LocalLLM.shared.unload()
                    LocalWhisper.shared.unload()
                }
        }
    }

    private static var backgroundSync = UIBackgroundTaskIdentifier.invalid

    private static func endBackgroundSync() {
        guard backgroundSync != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundSync)
        backgroundSync = .invalid
    }

    private func syncBeforeSuspending() {
        Self.endBackgroundSync()
        Self.backgroundSync = UIApplication.shared.beginBackgroundTask { Self.endBackgroundSync() }
        Task {
            await library.sync()
            Self.endBackgroundSync()
        }
    }
}
