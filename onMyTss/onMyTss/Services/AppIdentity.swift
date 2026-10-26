import Foundation

enum AppIdentity {
    static let name = "ohMyTss"
    // Keep the deployed host so existing SMS, OAuth and account links stay valid.
    static let serviceHost = "coach-ota.fly.dev"
    static let accountURL = URL(string: "https://\(serviceHost)/login")!
    static let servicePrivacyURL = URL(string: "https://\(serviceHost)/privacy")!
    static let websiteURL = URL(string: "https://godisinhisheaven.github.io/ohMyTss/")!
}
