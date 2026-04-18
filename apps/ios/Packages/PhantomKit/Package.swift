// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhantomKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "PhantomKit", targets: ["PhantomKit"]),
    ],
    targets: [
        .target(
            name: "PhantomKit",
            path: "Sources/PhantomKit",
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
