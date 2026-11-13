import Foundation

enum AppLinks {
    static let githubRepository = URL(
        string: "https://github.com/zfdang/remote-buddy"
    )!
    static let githubReleases = URL(string: "https://github.com/zfdang/remote-buddy/releases")!
    static let chineseWebsite = URL(string: "https://remote.zfdang.com/")!
    static let englishWebsite = URL(
        string: "https://remote.zfdang.com/index.en.html"
    )!
    static let feedback = URL(
        string: "https://github.com/zfdang/remote-buddy/issues"
    )!
    static let doubaoInputMethod = URL(
        string: "https://shurufa.doubao.com/"
    )!
    static let bageshuoWebsite = URL(string: "https://bug.youdao.com/")!
    static let voiceBuddyChineseWebsite = URL(string: "https://myvoicebuddy.com/")!
    static let voiceBuddyEnglishWebsite = URL(
        string: "https://myvoicebuddy.com/en.html"
    )!

    static func website(for locale: Locale) -> URL {
        locale.identifier.lowercased().hasPrefix("zh")
            ? chineseWebsite
            : englishWebsite
    }

    static func voiceBuddyWebsite(for locale: Locale) -> URL {
        locale.identifier.lowercased().hasPrefix("zh")
            ? voiceBuddyChineseWebsite
            : voiceBuddyEnglishWebsite
    }
}
