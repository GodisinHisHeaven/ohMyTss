//
//  OnboardingContainerView.swift
//  onMyTss
//
//  Created by Claude Code
//

import SwiftUI
import SwiftData

struct OnboardingContainerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentStep: OnboardingStep = .welcome
    @State private var healthKitManager = HealthKitManager()

    var onComplete: () -> Void

    private var dataStore: DataStore {
        DataStore(modelContext: modelContext)
    }

    var body: some View {
        Group {
            switch currentStep {
            case .welcome:
                WelcomeView {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        currentStep = .healthPermission
                    }
                }

            case .healthPermission:
                HealthPermissionView(
                    healthKitManager: healthKitManager,
                    onContinue: {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            currentStep = .thresholdInput
                        }
                    }
                )

            case .thresholdInput:
                ThresholdInputView(
                    dataStore: dataStore,
                    onComplete: {
                        onComplete()
                    }
                )
            }
        }
        .transition(reduceMotion ? .identity : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
        #if DEBUG
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--v2-ui-tests") && arguments.contains("--swiss-threshold-preview") {
                currentStep = .thresholdInput
            }
        }
        #endif
    }
}

enum OnboardingStep {
    case welcome
    case healthPermission
    case thresholdInput
}

#Preview {
    OnboardingContainerView(onComplete: {})
        .modelContainer(for: [UserThresholds.self, DayAggregate.self, AppState.self])
}
