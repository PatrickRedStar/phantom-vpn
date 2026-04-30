// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhantomKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v15),
    ],
    products: [
        .library(name: "PhantomKit", targets: ["PhantomKit"]),
        .library(name: "PhantomUI",  targets: ["PhantomUI"]),
    ],
    targets: [
        .binaryTarget(
            name: "PhantomCore",
            path: "../../Frameworks/PhantomCore.xcframework"
        ),
        .target(
            name: "PhantomKit",
            dependencies: ["PhantomCore"],
            path: "Sources/PhantomKit",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "PhantomUI",
            dependencies: ["PhantomKit"],
            path: "Sources/PhantomUI",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "PhantomCoreTestStubs",
            path: "Tests/PhantomCoreTestStubs",
            publicHeadersPath: "."
        ),
        .testTarget(
            name: "PhantomKitTests",
            dependencies: ["PhantomKit"],
            path: "Tests/PhantomKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
