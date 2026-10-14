// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MTPKit",
    platforms: [.macOS("27.0")],               // .macOS(.v27) needs tools 6.4
    products: [.library(name: "MTPKit", targets: ["MTPKit"])],
    targets: [
        .target(name: "MTPKit",
                linkerSettings: [.linkedFramework("IOUSBHost"), .linkedFramework("IOKit")]),
        .testTarget(name: "MTPKitTests", dependencies: ["MTPKit"], resources: [.copy("Fixtures")]),
    ]
)
