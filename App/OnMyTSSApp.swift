import SwiftUI
import SwiftData

@main
struct OnMyTSSApp: App {
    @State private var dataStore = DataStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(dataStore)
        }
        .modelContainer(dataStore.modelContainer)
    }
}
