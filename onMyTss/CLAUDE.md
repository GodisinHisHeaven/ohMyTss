# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Body Battery** is an iOS app that calculates a daily readiness score (0-100) for endurance athletes based on Training Stress Score (TSS), using the Banister CTL/ATL/TSB model with HealthKit integration.

- **Language:** Swift 6.0
- **Minimum iOS:** 18.6
- **Frameworks:** SwiftUI, SwiftData, HealthKit
- **Architecture:** MVVM with service layer

## Project Structure

```
onMyTss/onMyTss/
├── Models/                      # SwiftData models
│   ├── DayAggregate.swift       # Daily metrics (TSS, CTL, ATL, TSB, score)
│   ├── UserThresholds.swift     # User settings (FTP, preferences)
│   └── AppState.swift           # App sync state (HealthKit anchor)
├── Services/                    # Business logic layer
│   ├── DataStore.swift          # SwiftData CRUD operations
│   ├── HealthKitManager.swift   # HealthKit data access
│   ├── TSSCalculator.swift      # Training Stress Score calculation
│   ├── LoadCalculator.swift     # CTL/ATL/TSB calculations
│   ├── BodyBatteryCalculator.swift  # Score (0-100) conversion
│   ├── GuidanceEngine.swift     # Training recommendations
│   └── BodyBatteryEngine.swift  # Main orchestration service
├── ViewModels/                  # View models for MVVM
│   └── TodayViewModel.swift     # ✅ Today screen state management
├── Views/
│   ├── Onboarding/              # ✅ COMPLETE
│   │   ├── WelcomeView.swift
│   │   ├── HealthPermissionView.swift
│   │   ├── ThresholdInputView.swift
│   │   └── OnboardingContainerView.swift
│   ├── Today/                   # ✅ COMPLETE
│   │   ├── TodayView.swift      # Main today screen
│   │   ├── BodyBatteryGauge.swift  # Circular gauge component
│   │   ├── TSSGuidanceCard.swift   # Training recommendations
│   │   └── WeekTrendView.swift     # 7-day trend chart
│   ├── History/                 # TODO: Historical data view
│   ├── Settings/                # TODO: User settings
│   └── Shared/                  # TODO: Reusable components
├── Utilities/
│   ├── Extensions.swift         # Date, Double, Int, Array, Color extensions
│   └── Constants.swift          # App-wide constants
├── ContentView.swift            # Root view with onboarding check
└── onMyTssApp.swift            # App entry point with SwiftData setup
```

## Key Architecture Patterns

### Data Flow
1. **HealthKit** → HealthKitManager → BodyBatteryEngine
2. **BodyBatteryEngine** → Calculators (TSS/Load/BodyBattery) → DataStore
3. **DataStore** → SwiftData → ViewModels → Views

### Main Computation Pipeline
```swift
// Called on: app launch, manual refresh, after new workouts
BodyBatteryEngine.recomputeAll()
  └─> Fetch workouts from HealthKit (last 90 days)
  └─> Calculate TSS for each workout (power-based or HR-based)
  └─> Aggregate TSS by day
  └─> Compute CTL/ATL/TSB time series (exponential moving averages)
  └─> Convert TSB to Body Battery score (0-100)
  └─> Save DayAggregate records to SwiftData
```

### Algorithm Details

**TSS (Training Stress Score):**
- Power-based: `(duration_sec × NP × IF) / (FTP × 3600) × 100`
- NP = Normalized Power (4th root of average of 4th powers)
- HR-based fallback: TRIMP method with exponential weighting

**Load Metrics:**
- CTL (Chronic Training Load): 42-day exponential moving average of TSS
- ATL (Acute Training Load): 7-day exponential moving average of TSS
- TSB (Training Stress Balance): CTL - ATL

**Body Battery Score:**
- Linear mapping: TSB -35 → Score 0, TSB 0 → Score 50, TSB +25 → Score 100
- Score represents daily readiness (0=depleted, 100=fully charged)

## Development Commands

### Build
```bash
cd onMyTss
xcodebuild -scheme onMyTss -destination 'platform=iOS Simulator,name=iPhone 17' build
```

### Run on Simulator
Open in Xcode and run (⌘R), or:
```bash
xcodebuild -scheme onMyTss -destination 'platform=iOS Simulator,name=iPhone 17' run
```

