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
        VStack(spacing: 30) {
            Spacer()

            // App Icon/Logo
            Image(systemName: "bolt.heart.fill")
                .font(.system(size: 80))
                .foregroundStyle(.linearGradient(
                    colors: [.blue, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .padding(.bottom, 20)

            // Title
            Text("Body Battery")
                .font(.largeTitle)
                .fontWeight(.bold)

            // Subtitle
            Text("Your Daily Readiness Score")
                .font(.title3)
                .foregroundColor(.secondary)

            Spacer()

            // Features
            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    icon: "figure.outdoor.cycle",
                    title: "Track Your Training",
                    description: "Automatically analyze workouts from Apple Health"
                )

                FeatureRow(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "Monitor Load",
                    description: "See your fitness, fatigue, and form metrics"
                )

                FeatureRow(
                    icon: "lightbulb.fill",
                    title: "Get Guidance",
                    description: "Receive personalized training recommendations"
                )
            }
            .padding(.horizontal)

            Spacer()

            // Continue Button
            Button(action: onContinue) {
                Text("Get Started")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(12)
            }
            .padding(.horizontal)
            .padding(.bottom, 30)
        }
        .padding()
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
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
