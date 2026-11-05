import Foundation
import Testing
@testable import ScreenRec

struct LocalizationTests {
    private struct Catalog: Decodable {
        struct Entry: Decodable { var localizations: [String: Localization]? }
        struct Localization: Decodable { var stringUnit: Unit? }
        struct Unit: Decodable { var value: String }
        var strings: [String: Entry]
    }

    private func catalog() throws -> Catalog {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ScreenRec/Resources/Localizable.xcstrings")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    private func placeholders(in text: String) -> [String] {
        text.matches(of: /%(?:\d+\$)?(@|lld|ld|d|lf|f)/).map { String($0.output.1) }.sorted()
    }

    @Test func everyStringHasBothLanguages() throws {
        for (key, entry) in try catalog().strings {
            for language in AppLanguage.allCases {
                let value = entry.localizations?[language.rawValue]?.stringUnit?.value ?? ""
                #expect(!value.isEmpty, "\(language.rawValue) fehlt für „\(key)“")
            }
        }
    }

    @Test func translationsKeepTheirPlaceholders() throws {
        for (key, entry) in try catalog().strings {
            for language in AppLanguage.allCases {
                let value = entry.localizations?[language.rawValue]?.stringUnit?.value ?? ""
                #expect(placeholders(in: value) == placeholders(in: key), "\(language.rawValue): „\(key)“")
            }
        }
    }

    @Test func appShipsBothLanguages() {
        #expect(Set(Bundle.main.localizations).isSuperset(of: AppLanguage.allCases.map(\.rawValue)))
    }

    @Test func trackTitleKeepsUnknownNames() {
        #expect(Track(kind: .video, name: "Meine Spur").title == "Meine Spur")
    }
}
