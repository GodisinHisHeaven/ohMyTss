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
                    withAnimation {
                        currentStep = .healthPermission
                    }
                }

            case .healthPermission:
                HealthPermissionView(
                    healthKitManager: healthKitManager,
                    onContinue: {
                        withAnimation {
                            currentStep = .thresholdInput
                        }
                    },
                    onSkip: {
                        withAnimation {
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
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
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
