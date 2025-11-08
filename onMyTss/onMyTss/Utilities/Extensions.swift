//
//  Extensions.swift
//  onMyTss
//
//  Created by Claude Code
//

import Foundation
import SwiftUI

// MARK: - Date Extensions

extension Date {
    /// Returns the start of the day for the date
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    /// Returns the end of the day for the date
    var endOfDay: Date {
        var components = DateComponents()
        components.day = 1
        components.second = -1
        return Calendar.current.date(byAdding: components, to: startOfDay) ?? self
    }

    /// Returns a date offset by the specified number of days
    func addingDays(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }

    /// Returns the number of days between this date and another date
    func daysBetween(_ otherDate: Date) -> Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: startOfDay, to: otherDate.startOfDay)
        return abs(components.day ?? 0)
    }

    /// Returns a short date string (e.g., "Jan 1")
    var shortDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: self)
    }

    /// Returns a full date string (e.g., "Monday, January 1, 2024")
    var fullDateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter.string(from: self)
    }

    /// Returns the weekday name (e.g., "Monday")
    var weekdayName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: self)
    }

    /// Returns true if the date is today
    var isToday: Bool {
        Calendar.current.isDateInToday(self)
    }

    /// Returns true if the date is yesterday
    var isYesterday: Bool {
        Calendar.current.isDateInYesterday(self)
    }
}

// MARK: - Double Extensions

extension Double {
    /// Rounds to the specified number of decimal places
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }

    /// Returns a formatted string with the specified decimal places
    func formatted(decimalPlaces: Int = 1) -> String {
        String(format: "%.\(decimalPlaces)f", self)
    }

    /// Clamps the value between min and max
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Int Extensions

extension Int {
    /// Clamps the value between min and max
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Array Extensions

extension Array where Element == Double {
    /// Calculates the exponential moving average
    func exponentialMovingAverage(timeConstant: Double) -> [Double] {
        guard !isEmpty else { return [] }

        var ema: [Double] = []
        var currentEMA = first!

        for value in self {
            currentEMA = currentEMA + (1.0 / timeConstant) * (value - currentEMA)
            ema.append(currentEMA)
        }

        return ema
    }

    /// Calculates the simple moving average
    func average() -> Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }

    /// Calculates the sum
    var sum: Double {
        reduce(0, +)
    }

    /// Returns the maximum value or 0 if empty
    var maxValue: Double {
        self.max() ?? 0
    }

    /// Returns the minimum value or 0 if empty
    var minValue: Double {
        self.min() ?? 0
    }
}

// MARK: - Color Extensions

extension Color {
    /// Color for very low Body Battery score (0-20)
    static let bodyBatteryVeryLow = Color.red

    /// Color for low Body Battery score (20-40)
    static let bodyBatteryLow = Color.orange

    /// Color for medium Body Battery score (40-60)
    static let bodyBatteryMedium = Color.yellow

    /// Color for good Body Battery score (60-80)
    static let bodyBatteryGood = Color.green

    /// Color for excellent Body Battery score (80-100)
    static let bodyBatteryExcellent = Color.blue

    /// Returns the appropriate color for a given Body Battery score
    static func bodyBatteryColor(for score: Int) -> Color {
        switch score {
        case 0..<20:
            return .bodyBatteryVeryLow
        case 20..<40:
            return .bodyBatteryLow
        case 40..<60:
            return .bodyBatteryMedium
        case 60..<80:
            return .bodyBatteryGood
        default:
            return .bodyBatteryExcellent
        }
    }

    /// Returns a gradient for the Body Battery gauge
    static var bodyBatteryGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [
                .bodyBatteryVeryLow,
                .bodyBatteryLow,
                .bodyBatteryMedium,
                .bodyBatteryGood,
                .bodyBatteryExcellent
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Initialize Color from hex string (e.g., "#FF0000" or "FF0000")
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b: UInt64
        switch hex.count {
        case 6: // RGB (24-bit)
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}
