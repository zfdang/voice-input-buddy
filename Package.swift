// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RemoteBuddy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "RemoteBuddy",
            targets: ["RemoteBuddy"]
        ),
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")],
    targets: [
        .executableTarget(
            name: "RemoteBuddy",
            dependencies: ["AudioExceptionGuard", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/RemoteBuddy"
        ),
        .target(
            name: "AudioExceptionGuard",
            path: "Sources/AudioExceptionGuard",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc", "-fobjc-arc-exceptions"])]
        ),
        .target(name: "AudioExceptionFixtures", dependencies: ["AudioExceptionGuard"],
            path: "Tests/AudioExceptionFixtures", publicHeadersPath: "include"),
        .testTarget(name: "RemoteBuddyTests", dependencies: ["RemoteBuddy", "AudioExceptionFixtures"], path: "Tests/RemoteBuddyTests"),
    ],
    swiftLanguageModes: [.v5]
)
