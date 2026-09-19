// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PiDesk",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "PiDesk", targets: ["PiDesk"])],
    targets: [
        .executableTarget(name: "PiDesk", resources: [.copy("Resources/list-sessions.js"), .copy("Resources/list-project-files.js"), .copy("Resources/session-process.js")]),
        .testTarget(name: "PiDeskTests", dependencies: ["PiDesk"], resources: [.copy("Fixtures")])
    ]
)
