import XCTest
@testable import ntfy

final class LocalizationTests: XCTestCase {
    /// Raw catalog resources are copied from the same folder compiled into the app and NSE.
    /// Discover languages across all tables so adding a language automatically adds its gate.
    func testEveryCatalogEntryIsTranslatedInEverySupportedLanguage() throws {
        let folder = try XCTUnwrap(Bundle(for: Self.self).resourceURL?.appendingPathComponent("Localization"))
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" }
        XCTAssertEqual(urls.count, 3)
        let catalogs = try urls.map { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as! [String: Any] }
        let tables = catalogs.map { $0["strings"] as! [String: [String: Any]] }
        let languages = Set(tables.flatMap { $0.values.flatMap { ($0["localizations"] as? [String: Any])?.keys.map { $0 } ?? [] } })
        XCTAssertTrue(languages.contains("de"))
        let legal = tables[try XCTUnwrap(urls.firstIndex { $0.lastPathComponent == "Legal.xcstrings" })]
        let appCopy = tables[try XCTUnwrap(urls.firstIndex { $0.lastPathComponent == "Localizable.xcstrings" })]
        for component in OpenSourceLicenses.components {
            XCTAssertNotNil(appCopy[component.licenseName], "Missing license-name translation: \(component.licenseName)")
            for notice in [component.notice, component.licenseText].compactMap({ $0 }) {
                XCTAssertNotNil(legal[notice], "Generated notice changed; update its catalog translations: \(component.name)")
            }
        }

        for (table, url) in zip(tables, urls) {
            XCTAssertFalse(table.isEmpty)
            for (key, entry) in table {
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                for language in languages {
                    let value = try XCTUnwrap(localizations[language], "\(url.lastPathComponent): \(language) missing for \(key)")
                    let units = stringUnits(value)
                    XCTAssertFalse(units.isEmpty, "\(language): no values for \(key)")
                    for unit in units {
                        XCTAssertEqual(unit["state"] as? String, "translated", "\(language): \(key)")
                        let text = try XCTUnwrap(unit["value"] as? String)
                        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language): empty \(key)")
                        // InfoPlist uses symbolic keys. Other tables preserve all format arguments.
                        if url.lastPathComponent == "Localizable.xcstrings" {
                            XCTAssertEqual(placeholders(text), placeholders(key), "\(language): arguments differ for \(key)")
                        }
                    }
                }
            }
        }
    }

    private func stringUnits(_ node: Any) -> [[String: Any]] {
        guard let object = node as? [String: Any] else { return [] }
        if let unit = object["stringUnit"] as? [String: Any] { return [unit] }
        return object.values.flatMap(stringUnits)
    }

    private func placeholders(_ text: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:lld|ld|d|@)"#
        let expression = try! NSRegularExpression(pattern: pattern)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            let token = String(text[Range($0.range, in: text)!])
            return token.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
        }.sorted()
    }

    func testGermanPluralFormattingAndSharedNotificationCopy() throws {
        let bundle = try XCTUnwrap(Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        let locale = Locale(identifier: "de_DE")
        XCTAssertNil(DeliveryHealthCopy.retryIntervalLocale(language: "en", locale: locale))
        XCTAssertEqual(DeliveryHealthCopy.retryIntervalLocale(language: "pl", locale: Locale(identifier: "pl_PL")), Locale(identifier: "pl_PL"))
        func value(_ key: String, _ count: Int) -> String {
            String(format: bundle.localizedString(forKey: key, value: nil, table: nil), locale: locale, count)
        }
        XCTAssertEqual(value("%lld hours", 1), "1 Stunde")
        XCTAssertEqual(value("%lld hours", 2), "2 Stunden")
        XCTAssertEqual(value("%lld notifications", 1), "1 Benachrichtigung")
        XCTAssertEqual(value("%lld notifications", 0), "0 Benachrichtigungen")
        XCTAssertEqual(value("%lld notifications", 23), "23 Benachrichtigungen")
        XCTAssertEqual(bundle.localizedString(forKey: "Notification state synchronized", value: nil, table: nil), "Benachrichtigungsstatus synchronisiert")
        let canonicalMIT = OpenSourceLicenses.components[0].notice
        XCTAssertTrue(canonicalMIT.contains("Permission is hereby granted"))
        XCTAssertTrue(bundle.localizedString(forKey: canonicalMIT, value: nil, table: "Legal").contains("Hiermit wird jeder Person"))
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let extensionURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil).first { $0.pathExtension == "appex" })
        let extensionBundle = try XCTUnwrap(Bundle(url: extensionURL))
        let extensionGerman = try XCTUnwrap(extensionBundle.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(extensionGerman.localizedString(forKey: "Notification state synchronized", value: nil, table: nil), "Benachrichtigungsstatus synchronisiert")
        XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"), "NTFY me nutzt die Kamera nur, um QR-Codes für Themen zu scannen, die du abonnieren möchtest.")
        // Review eligibility uses this prefix in every bundled language, including old messages.
        // A future translator can fix an inconsistent prefix entirely in the catalog.
        for language in Bundle.main.localizations where language != "Base" {
            let localized = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            let prefix = localized.localizedString(forKey: Store.testMessagePrefix, value: nil, table: nil)
            for key in [
                "This is a test notification from NTFY me. Your topic is ready.",
                "This is a test notification from NTFY me. It has a priority of %lld. If you send another one, it may look different."
            ] {
                XCTAssertTrue(localized.localizedString(forKey: key, value: nil, table: nil).hasPrefix(prefix),
                              "\(language): test-message copy must retain its translated prefix")
            }
        }
        XCTAssertTrue(Store.isOwnTestMessage("Dies ist eine Testnachricht von NTFY me. Dein Thema ist bereit."))
        XCTAssertTrue(Store.isOwnTestMessage("This is a test notification from NTFY me. Your topic is ready."))
        XCTAssertFalse(Store.isOwnTestMessage("A real server message"))
        let store = Store(inMemory: true)
        let subscription = store.saveSubscription(baseUrl: "https://localization.invalid", topic: "locale-change")
        let messages = [
            Message(id: "de-test", time: 1_800_000_000, event: "message", topic: "locale-change", message: "Dies ist eine Testnachricht von NTFY me. Dein Thema ist bereit."),
            Message(id: "en-test", time: 1_800_000_001, event: "message", topic: "locale-change", message: "This is a test notification from NTFY me. Your topic is ready."),
            Message(id: "real", time: 1_800_000_002, event: "message", topic: "locale-change", message: "Backup complete")
        ]
        store.save(notificationsFromMessages: messages, withSubscription: subscription)
        messages.forEach { store.recordPresentation(message: $0, baseUrl: "https://localization.invalid") }
        XCTAssertEqual(store.presentedDeliveries().count, 1, "English and German test messages remain excluded across language changes")
        let locked = Notification(context: store.context)
        locked.encryption = NotificationEncryption.locked.rawValue
        locked.message = "Dies ist ein gespeicherter Platzhalter in einer anderen Sprache"
        XCTAssertEqual(locked.formatMessage(), TopicEncryption.lockedPlaceholder)
        locked.encryption = NotificationEncryption.none.rawValue
        XCTAssertEqual(locked.formatMessage(), locked.message, "readable server content must stay verbatim")
    }
}
