import SwiftUI
import Charts

struct HistoryView: View {
    @State private var timeRange: TimeRange = .month

    enum TimeRange: String, CaseIterable {
        case week = "7D"
        case month = "30D"
        case threeMonths = "90D"
    }

    var body: some View {
        NavigationStack {
            VStack {
                // Time range picker
                Picker("Range", selection: $timeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                // Placeholder for charts
                VStack(spacing: 20) {
                    chartPlaceholder(title: "Body Battery")
                    chartPlaceholder(title: "CTL / ATL / TSB")
                    chartPlaceholder(title: "Daily TSS")
                }
                .padding()

                Spacer()
            }
            .navigationTitle("History")
        }
    }

    private func chartPlaceholder(title: String) -> some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.headline)

            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray6))
                .frame(height: 150)
                .overlay(
                    Text("Chart placeholder")
                        .foregroundStyle(.secondary)
                )
        }
    }
}

#Preview {
    HistoryView()
}
