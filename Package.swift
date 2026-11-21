// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AlfalfaDesktop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "alfalfa-desktop", targets: ["AlfalfaDesktop"])],
    targets: [
        .executableTarget(name: "AlfalfaDesktop"),
        .testTarget(name: "AlfalfaDesktopTests", dependencies: ["AlfalfaDesktop"])
    ]
)
