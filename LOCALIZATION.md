# Localization

The app and its notification extension compile the same `ntfy/Localization/Localizable.xcstrings`.
Camera permission copy is in `ntfy/Localization/InfoPlist.xcstrings`, compiled into the app.
The app-only `Legal.xcstrings` translates the displayed license notices and retains the canonical
notices verbatim in its English resources. The generated license source remains unmodified.
English is the source language. German is the first translation.

Add a language to all three catalogs in Xcode and translate every entry. Add its language identifier to
`knownRegions` if Xcode has not done so. No Swift changes are needed. `LocalizationTests` discovers
languages from the catalogs and requires translated, nonempty values in every table. It checks format
arguments as well. The tests copy the source catalog folder as a resource; there is no second
translation file to maintain.

Short navigation-title keys have separate translations from full action/VoiceOver labels so
Cancel/Save controls still leave room at accessibility sizes. Keep these captions compact.

Use complete messages and localized interpolation for display strings, including errors, notification
fallbacks and accessibility labels. Keep numeric counts as numbers and use catalog plural variants.
German uses `one` and `other`; Polish also needs `few` and `many`. Let Xcode add the categories for
the new language rather than assuming English plural rules. Preserve format specifiers and numeric
arguments when translating. Format dates, times, numbers and byte counts using Foundation formatters.
The tomorrow mute choice formats its actual deadline's time, including the user's clock preference.

Do not localize server message content, titles, tags, action labels, topic/server names or addresses.
The publish commands and executable encryption examples remain executable original code. The text
around them is translated. License display text is translated; canonical copyright names, addresses and English notices are
preserved in the bundled English resources. Product and programming-language names remain proper names.

All historical release-note entries are translated as complete entries. Add future notes in English
and all supported languages when the release version is bumped. Each entry stays in one language.

Run the English unit suite and the existing 21 navigation tests. Run the German traversal separately:

```sh
python3 ntfyNavigationUITests/run.py "$UDID" "$APP" "$UI_DERIVED_DATA" "$OUTPUT" \
  --seed --german --only testGermanMainScreens
```

The app is launched with `-AppleLanguages (de) -AppleLocale de_DE`. The German empty-state test
uses `--seed --empty-fixture --german --only testGermanEmptyList`. The Add-login test requires a
loopback fixture returning HTTP 401 for `/auth` on port 18091. Keep test fixtures isolated from real
subscriptions. The login check uses the existing Debug QR-scan input to fill and verify the
fixture server, avoiding keyboard/caret assumptions. With no `--only`, `--german` runs the main
and license screens, or just the empty state when `--empty-fixture` is supplied. The compact-header
and login replays are opt-in because they require the local auth fixture. Repeat the screen traversal in dark mode, at the largest accessibility text size and
on a small iPhone. Export and shrink screenshots before inspecting them; retain the text trees too.
