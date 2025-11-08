# Quick Fix for "Multiple Commands Produce" Error

## Problem
The error `Multiple commands produce` means source files are added to the Xcode target multiple times.

## Solution

### Option 1: Fix in Xcode (Recommended)

#### 1. Remove Duplicate References

1. Open `ohMyTss.xcodeproj` in Xcode
2. Select **ohMyTss** project → **ohMyTss** target
3. Go to **Build Phases** tab
4. Expand **Compile Sources**
5. **Select all files** (Cmd+A)
6. Click **−** button to remove all
7. Confirm removal

#### 2. Clean Build

```
Product → Clean Build Folder (⇧⌘K)
```

#### 3. Add Files Correctly

**In Project Navigator:**
1. Right-click on `ohMyTss` (folder, not project)
2. **Add Files to "ohMyTss"...**
3. Navigate to your project: `/Users/mingjunliu/Developer/ohMyTss/ohMyTss/`
4. **Cmd+Click** to select:
   - `App` folder
   - `Views` folder
   - `ViewModels` folder
5. **IMPORTANT - Check these options:**
   - ✅ **Create groups** (NOT folder references)
   - ✅ **Add to targets: ohMyTss**
   - ❌ **Copy items if needed** (UNCHECK!)
6. Click **Add**

#### 4. Verify Compile Sources

Back in **Build Phases → Compile Sources**, you should see:
```
ContentView.swift
OnMyTSSApp.swift
TodayViewModel.swift
HistoryView.swift
OnboardingView.swift
SettingsView.swift
TodayView.swift
```

**Each file should appear ONLY ONCE.**

#### 5. Build

Press **⌘B**. Error should be gone!

---

### Option 2: Start Fresh (If Option 1 Fails)

If you're still having issues, recreate the project:

#### 1. Close Xcode

#### 2. Delete Xcode Project

```bash
cd /Users/mingjunliu/Developer/ohMyTss
rm -rf ohMyTss.xcodeproj
rm -rf ohMyTss/ohMyTss.entitlements
```

#### 3. Create New Xcode Project

1. Open Xcode
2. **File → New → Project**
3. Choose **iOS → App**
4. Settings:
   - **Product Name:** `ohMyTss`
   - **Organization Identifier:** `com.yourdomain`
   - **Interface:** SwiftUI
   - **Language:** Swift
   - **Storage:** SwiftData
   - **Include Tests:** Yes
5. **Save to:** `/Users/mingjunliu/Developer/ohMyTss/` (the main folder)
6. When prompted about existing files, choose **Don't Save** or **Replace**

#### 4. Delete Default Files

In Xcode Project Navigator, **delete** these (Move to Trash):
- `ContentView.swift` (the default one)
- `ohMyTssApp.swift` (the default one)
- `Item.swift` (if exists)

#### 5. Add Our Source Files

Follow **Option 1, Step 3** above to add:
- `App/` folder
- `Views/` folder
- `ViewModels/` folder

#### 6. Add Swift Packages

**File → Add Package Dependencies → Add Local:**
- Add `Packages/TSSEngine`
- Add `Packages/HealthStore`
- Add `Packages/Persistence`
- Add `Packages/SharedUI`

#### 7. Link Packages to Target

**General → Frameworks, Libraries, and Embedded Content:**

Click **+** and add:
- TSSEngine
- HealthStore
- Persistence
- SharedUI

#### 8. Configure Capabilities

**Signing & Capabilities:**
- Add **HealthKit** capability
- Add **App Groups** → `group.com.onmytss.app`

#### 9. Update Info.plist

Copy our `Info.plist` contents:
```bash
# In Terminal
cat ohMyTss/Info.plist
```

Copy the HealthKit privacy strings to the new Info.plist.

#### 10. Build

Press **⌘B** to build!

---

## Common Mistakes

❌ **DON'T:**
- Add files twice
- Check "Copy items if needed" for files already in project
- Add both individual files AND parent folders
- Use "Folder References" instead of "Create groups"

✅ **DO:**
- Add folders as "Groups"
- Add files only once
- Make sure "Add to targets" is checked
- Keep files in their original location

---

## Verification Checklist

After fixing, verify:

- [ ] Each `.swift` file appears **only once** in Build Phases → Compile Sources
- [ ] Project builds without "Multiple commands" errors
- [ ] All 4 packages appear under project dependencies
- [ ] All 4 packages linked in Frameworks, Libraries, and Embedded Content
- [ ] HealthKit capability enabled
- [ ] App Groups configured

---

## Still Having Issues?

1. **Check file locations:**
   ```bash
   ls -R ohMyTss/
   ```

2. **Clean DerivedData:**
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData/*
   ```

3. **Reset Package Caches:**
   ```
   File → Packages → Reset Package Caches
   ```

4. **Restart Xcode**

---

**After following these steps, you should have a clean build!**
