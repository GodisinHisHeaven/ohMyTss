import Foundation

struct MorningStatus: Decodable, Equatable {
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
        if !hasTodayData { return "Waiting for today's wellness data." }
        if inDeliveryWindow { return "Today's data is available. The next scheduled check can send your message." }
        return "Outside the morning window. Messages are sent only with current-day data."
    }
}
