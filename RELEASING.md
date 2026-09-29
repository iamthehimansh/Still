# Public release

## Prerequisites

- A paid Apple Developer Program membership with permission to create Developer ID certificates.
- **Developer ID Application** certificate and its private key installed in the login keychain. An **Apple Development** certificate is not a substitute.
- A `notarytool` keychain profile named `Still-notary` (or pass your own profile name). Store Apple credentials locally using `xcrun notarytool store-credentials`; never add passwords or API keys to the repository.
- macOS build tools compatible with this macOS 26+ target.

## Build, sign, notarize

```sh
STILL_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./scripts/release.sh Still-notary
```

The script builds without starter media, signs every component with hardened runtime, checks signatures, submits to Apple, requires acceptance, staples the ticket, runs Gatekeeper verification, and creates a release ZIP and checksum. If any step fails, it stops before producing a release-ready archive. Private API compatibility and notarization acceptance must be verified; neither is guaranteed by having a certificate.

Test the result on a clean Mac: import media, select the wallpaper, test desktop/saver/lock, sound, manual pause, Low Power Mode pause and image, then restore playback. Publishing requires the production artifact, not the ad-hoc development build.

## GitHub release

After verification, create a version tag, create GitHub release notes, and upload the notarized ZIP and its checksum. Update the website from “signed download in preparation” to the verified release link. Do not publish local videos or user settings.
