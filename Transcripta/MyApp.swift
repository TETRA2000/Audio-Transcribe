import SwiftUI

@main struct MyApp: App {
    /// History's on-device store. If it can't be opened, the app works without History and says why.
    private let history = Result { try HistoryStore() }

    var body: some Scene {
        WindowGroup {
            ContentView(history: history)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 640)
        #endif
    }
}
