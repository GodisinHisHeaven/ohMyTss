import SwiftUI
import SharedUI

struct TodayView: View {
    @State private var viewModel = TodayViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        // Gauge
                        BodyBatteryGauge(
                            score: viewModel.todayScore,
                            zoneColor: viewModel.zoneColor
                        )
                        .frame(width: 200, height: 200)

                        // Zone name and TSB
                        VStack(spacing: 8) {
                            Text(viewModel.readinessZone.name)
                                .font(.title2.bold())

                            Text("Freshness (TSB): \(viewModel.tsbFormatted)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // Guidance card
                        TSSGuidanceCard(
                            tssRange: viewModel.suggestedTSSRange,
                            description: viewModel.guidanceText
                        )

                        // 7-day trend
                        WeekTrendView(scores: viewModel.last7Days)

                        // Actions
                        HStack(spacing: 16) {
                            Button {
                                Task {
                                    await viewModel.refresh()
                                }
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Body Battery")
            .task {
                await viewModel.load()
            }
        }
    }
}

#Preview {
    TodayView()
}
