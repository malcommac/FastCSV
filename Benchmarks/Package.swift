// swift-tools-version: 6.0
// Comparison benchmark. Kept apart from the library so FastCSV has no dependencies.

import PackageDescription

let package = Package(
    name: "Benchmarks",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/swiftcsv/SwiftCSV.git", exact: "0.10.0"),
        .package(url: "https://github.com/dehesa/CodableCSV.git", exact: "0.6.7"),
        .package(url: "https://github.com/yaslab/CSV.swift.git", exact: "2.5.2"),
    ],
    targets: [
        .target(name: "BenchSupport"),
        .executableTarget(name: "BenchNaive", dependencies: ["BenchSupport"]),
        .executableTarget(name: "BenchFastCSV", dependencies: ["BenchSupport", "FastCSV"]),
        .executableTarget(name: "BenchFastCSVTyped", dependencies: ["BenchSupport", "FastCSV"]),
        .executableTarget(name: "BenchSwiftCSV", dependencies: ["BenchSupport", "SwiftCSV"]),
        .executableTarget(name: "BenchCodableCSV", dependencies: ["BenchSupport", "CodableCSV"]),
        .executableTarget(name: "BenchCSVSwift", dependencies: [
            "BenchSupport", .product(name: "CSV", package: "CSV.swift"),
        ]),
    ]
)
