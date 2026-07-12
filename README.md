# onMyTss

An iOS app that tracks your training load and tells you how hard you can push today.

## What it does

**onMyTss** reads your workouts from Apple Health and calculates your daily **Body Battery** — a 0–100 score that reflects how fresh or fatigued you are right now.

Under the hood, it uses the same performance management model used by professional coaches:

| Metric | What it means |
|--------|---------------|
| **TSS** (Training Stress Score) | How hard a single workout was |
| **CTL** (Chronic Training Load) | Your fitness — 42-day rolling average of TSS |
| **ATL** (Acute Training Load) | Your fatigue — 7-day rolling average of TSS |
| **TSB** (Training Stress Balance) | Your form — CTL minus ATL |
| **Body Battery** | TSB mapped to an intuitive 0–100 scale |

## Features

- **Body Battery gauge** — at-a-glance readiness score with readiness level (Very Low → Excellent)
- **Daily TSS guidance** — recommended TSS range and intensity for today based on your current state
- **Ramp rate monitoring** — warns you if your training load is increasing too fast (overtraining risk)
- **HRV & resting heart rate** — physiological modifiers that fine-tune your Body Battery beyond TSS
- **Illness detection** — flags unusual HRV/RHR patterns that may indicate early illness
- **7-day trend view** — visualise how your form has evolved through the week
- **Workout history** — browse past workouts with per-session TSS breakdown
- **Strava integration** — optionally pulls your FTP directly from your Strava athlete profile

## TSS Calculation

The app chooses the most accurate method available for each workout:

1. **Power-based** (cycling with a power meter + FTP) — most accurate, uses Normalized Power and Intensity Factor
2. **Heart rate-based** (any sport with HR data) — uses a modified Bannister TRIMP formula with sport-specific multipliers
3. **Duration estimate** (fallback) — estimates TSS from workout type and duration using typical intensity factors

## Requirements

- iOS 17+
- Apple Health access (workouts, heart rate, HRV, resting heart rate)
- Strava account (optional, for automatic FTP sync)

## Getting started

1. Clone the repo and open `onMyTss/onMyTss.xcodeproj` in Xcode
2. Build and run on a device or simulator
3. Grant Health permissions on first launch
4. Enter your FTP (if you cycle with a power meter) or let the app use heart rate data
5. Check your Body Battery on the Today tab

## Project structure

```
onMyTss/
├── Models/
│   ├── Workout.swift          # Workout data model
│   ├── DayAggregate.swift     # Per-day CTL/ATL/TSB snapshot
│   ├── UserThresholds.swift   # FTP, max HR, preferred sports
│   └── AppState.swift
├── Services/
│   ├── TSSCalculator.swift    # Power & HR-based TSS formulas
│   ├── LoadCalculator.swift   # CTL / ATL / TSB (Banister model)
│   ├── BodyBatteryCalculator.swift  # TSB → 0-100 score
│   ├── BodyBatteryEngine.swift      # Orchestrates data pipeline
│   ├── GuidanceEngine.swift   # Training recommendations
│   ├── PhysiologyModifier.swift     # HRV/RHR score adjustments
│   ├── SleepAnalyzer.swift
│   ├── HealthKitManager.swift
│   ├── WorkoutAggregator.swift
│   ├── StravaAPI.swift        # Strava REST client
│   └── StravaAuthManager.swift
├── ViewModels/
│   ├── TodayViewModel.swift
│   ├── HistoryViewModel.swift
│   └── SettingsViewModel.swift
└── Views/
    ├── Today/                 # Body Battery screen
    ├── History/               # Workout history
    ├── Settings/              # Thresholds & Strava setup
    └── Onboarding/
```

## Privacy

All health data stays on your device. See [PRIVACY_POLICY.md](PRIVACY_POLICY.md) for details.
