# Strava Integration Setup Guide

This guide will help you configure Strava OAuth integration for the onMyTss app.

## Prerequisites

- Xcode installed
- A Strava account
- Access to developers.strava.com

## Step 1: Register Your App with Strava

1. Go to https://www.strava.com/settings/api
2. Click "Create App" or "My API Application"
3. Fill in the following details:

   **Application Name:** onMyTss (or your preferred name)

   **Category:** Training

   **Club:** Leave blank (optional)

   **Website:** Your app's website (can use GitHub repo URL)

   **Authorization Callback Domain:** `localhost` (for development)

   **Application Description:** "Body Battery readiness score calculator for endurance athletes"

4. After creating the app, you'll see:
   - **Client ID** (a number, e.g., 123456)
   - **Client Secret** (a long string)

   **IMPORTANT:** Keep your Client Secret private! Never commit it to public repositories.

## Step 2: Configure URL Scheme in Xcode

1. Open `onMyTss.xcodeproj` in Xcode
2. Select the **onMyTss** project in the navigator
3. Select the **onMyTss** target
4. Go to the **Info** tab
5. Expand **URL Types** section (or add it if it doesn't exist)
6. Click the **+** button to add a new URL Type
7. Configure as follows:
   - **Identifier:** `com.onmytss.strava-auth`
   - **URL Schemes:** `onmytss`
   - **Role:** `Editor`

This allows Strava to redirect back to your app after OAuth authentication.

## Step 3: Configure Strava API Credentials

You have two options for configuring your Strava credentials:

### Option A: Direct Code Update (Development Only)

⚠️ **WARNING:** Only use this for local development. Never commit credentials to version control!

1. Open `onMyTss/Services/StravaAPI.swift`
2. Replace the placeholder values on lines 19-21:

```swift
static var clientID: String = "YOUR_CLIENT_ID"        // Replace with your Client ID
static var clientSecret: String = "YOUR_CLIENT_SECRET" // Replace with your Client Secret
static var redirectURI: String = "onmytss://strava-auth" // Already correct
```

3. Add `StravaAPI.swift` to your `.gitignore` (or use Option B)

### Option B: Environment Variables (Recommended for Production)

For production builds, use Xcode build configurations:

1. Create a new file: `Config.xcconfig`
2. Add your credentials:
   ```
   STRAVA_CLIENT_ID = YOUR_CLIENT_ID
   STRAVA_CLIENT_SECRET = YOUR_CLIENT_SECRET
   ```
3. Add `Config.xcconfig` to `.gitignore`
4. In Xcode project settings, set this config file for your build configurations
5. Update `StravaAPI.swift` to read from environment:
   ```swift
   static var clientID: String = ProcessInfo.processInfo.environment["STRAVA_CLIENT_ID"] ?? "YOUR_CLIENT_ID"
   static var clientSecret: String = ProcessInfo.processInfo.environment["STRAVA_CLIENT_SECRET"] ?? "YOUR_CLIENT_SECRET"
   ```

## Step 4: Update .gitignore

Add the following to your `.gitignore`:

```
# Strava API credentials
Config.xcconfig
**/StravaAPI.swift.local
```

## Step 5: Test the Integration

1. Build and run the app on a device or simulator
2. Complete onboarding
3. Go to Settings
4. Tap "Connect to Strava"
5. You should see the Strava OAuth page
6. Authorize the app
7. You should be redirected back to the app
8. Verify that:
   - Your Strava athlete name appears in Settings
   - Your Strava FTP is displayed (if set in Strava profile)
   - You can toggle between manual and Strava FTP

## Troubleshooting

### "Invalid redirect URI" error
- Verify URL scheme is exactly `onmytss` (no capitals, no spaces)
- Check that Authorization Callback Domain in Strava settings is `localhost`

### App doesn't open after authorizing
- Verify URL Types configuration in Xcode Info tab
- Make sure URL Scheme is `onmytss` (matches the redirect URI)
- Check that you're testing on a device/simulator that can handle URL schemes

### "Unauthorized" error
- Verify Client ID and Client Secret are correct
- Check that your Strava app is not in "draft" mode
- Ensure you've granted the app the required permissions (read, activity:read_all)

### No activities showing up
- Check that you have activities in your Strava account
- Verify date range (app fetches last 90 days by default)
- Check Settings > Last Sync to see if sync completed successfully

## Security Best Practices

1. **Never commit credentials** to version control
2. **Use environment variables** for production builds
3. **Rotate secrets** if they're accidentally exposed
4. **Use different credentials** for development vs. production
5. **Monitor API usage** in Strava Developer Dashboard

## API Rate Limits

Strava enforces the following rate limits:
- **600 requests per 15 minutes**
- **30,000 requests per day**

The app is designed to stay well under these limits by:
- Caching responses when possible
- Using pagination efficiently
- Only syncing when needed (not on every app launch)

## Next Steps

After completing this setup:
1. Test the OAuth flow thoroughly
2. Verify activity sync is working
3. Test FTP toggle functionality
4. Check that Strava workouts appear in History
5. Prepare for TestFlight by securing credentials in build configuration

## Resources

- [Strava API Documentation](https://developers.strava.com/docs/reference/)
- [Strava OAuth Flow](https://developers.strava.com/docs/authentication/)
- [Strava API Rate Limits](https://developers.strava.com/docs/rate-limits/)

## Support

For issues with:
- **Strava API:** Check [Strava Developer Forum](https://groups.google.com/g/strava-api)
- **App Integration:** Open an issue on GitHub
