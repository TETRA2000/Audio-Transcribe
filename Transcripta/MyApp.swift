import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 600)
        #endif
    }
}
