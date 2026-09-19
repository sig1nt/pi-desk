// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PiDesk",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "PiDesk", targets: ["PiDesk"])],
    targets: [.executableTarget(name: "PiDesk")]
)
