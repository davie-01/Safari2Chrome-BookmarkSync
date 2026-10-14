// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BookmarkSync",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "bmsync", targets: ["bmsync"]),
        .executable(name: "BookmarkSync", targets: ["BookmarkSyncApp"]),
    ],
    targets: [
        // Pure Foundation: Safari Bookmarks.plist model, normalization, fidelity-preserving edits.
        .target(name: "SafariBookmarks"),
        // Agent pieces: file store, state store, socket server, native messaging relay, installer.
        .target(name: "AgentCore", dependencies: ["SafariBookmarks"]),
        .executableTarget(name: "bmsync", dependencies: ["AgentCore", "SafariBookmarks"]),
        // SwiftUI shell: main window, settings, permissions, menu bar, endpoint management.
        .executableTarget(name: "BookmarkSyncApp", dependencies: ["AgentCore", "SafariBookmarks"]),
        .testTarget(name: "SafariBookmarksTests", dependencies: ["SafariBookmarks", "AgentCore"], resources: [.copy("Resources")]),
    ]
)
