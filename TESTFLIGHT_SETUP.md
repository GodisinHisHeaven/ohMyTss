# TestFlight Setup Guide for onMyTss

This guide walks you through preparing onMyTss for TestFlight distribution.

## ✅ Completed Steps

### Phase 1: Build Configuration
- ✅ Removed macOS-only settings (ENABLE_APP_SANDBOX, ENABLE_HARDENED_RUNTIME)
- ✅ Limited platform support to iOS only
- ✅ Updated version to 1.0.0
- ✅ Build verified successful

### Phase 2: App Icon
- ✅ 1024x1024 app icon present with light, dark, and tinted variants
- ✅ Located in: `onMyTss/Assets.xcassets/AppIcon.appiconset/`

### Phase 3: Privacy Policy
- ✅ Comprehensive privacy policy created (PRIVACY_POLICY.md)
- ✅ HTML version for web hosting (docs/privacy-policy.html)
- ✅ Privacy Policy link added to Settings screen

---

## 🔧 Required: Enable GitHub Pages

**IMPORTANT:** You must enable GitHub Pages to host the privacy policy before TestFlight submission.

### Steps to Enable GitHub Pages:

1. **Go to your repository on GitHub:**
   - Navigate to: https://github.com/GodisinHisHeaven/ohMyTss

2. **Access Settings:**
   - Click the "Settings" tab (top right of the repository)

3. **Find Pages Section:**
   - In the left sidebar, scroll down to "Pages"
   - Click on "Pages"

4. **Configure Source:**
   - Under "Build and deployment"
   - **Source:** Select "Deploy from a branch"
   - **Branch:** Select "main"
   - **Folder:** Select "/ (root)" or "/docs" (both will work, /docs is recommended)
   - Click "Save"

5. **Wait for Deployment:**
   - GitHub will take 1-3 minutes to deploy
   - You'll see a green success message when ready
   - Your privacy policy will be live at:
     ```
     https://godisinHisHeaven.github.io/ohMyTss/privacy-policy.html
     ```

6. **Verify the Privacy Policy:**
   - Open the URL above in your browser
   - Confirm the page loads correctly
   - Check that all sections are visible and formatted properly

---

## 📱 Phase 4: App Store Connect Setup

### Step 1: Register Bundle ID

1. **Go to Apple Developer Portal:**
   - Visit: https://developer.apple.com/account/resources/identifiers/list
   - Sign in with your Apple Developer account

2. **Create Bundle ID:**
   - Click the "+" button
   - Select "App IDs"
   - Click "Continue"

3. **Configure Bundle ID:**
   - **Description:** onMyTss
   - **Bundle ID:** Select "Explicit"
   - **Bundle ID:** Enter `mj6.onMyTss`
   - **Capabilities:** Check "HealthKit"
   - Click "Continue" then "Register"

### Step 2: Create App Record in App Store Connect

1. **Go to App Store Connect:**
   - Visit: https://appstoreconnect.apple.com
   - Click "My Apps"

2. **Create New App:**
   - Click the "+" button
   - Select "New App"

3. **Fill in App Information:**
   - **Platform:** iOS
   - **Name:** onMyTss
   - **Primary Language:** English (U.S.)
   - **Bundle ID:** Select `mj6.onMyTss` (from dropdown)
   - **SKU:** `ONMYTSS001` (or your preference - internal tracking only)
   - **User Access:** Full Access (or as needed)
   - Click "Create"

4. **Configure App Information:**

   **Privacy Policy URL:**
   ```
   https://godisinHisHeaven.github.io/ohMyTss/privacy-policy.html
   ```

   **Category:**
   - Primary: Health & Fitness
   - Secondary: (Optional) Sports

   **App Description (Suggested):**
   ```
   Track your training readiness with onMyTss - the Body Battery app for endurance athletes.

   onMyTss analyzes your workout data from Apple Health to calculate your daily Training Stress Score (TSS) and Body Battery readiness level (0-100). Get personalized training guidance based on your fitness state.

   FEATURES:
   • Daily Body Battery score (0-100) showing training readiness
   • Training Stress Score (TSS) calculation from power and heart rate
   • Chronic Training Load (CTL) and Acute Training Load (ATL) tracking
   • Training Stress Balance (TSB) monitoring
   • 7-day trend visualization
   • Personalized training recommendations
   • FTP-based power analysis for cycling
   • Automatic HealthKit integration

   PRIVACY & DATA:
   • All data stored locally on your device
   • No cloud servers or data sharing
   • No advertising or data mining
   • Read-only HealthKit access

   Perfect for cyclists, runners, and endurance athletes who want data-driven training insights.

   Requires iOS 18.6 or later and Apple Health data.
   ```

   **Keywords (Suggested):**
   ```
   training,fitness,cycling,running,TSS,power,heart rate,workout,endurance,athlete
   ```

   **Support URL:**
   ```
   https://github.com/GodisinHisHeaven/ohMyTss
   ```

   **Marketing URL (Optional):**
   ```
   https://github.com/GodisinHisHeaven/ohMyTss
   ```

