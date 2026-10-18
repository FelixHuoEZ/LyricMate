import Foundation

public enum L10n {
    public static let supportedLanguages = ["en", "zh-Hans"]
    private static let tokens = try! NSRegularExpression(pattern: #"%%|%([1-9][0-9]*)\$@"#)

    #if SWIFT_PACKAGE
    private static let resources = Bundle.module
    #else
    private static let resources = Bundle.main
    #endif

    private static let catalogs: [String: [String: String]] = {
        var result: [String: [String: String]] = [:]
        for language in supportedLanguages {
            // SwiftPM lowercases localization folders; the standalone bundle preserves their case.
            for folder in [language, language.lowercased()] {
                guard let url = resources.resourceURL?.appendingPathComponent(folder + ".lproj/Localizable.strings"),
                      let data = try? Data(contentsOf: url),
                      let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { continue }
                result[language] = table
                break
            }
        }
        return result
    }()

    public static func language(for preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: supportedLanguages, forPreferences: preferences).first ?? "en"
    }

    public static func text(_ key: String, _ arguments: String...) -> String {
        localized(key, preferences: Locale.preferredLanguages, arguments: arguments)
    }

    public static func localized(_ key: String, preferences: [String], arguments: [String] = []) -> String {
        let template = catalogs[language(for: preferences)]?[key] ?? key
        // Substitute only catalog tokens, never recursively interpret user-provided text.
        let matches = tokens.matches(in: template, range: NSRange(template.startIndex..., in: template))
        var output = ""
        var cursor = template.startIndex
        for match in matches {
            guard let range = Range(match.range, in: template) else { continue }
            output += template[cursor..<range.lowerBound]
            if template[range] == "%%" { output += "%" }
            else if let indexRange = Range(match.range(at: 1), in: template),
                    let index = Int(template[indexRange]), arguments.indices.contains(index - 1) {
                output += arguments[index - 1]
            } else { output += template[range] }
            cursor = range.upperBound
        }
        return output + template[cursor...]
    }

}
