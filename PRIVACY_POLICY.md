# Privacy Policy for ohMyTss

**Last Updated:** October 25, 2026

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

Morning Status SMS is an optional web service for existing accounts. It uses
account details, an opted-in phone number, and training/wellness data from
Intervals.icu and optional Strava connections. The backend stores this data in
Supabase and uses Twilio to deliver messages. Its [service privacy
notice](https://coach-ota.fly.dev/privacy) describes that processing. Opening
its account link from iOS does not upload Apple Health data. Reply STOP to stop
SMS. Coaching chat, plans, other alerts, and signup are currently paused.

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
- This integration does not upload HealthKit data to the morning status service
- Optional Strava and SMS services use the connections described above
- Data is protected by iOS sandboxing and encryption mechanisms

### No Account Required

The iOS HealthKit features do not require an account. Strava requires separate authorization; the morning status service requires an existing account and separate SMS opt-in.

## Data You Control

### Your Rights

You have complete control over your data:

- **Access**: View all calculated metrics within the app
- **Delete**: Remove all calculated data using the "Reset All Data" option in Settings
- **HealthKit Permissions**: Revoke HealthKit access at any time through iOS Settings → Health → Data Access & Devices → ohMyTss

### What Happens When You Delete Data

When you use "Reset All Data" in the app:
- All calculated Body Battery scores, TSS, and training load metrics are permanently deleted
- Your original HealthKit data remains untouched in Apple Health
- You can recalculate metrics by syncing HealthKit data again
- This reset does not delete your separate morning status account or change its SMS consent

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

ohMyTss does not use third-party analytics or advertising. Optional Strava and morning status services process the data described above.

## International Users

iOS HealthKit data stays on your device. The optional web service and its providers process account, training, and SMS data on their servers.

## Your Consent

By using ohMyTss and granting HealthKit permissions, you consent to the collection and use of your health data as described in this Privacy Policy.

## Contact Us

If you have questions, concerns, or requests regarding this Privacy Policy or your data, please contact us:

- **GitHub Issues**: [https://github.com/GodisinHisHeaven/ohMyTss/issues](https://github.com/GodisinHisHeaven/ohMyTss/issues)
- **Repository**: [https://github.com/GodisinHisHeaven/ohMyTss](https://github.com/GodisinHisHeaven/ohMyTss)

## Summary

**In Plain English:**

ohMyTss reads your workout data from Apple Health to calculate how ready you are to train. HealthKit calculations happen on your device. Optional Strava authorization and the separate morning SMS service use external providers as described above. HealthKit data is not uploaded by this integration or used for advertising. You can delete all calculated data anytime, and your original Health data stays safe in Apple Health.

---

© 2026 ohMyTss. All rights reserved.
