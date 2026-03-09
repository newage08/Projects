import SwiftUI

@main
struct MyApp: App {
    // アプリ起動と同時にEKEventStoreの初期化を開始（黒画面短縮）
    @StateObject private var eventManager = EventStoreManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(eventManager)
        }
    }
}
