# Changes vs upstream (binwiederhier/ntfy-ios)

Fork-original changes and backports that diverge from the `binwiederhier/ntfy-ios`
base, so we can track what to (eventually) upstream and what shipped when.

| Date | Change | Kind | ntfy issue | PR | sha | Release |
|------|--------|------|-----------|----|-----|---------|
| 2026-07-04 | Add `ntfyTests` unit-test target (host-based) + 4 seed tests; make app launchable under XCTest (guarded Firebase/push + Core Data in-memory) | infra/test | — | TBD | TBD | TBD |
| 2026-07-08 | Linkify bare URLs inside `text/markdown` messages (markdown parser only links `[text](url)`/`<url>`, so bare `https://…` was tappable as plain text but dead as markdown) — completes #1072 markdown + #1743 links | fix | [#1072](https://github.com/binwiederhier/ntfy/issues/1072) | TBD | TBD | TBD |
| 2026-07-14 | Resolve every gemoji alias, not just the first: `EmojiManager` indexed only `aliases.first`, so 43 aliases the ntfy web/Android clients accept (`thumbsup`, `poop`, `uk`, `telephone`, …) rendered as literal text instead of emoji | fix | — | TBD | TBD | TBD |
| 2026-07-15 | Title notifications with the subscription's custom display name: a renamed subscription showed its custom name in the subscription list and notification header, but titleless push/local notifications still showed the raw `ntfy.sh/topic` (the Android client honors the rename via `formatTitle`→`displayName`) | fix | — | TBD | TBD | TBD |
| 2026-07-17 | Honor Settings → "Download attachments" on the push/NSE path: `attachImageIfNeeded` fetched and stored every image attachment regardless of the setting, so "Never" and the size caps were silently ignored for notifications arriving by push (the in-app path already honored them). Also stop force-unwrapping the app-group container in `AttachmentFileStore` | fix | — | TBD | TBD | TBD |
| 2026-07-19 | Always resolve the "Add subscription" auth check: `ApiService.checkAuth` returned without calling its completion handler when the base URL was unparseable, and the Subscribe button clears its spinner only from that handler — so a base URL like `https://my server.com` (an internal space passes the app's `^https?://.+` validation but `URL(string:)` rejects it) left the sheet spinning forever with no error and no way out but force-quitting | fix | [#999](https://github.com/binwiederhier/ntfy/issues/999) | TBD | TBD | TBD |
| 2026-07-20 | Do Core Data work for "Add subscription" on the context's own queue: `Store.saveSubscription` inserted the `Subscription` on the *caller's* thread and wrapped only the save in `DispatchQueue.main.sync`, so subscribing from `SubscriptionAddView`'s background hop could silently fail to persist the topic, and would have deadlocked outright once that hop was removed. `saveSubscription`/`saveUser` now run under `context.performAndWait`, the swallowed `try?` save error is logged, and the two `checkAuth` completions hop to main before touching `@State` or the store | fix | — | TBD | TBD | TBD |

| Change | ntfy issue | Upstream PR | Fork PR | SHA | Release |
| Custom display names for subscriptions | [#1314](https://github.com/binwiederhier/ntfy/issues/1314) | [ntfy-ios#29](https://github.com/binwiederhier/ntfy-ios/pull/29) (AnimaI) | TBD | TBD | TBD |
| Rebrand to ntfy NextGen: bundle id `io.heckel.ntfy`→`com.legitimateapps.ntfynextgen`, app group, display name, team→3LTL47SJ8C (Legitimate LLC) | — | — | TBD | TBD | TBD |