---

## 🧪 Phase 5: Build and Upload to TestFlight

### Prerequisites Checklist

Before archiving, verify:
- ✅ Privacy Policy is live at GitHub Pages URL
- ✅ Bundle ID `mj6.onMyTss` is registered with HealthKit capability
- ✅ App record created in App Store Connect
- ✅ Build settings fixed (no macOS settings)
- ✅ App icon present (1024x1024)
- ✅ Version is 1.0.0, Build is 1

### Step 1: Clean Build

```bash
cd /Users/mingjunliu/Developer/ohMyTss/onMyTss
xcodebuild clean -scheme onMyTss
```

### Step 2: Archive the App

**Option A: Using Xcode (Recommended for first-time):**

1. **Open Xcode:**
   ```bash
   open onMyTss.xcodeproj
   ```

2. **Select Device:**
   - In the device selector (top toolbar), choose "Any iOS Device (arm64)"
   - Do NOT select a simulator

3. **Set Scheme:**
   - Product → Scheme → Edit Scheme
   - Select "Archive" on the left
   - Ensure Build Configuration is "Release"
   - Click "Close"

4. **Archive:**
   - Product → Clean Build Folder (⇧⌘K)
   - Product → Archive
   - Wait for archive to complete (2-5 minutes)

5. **Organizer Window:**
   - Xcode Organizer will open automatically
   - Your archive should appear with today's date

6. **Distribute:**
   - Select the archive
   - Click "Distribute App"
   - Select "App Store Connect"
   - Click "Next"
   - Select "Upload"
   - Click "Next"
   - **Automatically manage signing** (recommended)
   - Click "Next"
   - Review entitlements (should show HealthKit)
   - Click "Upload"
   - Wait for upload (5-10 minutes)

**Option B: Using Command Line:**

```bash
# Archive
xcodebuild archive \
  -scheme onMyTss \
  -archivePath ~/Desktop/onMyTss.xcarchive \
  -configuration Release \
  -destination 'generic/platform=iOS'

# Export for App Store
xcodebuild -exportArchive \
  -archivePath ~/Desktop/onMyTss.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath ~/Desktop/onMyTss-Export
```

### Step 3: Configure TestFlight

1. **Go to App Store Connect:**
   - Visit: https://appstoreconnect.apple.com
   - Navigate to your app (onMyTss)
   - Click "TestFlight" tab

2. **Wait for Processing:**
   - Your build will appear with status "Processing"
   - This takes 5-30 minutes
   - You'll receive an email when ready

3. **Add Beta App Description:**
   ```
   Body Battery is a fitness readiness app for endurance athletes. It analyzes your
   workout data from Apple Health (power, heart rate, HRV) to calculate your daily
   Training Stress Score (TSS) and readiness level (0-100).

   Features being tested:
   - Daily Body Battery score based on training load
   - 7-day trend visualization
   - Training guidance recommendations
   - HealthKit integration for automatic workout sync
   - FTP-based power analysis for cycling

   We're looking for feedback on accuracy, usability, and feature requests.
   ```

4. **Add "What to Test" Notes:**
   ```
   Initial beta release - please test all core functionality:

   WHAT TO TEST:
   - Complete onboarding flow (HealthKit permission, FTP setup)
   - Verify Body Battery score appears after granting HealthKit access
   - Check 7-day trend chart displays correctly
   - Test training guidance recommendations
   - Verify Settings can update FTP
   - Test manual data refresh

   KNOWN LIMITATIONS:
   - Cycling workouts only (running/swimming not yet supported)
   - Requires recent workout data in Apple Health
   - iOS 18.6+ required

   FEEDBACK NEEDED:
   - Is the Body Battery score accurate for your fitness level?
   - Are the training recommendations helpful?
   - Any UI/UX improvements?
   ```

