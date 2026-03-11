// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PolarCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PolarCore", targets: ["PolarCore"]),
    ],
    targets: [
        .target(
            name: "PolarCore",
            dependencies: ["polar_coreFFI"],
            path: "Sources/PolarCore"
        ),
        .target(
            name: "polar_coreFFI",
            path: "Sources/PolarCoreFFI",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)",
                    "-lpolar_core",
                ]),
            ]
        ),
    ]
)
