# myMail App Store Completion Audit

Date: 2026-06-26

This audit separates repository-side completion from App Store Connect tasks that must be completed during submission.

## Objective Coverage

| Requirement | Status | Evidence |
| --- | --- | --- |
| Check App Store compliance | Repo-side complete | `docs/app-store-release.md` documents sandbox, privacy, encryption, metadata, icon, screenshots, review risks, and manual submission gates. |
| Fix local compliance gaps | Complete | `myMail/myMail/Info.plist` declares `LSApplicationCategoryType` and `ITSAppUsesNonExemptEncryption`; `myMail/myMail/PrivacyInfo.xcprivacy` is present. |
| Provide compliant app icon | Complete | `myMail/myMail/Assets.xcassets/AppIcon.appiconset` contains all macOS icon entries; `docs/mymail-app-icon-1024.png` is the preview. |
| Prepare release description | Complete | `docs/app-store-release.md` and `docs/app-store-metadata.json`. |
| Prepare promotional text | Complete | `docs/app-store-release.md` and `docs/app-store-metadata.json`. |
| Prepare keywords | Complete | `docs/app-store-release.md` and `docs/app-store-metadata.json`; Chinese keywords are under 100 UTF-8 bytes and English keywords are 95 characters. |
| Future App Store submission readiness | Locally ready, externally gated | Requires App Store Connect URLs, screenshots, review notes, and Apple Distribution archive upload. |

## Verified Local Evidence

These checks were performed against the current worktree and build products:

- `plutil -lint myMail/myMail/Info.plist myMail/myMail/PrivacyInfo.xcprivacy`: passed.
- `python3 -m json.tool docs/app-store-metadata.json`: passed.
- `python3 -m json.tool myMail/myMail/Assets.xcassets/AppIcon.appiconset/Contents.json`: passed.
- `xcodebuild -project myMail/myMail.xcodeproj -scheme myMail -configuration Release -destination 'platform=macOS,arch=arm64' build`: passed.
- `xcodebuild -project myMail/myMail.xcodeproj -scheme myMail -configuration Release -destination 'generic/platform=macOS' build`: passed.
- `lipo -archs .../Release/myMail.app/Contents/MacOS/myMail`: `x86_64 arm64`.
- Built app contains `Contents/Resources/AppIcon.icns`.
- Built app contains `Contents/Resources/PrivacyInfo.xcprivacy`.
- Built app `Info.plist` contains:
  - `CFBundleIdentifier=fudan.miniS.myMail`
  - `CFBundleShortVersionString=1.07`
  - `CFBundleVersion=4`
  - `LSApplicationCategoryType=public.app-category.productivity`
  - `ITSAppUsesNonExemptEncryption=false`
- `codesign --verify --deep --strict --verbose=2 .../Release/myMail.app`: passed for the local development-signed build.

## Local Constraints And Residual Risk

- Local Release builds are signed with Apple Development in this environment and include `com.apple.security.get-task-allow=true`. This is expected locally but must not be uploaded. Upload an Apple Distribution/App Store archive and verify `get-task-allow` is absent or false.
- `xcodebuild test` did not complete reliably in this desktop session because the XCTest runner timed out or hung while starting/cleaning up automation. `xcodebuild build-for-testing` passed. Re-run the full test suite in Xcode or CI before submission.
- The current generic Release build proves the app can produce a universal binary. A real App Store archive/export still has to be created by Xcode Organizer or `xcodebuild archive` plus `xcodebuild -exportArchive` with App Store signing.

## Required App Store Connect Gates

These cannot be completed from the repository alone:

1. Publish a privacy policy URL based on `docs/privacy-policy.md`.
2. Publish a support URL based on `docs/support.md`.
3. Upload clean screenshots using the plan in `docs/app-store-release.md`.
4. Fill App Privacy details consistently with `PrivacyInfo.xcprivacy`.
5. Fill export-compliance answers consistently with `ITSAppUsesNonExemptEncryption=false`.
6. Provide review notes and a review-safe test mailbox if login is required.
7. Confirm production Gmail OAuth Client ID and redirect scheme for bundle id `fudan.miniS.myMail`.
8. Upload only an Apple Distribution/App Store signed archive.

## Apple Reference Checklist

- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- App privacy details: https://developer.apple.com/app-store/app-privacy-details/
- Privacy manifest files: https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
- Required reason APIs: https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- App metadata reference: https://developer.apple.com/help/app-store-connect/reference/app-metadata-reference
- App icons: https://developer.apple.com/design/human-interface-guidelines/app-icons
