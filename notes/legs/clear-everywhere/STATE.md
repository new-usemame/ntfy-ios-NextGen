# Clear everywhere — complete for review

2026-10-08. Branch `feat/clear-everywhere`.

- Implemented sequence-aware store ingestion and delivery cleanup in foreground/poll, NSE and direct Firebase background paths.
- Local read/tap/dismiss sends best-effort authenticated clear, without republishing received controls.
- Additive Model 6 migration; no dependencies, entitlements, URL schemes or signing configuration changed.
- Verified baseline red (6 failed), mutation caught (2 failed), final full suite 334/334 green, simulator build green.
- Live ntfy-me.com foreground poll verified update-in-place, clear/read + delivered-notification removal, delete, and local topic-open publication. JPEG evidence beside this file.
- Independent review's blockers corrected and final bounded verdict clean.
- Server source confirms no self-hosted upstream forwarding for controls. Real FCM/APNs/NSE and multi-device propagation remain unverified; relay improvement is a separate server/client follow-up.
- Details, source lines, exact command shape and limits: [VERIFICATION.md](VERIFICATION.md).
- Remaining authorized step: commit/push and open `needs-review` PR. Do not merge or release.
- Local raw logs and simulator resource notes remain private/uncommitted; resource leases released after verification.
