// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "PiDesk",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "PiDesk", targets: ["PiDesk"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.3.2")
    ],
    targets: [
        .executableTarget(name: "PiDesk", resources: [.copy("Resources/list-sessions.js"), .copy("Resources/list-project-files.js"), .copy("Resources/session-process.js")]),
        .testTarget(
            name: "PiDeskTests",
            dependencies: ["PiDesk", .product(name: "Testing", package: "swift-testing")],
            resources: [.copy("Fixtures")]
        )
    ]
)
