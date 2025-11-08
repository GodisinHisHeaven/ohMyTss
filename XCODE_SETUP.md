# Xcode Project Setup Guide

This guide will help you complete the Xcode project setup for OnMyTSS.

## Current Project Structure

```
ohMyTss/
├── ohMyTss.xcodeproj/        # ✅ Xcode project
├── ohMyTss/ohMyTss/          # ✅ App source code
│   ├── App/
│   ├── Views/
│   ├── ViewModels/
│   ├── Assets.xcassets
│   └── Info.plist            # ✅ With HealthKit permissions
├── ohMyTssTests/             # ✅ Unit tests
├── Packages/                 # ✅ Local Swift Packages
│   ├── TSSEngine/
│   ├── HealthStore/
│   ├── Persistence/
│   └── SharedUI/
└── README.md
```

## Steps to Complete Setup

### 1. Open the Project in Xcode

```bash
open ohMyTss.xcodeproj
```

### 2. Add Local Swift Packages

For each package in the `Packages/` directory:

1. In Xcode, go to **File → Add Package Dependencies...**
2. Click **Add Local...** (bottom left)
3. Navigate to `Packages/TSSEngine` and click **Add Package**
4. Repeat for:
   - `Packages/HealthStore`
   - `Packages/Persistence`
   - `Packages/SharedUI`

**Alternative method (if Add Local doesn't work):**
1. Drag each `Package.swift` file from Finder into the Xcode Project Navigator
2. Xcode will automatically recognize them as local packages

### 3. Add Source Files to Target

The source files are already in `ohMyTss/ohMyTss/`, but you need to add them to the Xcode project:

1. In Xcode Project Navigator, right-click on `ohMyTss` (blue icon)
2. **Add Files to "ohMyTss"...**
3. Select the following folders:
   - `App/`
   - `Views/`
   - `ViewModels/`
4. Make sure **"Copy items if needed"** is **UNCHECKED**
5. Make sure **"Create groups"** is selected
6. Make sure the **ohMyTss target** is checked
7. Click **Add**

### 4. Configure HealthKit Capability

1. Select the **ohMyTss** project in Project Navigator
2. Select the **ohMyTss** target
3. Go to **Signing & Capabilities** tab
4. Click **+ Capability**
5. Search for and add **HealthKit**
6. In the HealthKit section, check:
   - ✅ **Background Delivery**
   - ✅ **Clinical Health Records** (optional)

### 5. Configure App Group (for future Watch sync)

1. Still in **Signing & Capabilities**
2. Click **+ Capability** again
3. Add **App Groups**
4. Click **+** and create: `group.com.onmytss.app`

### 6. Update Deployment Target

1. In **General** tab of target settings
2. Set **Minimum Deployments** to **iOS 18.0**

### 7. Set Your Development Team

1. In **Signing & Capabilities** tab
2. Set **Team** to your Apple Developer account
3. Update **Bundle Identifier** if needed (e.g., `com.yourteam.onmytss`)

### 8. Link Swift Packages to Target

After adding the packages:

1. Select the **ohMyTss** target
2. Go to **General** tab
3. Scroll to **Frameworks, Libraries, and Embedded Content**
4. Click **+** and add:
   - TSSEngine
   - HealthStore
   - Persistence
   - SharedUI

### 9. Update Import Statements

The source files should already have correct imports, but verify in `OnMyTSSApp.swift`:

```swift
import SwiftUI
import SwiftData
import Persistence  // Add if needed
```

And in view files:
```swift
import SharedUI
import TSSEngine
```

### 10. Build and Run

1. Select a simulator or connected device
2. Press **⌘R** (Cmd+R) to build and run
3. If build fails, check the issues:
   - Make sure all packages are added
   - Verify all source files are added to target
   - Check import statements

## Common Build Issues & Solutions

### Issue: "No such module 'TSSEngine'" (or other packages)

**Solution:**
1. Go to **File → Packages → Reset Package Caches**
2. Clean build folder: **Product → Clean Build Folder** (⇧⌘K)
3. Rebuild: **Product → Build** (⌘B)

### Issue: "Missing required module 'Persistence'"

**Solution:**
1. Check that Persistence package is added in **Project → Package Dependencies**
2. Make sure it's linked in **General → Frameworks, Libraries, and Embedded Content**

### Issue: SwiftData import errors

**Solution:**
- SwiftData requires iOS 17+. Make sure deployment target is iOS 18.0

### Issue: HealthKit authorization crashes

**Solution:**
1. Check `Info.plist` has privacy strings:
   - `NSHealthShareUsageDescription`
   - `NSHealthUpdateUsageDescription`
2. Make sure HealthKit capability is enabled
3. Simulator: Use a device that supports HealthKit

### Issue: Files appear red in Xcode

**Solution:**
1. Select the file in Project Navigator
2. In File Inspector (right sidebar), click folder icon next to **Location**
3. Navigate to the correct file location
4. Or delete reference and re-add the file

## Testing the Setup

### 1. Run Unit Tests

```bash
# In Xcode, press ⌘U (Cmd+U)
# Or: Product → Test
```

This will run all tests in `Packages/TSSEngine/Tests/`.

### 2. Quick Build Test

Press **⌘B** (Cmd+B) to build without running. Check for:
- ✅ No compiler errors
- ✅ All imports resolve correctly
- ✅ SwiftData models compile

### 3. Simulator Test

1. Run on **iPhone 15** simulator (⌘R)
2. You should see:
   - ✅ Onboarding screen
   - ✅ HealthKit permission request
   - ✅ Today view with Body Battery gauge (mock data)

## Project Organization in Xcode

After setup, your Xcode Project Navigator should look like:

```
ohMyTss
├── ohMyTss/
│   ├── App/
│   │   ├── OnMyTSSApp.swift
│   │   └── ContentView.swift
│   ├── Views/
│   │   ├── Onboarding/
│   │   ├── Today/
│   │   ├── History/
│   │   └── Settings/
│   ├── ViewModels/
│   │   └── TodayViewModel.swift
│   ├── Assets.xcassets
│   └── Info.plist
├── ohMyTssTests/
│   ├── Mocks/
│   └── ohMyTssTests.swift
├── Packages/
│   ├── TSSEngine
│   ├── HealthStore
│   ├── Persistence
│   └── SharedUI
└── Products/
    └── ohMyTss.app
```

## Next Steps After Setup

Once the project builds successfully:

1. **Wire up real data**: Connect HealthKit to TodayViewModel
2. **Implement recompute engine**: Create the main computation flow
3. **Add history charts**: Implement CTL/ATL/TSB visualization
4. **Test on device**: Test with real Apple Watch HRV data
5. **Add background refresh**: Implement BGTaskScheduler

## Need Help?

- **Xcode won't build?** Check Build Log: **View → Navigators → Reports** (⌘9)
- **Package issues?** Delete `~/Library/Developer/Xcode/DerivedData/`
- **Still stuck?** Open an issue on GitHub with build logs

---

**Ready to code!** 🚀

Once setup is complete, start with `TodayViewModel.swift` and wire up the HealthKit data flow.
