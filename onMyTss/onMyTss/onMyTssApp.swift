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
    @State private var storage: Result<ModelContainer, Error>?
    @State private var hasAttemptedOpen = false

    private static func makeModelContainer() throws -> ModelContainer {
        let schema = Schema(AppSchema.models)
        var inMemory = false
        var testStoreURL: URL?
        #if DEBUG
        inMemory = ProcessInfo.processInfo.arguments.contains("--v2-ui-tests")
        if inMemory && ProcessInfo.processInfo.arguments.contains("--v2-disk-history") {
            inMemory = false
            testStoreURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ohmytss-ui-\(UUID().uuidString).store")
        }
        #endif
        let modelConfiguration = testStoreURL.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)

        let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
        #if DEBUG
        if (inMemory || testStoreURL != nil) && ProcessInfo.processInfo.arguments.contains("--v2-large-history") {
            try LaunchHistoryFixture.seed(in: container, includeEstimates:
                !ProcessInfo.processInfo.arguments.contains("--v2-missing-estimates"))
        }
        if inMemory && ProcessInfo.processInfo.arguments.contains("--v2-rpe-demo") {
            try LaunchHistoryFixture.seedDashboard(in: container)
        }
        #endif
        return container
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch storage {
                case .success(let container):
                    ContentView().modelContainer(container)
                case .failure:
                    ContentUnavailableView {
                        Label("Saved data could not be opened", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("Your saved data has been kept. Try again. If this continues, contact support before reinstalling the app.")
                    } actions: {
                        Button("Try Again") { storage = nil }
                            .accessibilityIdentifier("storage.retry")
                    }
                case nil:
                    ProgressView("Opening saved data…")
                        .task { openStorage() }
                }
            }
            .tint(SwissStyle.accent)
            .fontDesign(.default)
            .background(SwissStyle.canvas.ignoresSafeArea())
            #if DEBUG
            .modifier(SwissAccessibilityFixture())
            #endif
        }
    }

    private func openStorage() {
        #if DEBUG
        if !hasAttemptedOpen && ProcessInfo.processInfo.arguments.contains("--v2-ui-tests")
            && ProcessInfo.processInfo.arguments.contains("--v2-storage-failure-once") {
            hasAttemptedOpen = true
            storage = .failure(NSError(domain: "ohmytss.synthetic-storage-test", code: 1))
            return
        }
        #endif
        hasAttemptedOpen = true
        storage = Result { try Self.makeModelContainer() }
    }
}
