import SwiftUI

@main
struct MarginApp: App {
    @State private var library = Library()
    @AppStorage("theme") private var theme = "system"

    var body: some Scene {
        WindowGroup(id: "library") {
            LibraryView(library: library)
                .preferredColorScheme(theme == "dark" ? .dark : theme == "light" ? .light : nil)
        }
    }
}