5. **Add Beta App Information:**
   - **Feedback Email:** Your email address
   - **Privacy Policy URL:** `https://godisinHisHeaven.github.io/ohMyTss/privacy-policy.html`

### Step 4: Internal Testing (No Review Required)

1. **Create Internal Tester Group:**
   - In TestFlight, click "Internal Testing"
   - Click "+" to create a new group
   - Name it "Internal Testers"

2. **Add Internal Testers:**
   - Add App Store Connect users (yourself and team members)
   - They must have Developer or higher role

3. **Select Build:**
   - Choose your uploaded build
   - Click "Save"

4. **Start Testing:**
   - Testers will receive an email invitation
   - They can install TestFlight app and start testing immediately
   - Test thoroughly before external release

### Step 5: External Testing (Requires Beta App Review)

1. **Create External Tester Group:**
   - In TestFlight, click "External Testing"
   - Click "+" to create a new group
   - Name it "Public Beta Testers"

2. **Submit for Beta App Review:**
   - Add build to external group
   - Fill in export compliance questions:
     - **Does your app use encryption?** → Yes (iOS uses standard encryption)
     - **Does it use custom encryption?** → No
   - Click "Submit for Review"

3. **Wait for Beta App Review:**
   - Typically takes 24-48 hours
   - You'll receive email when approved or if issues found

4. **Invite External Testers:**
   - Add testers by email
   - Or create a public link for broader testing
   - Testers can download TestFlight and install the app

---

## 🐛 Troubleshooting

### Common Issues:

**Issue:** Archive fails with code signing error
- **Solution:** Go to project settings → Signing & Capabilities → Ensure "Automatically manage signing" is checked and team is selected

**Issue:** Build shows as "Invalid Binary" in App Store Connect
- **Solution:** Check that ENABLE_APP_SANDBOX and ENABLE_HARDENED_RUNTIME are removed (already done in Phase 1)

**Issue:** Upload fails with "Invalid Entitlements"
- **Solution:** Verify HealthKit entitlement is properly configured in `onMyTss.entitlements`

**Issue:** Beta App Review rejection
- **Solution:** Most common reasons:
  - Missing privacy policy (must be accessible at URL)
  - HealthKit usage not clearly explained
  - App crashes on launch (test thoroughly first)

### Build Version Management:

For subsequent TestFlight builds:
- Keep `MARKETING_VERSION` at `1.0.0` during beta
- Increment `CURRENT_PROJECT_VERSION`: 1 → 2 → 3 → 4...
- Each upload must have a higher build number than the previous

---

## 📋 Final Checklist

Before submitting to TestFlight:

- [ ] Privacy Policy is live and accessible at GitHub Pages URL
- [ ] Bundle ID registered with HealthKit capability
- [ ] App record created in App Store Connect
- [ ] All app metadata filled in (description, keywords, URLs)
- [ ] Archive created successfully
- [ ] Upload to App Store Connect completed
- [ ] Build processing finished (no errors)
- [ ] TestFlight beta information filled in
- [ ] Internal testing completed (no critical bugs)
- [ ] Beta App Review submission completed (for external testing)

---

## 🎯 Next Steps After TestFlight

1. **Gather Beta Feedback:**
   - Monitor TestFlight feedback
   - Track crashes in App Store Connect
   - Iterate on bugs and features

2. **Prepare for App Store Release:**
   - Create app screenshots (required sizes)
   - Write App Store description
   - Set pricing (free or paid)
   - Choose release option (manual or automatic)

3. **Submit for App Review:**
   - Submit for full App Store review
   - Wait 1-7 days for review
   - Address any feedback from review team

---

## 📞 Support

If you encounter issues:
- Check Apple Developer Forums: https://developer.apple.com/forums/
- Review App Store Connect Help: https://help.apple.com/app-store-connect/
- Submit GitHub issue: https://github.com/GodisinHisHeaven/ohMyTss/issues

---

**Document Version:** 1.0
**Last Updated:** November 8, 2025
**Next Review:** Before App Store submission
