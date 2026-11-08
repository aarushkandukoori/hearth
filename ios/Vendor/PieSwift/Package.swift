// swift-tools-version:6.2
// Pie's Swift package (pie-project/pie packages/swift at 6168f025d), trimmed to
// the two products Hearth uses. PieServerCore.xcframework is built by
// ios/scripts/build-pie.sh: Pie's C library for the iPhone, plus a stub for
// the Simulator (Pie's Metal engine runs on the device only).

import PackageDescription

let package = Package(
    name: "Pie",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PieClient", targets: ["PieClient"]),
        .library(name: "PieServer", targets: ["PieServer"]),
    ],
    targets: [
        .binaryTarget(name: "PieServerCore", path: "build/PieServerCore.xcframework"),
        .target(name: "PieClient"),
        .target(
            name: "PieServer",
            dependencies: ["PieServerCore", "PieClient"],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
                .linkedLibrary("iconv"),
            ]
        ),
    ]
)
