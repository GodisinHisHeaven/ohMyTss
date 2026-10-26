//
//  ohMyTssApp.swift
//  ohMyTss
//
//  Created by Mingjun Liu on 11/7/25.
//

import SwiftUI
import SwiftData

@main
struct ohMyTssApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema(AppSchema.models)
        var inMemory = false
        #if DEBUG
        inMemory = ProcessInfo.processInfo.arguments.contains("--v2-ui-tests")
        #endif
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            #if DEBUG
            if inMemory && ProcessInfo.processInfo.arguments.contains("--v2-large-history") {
                try LaunchHistoryFixture.seed(in: container, includeEstimates:
                    !ProcessInfo.processInfo.arguments.contains("--v2-missing-estimates"))
            }
            #endif
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
