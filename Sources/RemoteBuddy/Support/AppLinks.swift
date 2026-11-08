import Foundation

enum AppLinks {
    static let githubRepository = URL(
        string: "https://github.com/zfdang/voice-input-buddy"
    )!
    static let chineseWebsite = URL(string: "https://voice.zfdang.com/")!
    static let englishWebsite = URL(string: "https://voice.zfdang.com/")!
    static let feedback = URL(
        string: "https://github.com/zfdang/voice-input-buddy/issues"
    )!
    static let doubaoInputMethod = URL(
        string: "https://shurufa.doubao.com/"
    )!
    static let bageshuoWebsite = URL(string: "https://bug.youdao.com/")!

    static func website(for locale: Locale) -> URL {
        locale.identifier.lowercased().hasPrefix("zh")
            ? chineseWebsite
            : englishWebsite
    }
}
