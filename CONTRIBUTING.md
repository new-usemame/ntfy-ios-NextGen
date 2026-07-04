# Contributing

Bug reports, fixes, and small features welcome.

## Reporting a bug

[Open an issue](https://github.com/new-usemame/ntfy-ios-NextGen/issues/new/choose) using the bug report template. Include your iOS version, device model, and app version — bug reports without those are still fine, we'll just ask follow-ups before we can act on them.

## Building the app

Requirements: a Mac with Xcode installed, matching the deployment target in `ntfy.xcodeproj` (iOS 14 for the app, iOS 15 for the Notification Service Extension).

1. Open `ntfy.xcodeproj` in Xcode, or build from the command line:
   ```
   xcodebuild -project ntfy.xcodeproj -scheme ntfy -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
   ```
2. Resolve SPM dependencies if Xcode doesn't do it automatically:
   ```
   xcodebuild -project ntfy.xcodeproj -scheme ntfy -resolvePackageDependencies
   ```
3. Run on the simulator via Xcode (Cmd+R) or `xcodebuild ... build-for-testing` / install the built `.app` onto a booted simulator.

A device build or a build that needs push notifications requires your own Apple Developer signing and a `GoogleService-Info.plist` (not included — see `docs/GETTING_STARTED.md` for the Firebase setup this app expects). Simulator builds don't need signing or Firebase config for most flows.

## Code style

Match the surrounding upstream SwiftUI style. This is a fork we intend to stay upstreamable, so keep diffs focused and don't reformat files you aren't otherwise changing.

## Submitting a PR

1. Fork → branch off `main` → commit → push → open a PR against `main`.
2. Keep PRs focused on one logical change.
3. CI must pass (`validate-author` at minimum). iOS build/test verification is currently done locally before merge rather than in GitHub Actions — GitHub-hosted macOS runners aren't used on this project (cost), and there's no self-hosted macOS runner attached to the public repo.
4. Describe what you tested (simulator + device, if applicable) in the PR description.

## Commit identity

Commits merged into this repo are committed under `new-usemame`. If you're an outside contributor, your own authorship is preserved and credited — you don't need to match this identity yourself; a maintainer applies the `community-contribution` label to exempt your PR from the committer check in `validate-author.yml`.

## Auto-merge

PRs labeled `safe-tier-1` (docs/markdown-only changes) auto-merge once CI is green. Everything else waits for review. See `.github/workflows/auto-merge-tier1.yml` for the exact gate.

## Credit

Contributions are credited by handle in commit history and release notes. We don't squash credit out.
