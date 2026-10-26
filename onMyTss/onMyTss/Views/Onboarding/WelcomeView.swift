//
//  WelcomeView.swift
//  onMyTss
//
//  Created by Claude Code
//

import SwiftUI

struct WelcomeView: View {
    var onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                SwissSectionHeading(number: "01", title: AppIdentity.name)
                Divider()
                Text("Your daily\nreadiness.")
                    .font(.largeTitle.weight(.semibold)).tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Training, recovery and how your muscles feel. One clear view of your day.")
                    .font(.body).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 24) {
                    FeatureRow(icon: "figure.outdoor.cycle", title: "Track your training",
                               description: "Workouts from Apple Health and Strava")
                    Divider()
                    FeatureRow(icon: "chart.line.uptrend.xyaxis", title: "Follow your trends",
                               description: "Readiness and training load over time")
                    Divider()
                    FeatureRow(icon: "figure.stand", title: "Check in with your muscles",
                               description: "A quick effort rating, whenever useful")
                }
                .padding(.vertical, 8)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24).frame(maxWidth: .infinity)
        }
        .swissCanvas()
        .safeAreaInset(edge: .bottom) {
            Button(action: onContinue) {
                Text("Get Started").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
            }
            .swissAction(prominent: true)
            .padding(24).background(SwissStyle.canvas)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.title3.weight(.regular))
                .foregroundStyle(SwissStyle.accent)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    WelcomeView(onContinue: {})
}
