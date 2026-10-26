import Foundation

enum AppIdentity {
    static let name = "ohMyTss"
    // Keep the deployed host so existing SMS, OAuth and account links stay valid.
    static let serviceHost = "coach-ota.fly.dev"
    static let mobileAPIURL = URL(string: "https://\(serviceHost)/api/mobile")!
    static let websiteURL = URL(string: "https://godisinhisheaven.github.io/ohMyTss/")!
}
