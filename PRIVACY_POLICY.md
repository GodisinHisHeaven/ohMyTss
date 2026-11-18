# Privacy Policy for ohMyTss

**Last Updated:** November 18, 2026

## Introduction

ohMyTss ("we," "our," or "the app") is committed to protecting your privacy. This Privacy Policy explains how we collect, use, and safeguard your health and fitness data when you use our iOS application.

## Information We Collect

### HealthKit Data

ohMyTss requests access to the following types of health and fitness data from Apple HealthKit:

- **Workout Data**: Exercise sessions including type, duration, distance, and calories
- **Heart Rate Data**: Heart rate measurements during workouts
- **Heart Rate Variability (HRV)**: HRV measurements for recovery analysis
- **Cycling Power Data**: Power output measurements from cycling workouts (when available)

### Optional Strava and Morning Status SMS

If you connect Strava, the iOS app reads your authorized activity and athlete
profile data and stores access credentials in the iOS Keychain. OAuth and API
requests go to Strava.

Morning texts, phone verification, and app-summary uploads have ended. The private service retains existing accounts, consent, delivery history, and the latest shared summary on encrypted storage. The former SMS feature used Twilio to verify phone numbers and deliver texts. With separate consent, it sent only readiness, sleep duration, and seven-day training minutes from the app. Raw HealthKit samples, routes, and muscle notes stayed on the device.

The [service privacy notice](https://coach-ota.fly.dev/privacy) describes historical records and requests for account data.

We do not collect payment information or advertising identifiers.

## How We Use Your Data

We use the health data you authorize solely for the following purposes:

1. **Calculate Training Stress Score (TSS)**: Analyze workout intensity based on power output or heart rate
2. **Calculate Training Load Metrics**: Compute Chronic Training Load (CTL), Acute Training Load (ATL), and Training Stress Balance (TSB)
3. **Generate Body Battery Score**: Calculate your daily readiness score (0-100) based on training load
4. **Provide Training Guidance**: Offer personalized training recommendations based on your current fitness state
5. **Display Historical Trends**: Show your training load and readiness trends over time

## Data Storage and Security

### iOS HealthKit Storage

- HealthKit data and calculated metrics are stored locally using Apple's SwiftData framework
- Optional Strava requests use the connection described above
- Data is protected by iOS sandboxing and encryption mechanisms

### No Account Required

The iOS HealthKit features do not require an account. Strava requires separate authorization.

## Data You Control

### Your Rights

You have complete control over your data:

- **Access**: View all calculated metrics within the app
- **Sync**: Reset source checkpoints through **Reset Activity Sync** in Settings
- **HealthKit Permissions**: Revoke HealthKit access at any time through iOS Settings → Health → Data Access & Devices → ohMyTss

### Reset Activity Sync

Resetting sync keeps saved workouts, metrics, estimates, and notes. The next sync rechecks Apple Health and connected Strava activity. Existing web account records are managed separately.

## HealthKit-Specific Disclosures

### Required by Apple HealthKit Guidelines

- **No Advertising**: We do not use HealthKit data for advertising, marketing, or data mining purposes
- **No Selling**: We do not sell your health data to third parties
- **No Third-Party Sharing**: We do not share HealthKit data with third parties without your explicit consent
- **Health & Fitness Use Only**: HealthKit data is used exclusively for health, fitness, and wellness management

### Data You Write to HealthKit

ohMyTss is **read-only** and does not write any data to HealthKit. We only read workout and health data with your permission.

## Changes to Metrics and Thresholds

### User-Provided Data

For local training calculations, you can provide:

- **Functional Threshold Power (FTP)**: Used to calculate cycling TSS accurately
- This is stored locally and can be updated anytime in Settings

## Children's Privacy

ohMyTss is intended for users aged 13 and older. We do not knowingly collect data from children under 13. If you are a parent or guardian and believe your child has provided data to our app, please contact us.

## Changes to This Privacy Policy

We may update this Privacy Policy from time to time. Changes will be reflected in the "Last Updated" date at the top of this policy. Continued use of the app after changes constitutes acceptance of the updated policy.

## Third-Party Services

ohMyTss does not use third-party analytics or advertising. Strava and the private backend process the data described above.

## International Users

Raw iOS HealthKit data stays on your device. See the SMS section above for the prior processing and continued retention of shared summaries and account data.

## Your Consent

By using ohMyTss and granting HealthKit permissions, you consent to the collection and use of your health data as described in this Privacy Policy.

## Contact Us

If you have questions, concerns, or requests regarding this Privacy Policy or your data, please contact us:

- **GitHub Issues**: [https://github.com/GodisinHisHeaven/ohMyTss/issues](https://github.com/GodisinHisHeaven/ohMyTss/issues)
- **Repository**: [https://github.com/GodisinHisHeaven/ohMyTss](https://github.com/GodisinHisHeaven/ohMyTss)

## Summary

**In Plain English:**

ohMyTss calculates training load and readiness on your device from Apple Health and optional Strava activities. Health data is never used for advertising. Resetting activity sync keeps your saved training history and notes.
