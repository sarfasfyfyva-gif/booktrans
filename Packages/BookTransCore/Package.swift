// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BookTransCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "BookTransCore", targets: ["BookTransCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "BookTransCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation", condition: .when(platforms: [.macOS, .iOS, .linux])),
            ]
        ),
        .testTarget(
            name: "BookTransCoreTests",
            dependencies: ["BookTransCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
