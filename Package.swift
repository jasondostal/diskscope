// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskScope",
    platforms: [.macOS(.v14)],
    targets: [
        // The index engine's first organ: the bulk filesystem scanner.
        // Real, tested module — both v1.0 search and v1.1 treemap are clients of this.
        .target(name: "DiskScopeCore"),
        // CLI harness: scan/benchmark, --watch (live FSEvents), --treemap (SVG render).
        .executableTarget(name: "diskscope-scan", dependencies: ["DiskScopeCore"]),
        // The SwiftUI app — interactive treemap.
        .executableTarget(name: "DiskScopeApp", dependencies: ["DiskScopeCore"]),
        .testTarget(name: "DiskScopeCoreTests", dependencies: ["DiskScopeCore"]),
    ]
)
