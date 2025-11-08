# OnMyTSS - Body Battery for Endurance Athletes

> Calculate your daily Body Battery score from training load (TSS), HRV, and resting heart rate.

[![iOS](https://img.shields.io/badge/iOS-18%2B-blue)](https://www.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## Overview

OnMyTSS is an iOS app that calculates a daily **Body Battery** score (0-100) to help endurance athletes understand when to train hard vs. recover. It combines:

- **Training Load** (CTL/ATL/TSB) from workouts
- **Heart Rate Variability** (HRV) for stress/recovery
- **Resting Heart Rate** (RHR) for readiness

All computation happens **on-device** using Apple Health data. No servers, no data sharing.

## Features

### MVP (Current)
- ✅ Daily Body Battery score (0-100)
- ✅ Training Stress Score (TSS) calculation from cycling power
- ✅ CTL/ATL/TSB tracking (Banister model)
- ✅ Today view with gauge and suggested TSS range
- ✅ Onboarding flow with HealthKit permissions
- ✅ Settings for FTP and thresholds

### v1.0 (Roadmap)
- [ ] HRV and RHR modifiers
- [ ] Illness detection
- [ ] Multi-sport support (running, swimming)
- [ ] 90-day history charts
- [ ] Apple Watch app with complications
- [ ] Background refresh
- [ ] Daily notifications

### v1.1+ (Future)
- [ ] iCloud sync
- [ ] Widgets
- [ ] Training plan suggestions
- [ ] Strava integration
- [ ] FIT/TCX file import

## Architecture

```
OnMyTSS/
├── Packages/
│   ├── TSSEngine/              # Core algorithms (CTL/ATL/TSB, Body Battery)
│   ├── HealthStore/            # HealthKit integration
│   ├── Persistence/            # SwiftData models
│   └── SharedUI/               # Reusable UI components
├── OnMyTSS/                    # Main app
│   ├── App/                    # App entry point
│   ├── Views/                  # SwiftUI views
│   └── ViewModels/             # View models
└── OnMyTSSTests/               # Unit tests

```

### Key Modules

| Module | Description |
|--------|-------------|
| **TSSEngine** | Pure Swift algorithms for TSS calculation, CTL/ATL/TSB, Body Battery mapping, HRV/RHR modifiers |
| **HealthStore** | HealthKit queries (workouts, HRV, RHR, sleep), anchored queries, background observers |
| **Persistence** | SwiftData models (DayAggregate, UserThresholds, AppState), DataStore |
| **SharedUI** | Reusable SwiftUI components (BodyBatteryGauge, TSSGuidanceCard, WeekTrendView) |

## Setup

### Requirements
- **Xcode 15+** (for iOS 18 and Swift 5.9)
- **iOS 18+** device or simulator
- **macOS 14+** (Sonoma)

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/GodisinHisHeaven/ohMyTss.git
   cd ohMyTss
   ```

2. **Open in Xcode:**
   ```bash
   open OnMyTSS.xcodeproj
   ```
   > Note: The project structure is currently set up as Swift Packages. You'll need to create the Xcode project file manually or use `File > New > Project` in Xcode and add the packages.

3. **Build and run:**
   - Select the `OnMyTSS` scheme
   - Choose a simulator or connected device
   - Press `Cmd+R` to build and run

### Creating the Xcode Project

Since this is a fresh Swift Package-based structure, create the Xcode project:

1. Open Xcode
2. `File > New > Project`
3. Choose **iOS > App**
4. Name: `OnMyTSS`
5. Team: Your development team
6. Bundle ID: `com.yourdomain.onmytss`
7. Deployment Target: **iOS 18.0**

Then add the local Swift Packages:
1. `File > Add Packages...`
2. Click "Add Local..."
3. Navigate to `Packages/TSSEngine` and add
4. Repeat for `HealthStore`, `Persistence`, `SharedUI`

Copy the source files from `OnMyTSS/` into the Xcode project.

## Testing

### Run Unit Tests

```bash
# Run all tests
xcodebuild test -scheme TSSEngine -destination 'platform=iOS Simulator,name=iPhone 15'

# Or in Xcode
# Cmd+U
```

### Test Coverage

- **TSSEngine**: 95%+ coverage (algorithms)
- **Persistence**: Core data operations
- **Mock Data**: Synthetic workouts, HRV, RHR for development

## Core Algorithms

### 1. Training Stress Score (TSS)

**Cycling (Power-based):**
```
NP = Normalized Power (30-sec rolling avg, 4th power mean)
IF = Intensity Factor = NP / FTP
TSS = (duration_hours × NP × IF) / (FTP × 3600) × 100
```

**Running (Pace-based):**
```
IF = threshold_pace / actual_pace
TSS = duration_hours × IF² × 100
```

### 2. CTL/ATL/TSB (Banister Model)

```swift
CTL[d] = CTL[d-1] + k42 × (TSS[d] - CTL[d-1])  // 42-day time constant
ATL[d] = ATL[d-1] + k7  × (TSS[d] - ATL[d-1])  // 7-day time constant
TSB[d] = CTL[d] - ATL[d]                       // Freshness
```

Where:
- `k42 = 1 - exp(-1/42) ≈ 0.0235`
- `k7 = 1 - exp(-1/7) ≈ 0.1331`

### 3. Body Battery Score

```swift
// Map TSB to 0-100
BB_raw = clamp(50 + TSB × (50/30), 0, 100)

// Add HRV/RHR modifiers (v1.0)
adj = f(HRV_z, RHR_z, previous_adj)
BB_final = clamp(BB_raw + adj, 0, 100)
```

## Configuration

### Setting Your FTP

1. Go to **Settings** tab
2. Enter your Functional Threshold Power (FTP) in watts
3. For running, enter threshold pace (min/km)

### HealthKit Permissions

OnMyTSS requires read access to:
- Workouts
- Heart Rate
- Heart Rate Variability (SDNN)
- Resting Heart Rate
- Cycling Power
- Running Speed/Pace
- Sleep Analysis

Grant permissions during onboarding or in iOS Settings > Health > Data Access.

## Development

### Adding a New Sport

1. Add TSS calculation to `TSSEngine/TSSCalculator.swift`
2. Update `Sport` enum in `Persistence/Models/UserThresholds.swift`
3. Add threshold input to Settings view
4. Update workout processing in main engine

### Running Tests

```bash
# Swift Package Manager
swift test

# Xcode
Cmd+U
```

### Code Style

- SwiftLint configuration (coming soon)
- Prefer `async/await` over completion handlers
- Use `@Observable` for view models (iOS 17+)
- Keep packages independent and testable

## Privacy

- **All data stays on your device** (no servers)
- Optional iCloud sync (v1.1+, user-controlled)
- No analytics by default
- Open source (coming soon)

## Contributing

Contributions are welcome! Please:
1. Fork the repo
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Roadmap

See [DESIGN_DOC_V2.md](DESIGN_DOC_V2.md) for detailed implementation plan.

| Phase | Timeline | Status |
|-------|----------|--------|
| MVP (Cycling only) | Weeks 1-8 | ✅ Framework complete |
| v1.0 (Multi-sport + Physiology) | Weeks 9-12 | 🚧 In progress |
| v1.1 (iCloud + Widgets) | Q2 2025 | 📋 Planned |

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- Training load model based on [Banister et al. (1975)](https://pubmed.ncbi.nlm.nih.gov/1085735/)
- TSS concept from [TrainingPeaks](https://www.trainingpeaks.com)
- Inspired by Garmin Body Battery and Whoop Recovery Score

## Contact

- **Author:** Mingjun Liu
- **GitHub:** [@GodisinHisHeaven](https://github.com/GodisinHisHeaven)
- **Repo:** [ohMyTss](https://github.com/GodisinHisHeaven/ohMyTss)

---

**Built with ❤️ for endurance athletes who want to train smarter, not harder.**
