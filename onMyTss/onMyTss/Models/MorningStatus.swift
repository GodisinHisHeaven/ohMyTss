import Foundation

struct MorningStatus: Decodable, Equatable {
    struct AppSummary: Decodable, Equatable {
        let readinessScore: Int?
        let sleepHours: Double?
        let trainingMinutes7d: Int
        enum CodingKeys: String, CodingKey {
            case readinessScore, sleepHours
            case trainingMinutes7d = "trainingMinutes7D"
        }
    }
    struct Wellness: Decodable, Equatable {
        let hrv: Double?
        let restingHr: Double?
        let sleepHours: Double?
        let tsb: Double?
    }

    let displayName: String
    let email: String
    let phoneHint: String?
    let timezone: String
    let localDate: String
    let windowStart: String
    let windowEnd: String
    let smsState: String
    let smsEnabled: Bool
    let sentToday: Bool
    let hasTodayData: Bool
    let inDeliveryWindow: Bool
    let wellness: Wellness?
    let lastActivitySync: String?
    let wellnessThrough: String?
    let syncFailures: Int
    var dataSource: String? = nil
    var appSummaryConsent: Bool? = nil
    var requiresSmsRestart: Bool? = nil
    var appSummary: AppSummary? = nil

    var usesAppSummary: Bool { dataSource == "app" }
    var canUploadSummary: Bool { usesAppSummary && appSummaryConsent == true && smsEnabled }

    var subscriptionLabel: String {
        switch smsState {
        case "active": "Subscribed"
        case "not_subscribed": "Not subscribed"
        case "no_phone": "No phone connected"
        case "paused": "Delivery paused"
        default: "Status unavailable"
        }
    }

    var deliveryDescription: String {
        if sentToday { return "Today's message was submitted for delivery." }
        if !smsEnabled { return "Morning texts are not enabled." }
        if !hasTodayData { return "Open the app and sync today's summary." }
        if inDeliveryWindow { return "Today's data is available. The next scheduled check can send your message." }
        return "Outside the morning window. Messages are sent only with current-day data."
    }
}