### Run Tests (when implemented)
```bash
xcodebuild test -scheme onMyTss -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Current Implementation Status

### ✅ COMPLETED (Phases 1-6)
- SwiftData models and persistence layer
- HealthKit integration (workouts, power, heart rate)
- All calculation engines (TSS, CTL/ATL/TSB, Body Battery, Guidance)
- BodyBatteryEngine orchestration service
- Complete onboarding flow (Welcome → HealthKit → FTP setup)
- **Today Screen (Phase 6):**
  - ✅ `BodyBatteryGauge.swift` - Circular gauge with color gradient
  - ✅ `TSSGuidanceCard.swift` - Daily recommendations card
  - ✅ `WeekTrendView.swift` - 7-day mini chart with trend analysis
  - ✅ `TodayViewModel.swift` - State management and data fetching
  - ✅ `TodayView.swift` - Main screen with gauge, guidance, metrics, and trend
  - ✅ Pull-to-refresh for incremental HealthKit sync
  - ✅ Loading, empty, and error states
  - ✅ Integration with BodyBatteryEngine and DataStore

### 🚧 TODO: Phase 7 - Settings & History
- [ ] Create `SettingsViewModel.swift`
- [ ] Create `SettingsView.swift` - FTP input, units preference, about section
- [ ] Create `HistoryViewModel.swift`
- [ ] Create `HistoryView.swift` - List of last 7 days with CTL/ATL/TSB
- [ ] Create TabView navigation (Today, History, Settings tabs)
- [ ] Update ContentView to show TabView after onboarding

### 🚧 TODO: Phase 8 - Error Handling & Polish
- [ ] Add error states (no HealthKit permission, no FTP, no data)
- [ ] Add loading states (skeleton screens, progress indicators)
- [ ] Add empty states (no workouts yet, first-time user)
- [ ] Handle edge cases (sync failures, invalid data, missing FTP)
- [ ] Add automatic data refresh on app launch
- [ ] Optimize performance (lazy loading, query optimization)

### 🚧 TODO: Phase 9 - Testing & Bug Fixes
- [ ] Test full user flow (onboarding → sync → score display)
- [ ] Test with real HealthKit data on physical device
- [ ] Test edge cases (no workouts, extreme TSS values)
- [ ] Test different screen sizes (iPhone SE to Pro Max, iPad)
- [ ] Performance test with 90 days of dense workout data
- [ ] Fix all critical bugs

### 🚧 TODO: Phase 10 - TestFlight Preparation
- [ ] Update version to 1.0 and build number
- [ ] Generate app screenshots
- [ ] Write TestFlight beta notes
- [ ] Archive and upload to App Store Connect
- [ ] Invite beta testers

## Important Notes

### HealthKit Privacy
- App requires HealthKit permissions to function
- Privacy descriptions are in project.pbxproj INFOPLIST_KEY_NSHealthShareUsageDescription
- Never writes data to HealthKit (read-only)

### Data Persistence
- All metrics stored in SwiftData (local device only)
- No cloud sync in MVP (planned for v1.1)
- App state includes HKQueryAnchor for incremental syncs

### FTP (Functional Threshold Power)
- Required for accurate cycling TSS calculation
- Range: 50-500 watts (validation in ThresholdInputView)
- Can be updated anytime in Settings
- Default fallback: 200W

### MVP Scope (Phase 0)
- Cycling workouts only (power-based TSS)
- Manual FTP input (no auto-detection)
- No HRV/RHR modifiers (planned for v1.0)
- No Watch app (planned for v1.1)
- No background sync (planned for v1.1)
- No multi-sport support (planned for v1.0)

## Common Development Tasks

### Add a New View
1. Create Swift file in appropriate Views/ subfolder
2. Import SwiftUI (and SwiftData if using @Environment)
3. Follow existing view patterns (BodyBatteryGauge, TodayView)
4. Add Preview for Xcode canvas testing

### Add a New Calculation
1. Add static function to appropriate calculator (TSS/Load/BodyBattery)
2. Follow pure function pattern (no side effects)
3. Add unit tests in Tests/ folder (when test infrastructure is set up)
4. Update BodyBatteryEngine if needed to call new calculation

### Modify SwiftData Models
⚠️ **WARNING:** Changing @Model classes requires migration strategy
1. Consider backward compatibility
2. Add new properties with default values
3. Test with existing data
4. Document migration in commit message

### Debug HealthKit Issues
- Check entitlements file has `com.apple.developer.healthkit` = true
- Verify Info.plist has NSHealthShareUsageDescription
- Test on real device (HealthKit unavailable in some simulators)
- Use HealthKitManager.isHealthKitAvailable to check availability

## Known Issues & Limitations

1. **No offline support:** App requires HealthKit data to function
2. **No data export:** Users cannot export their metrics (planned for v1.1)
3. **iOS only:** No macOS/watchOS support in MVP
4. **Single sport:** Only cycling workouts use power-based TSS
5. **Manual FTP:** No FTP auto-detection from workouts

## Future Enhancements (Post-MVP)

- Multi-sport support (running, swimming with pace/HR-based TSS)
- HRV/RHR modifiers for score adjustment
- Apple Watch companion app
- Background HealthKit sync
- iCloud sync across devices
- Weekly/monthly trend charts
- Training plan suggestions
- Race readiness predictions

## Contact & Resources

- Design Doc: `/DESIGN_DOC_V2.md`
- GitHub Issues: Report bugs and feature requests
- TSS Formula Reference: TrainingPeaks methodology
- CTL/ATL/TSB: Banister Impulse-Response Model
