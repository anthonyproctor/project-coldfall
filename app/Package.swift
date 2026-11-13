// swift-tools-version:5.9
import PackageDescription
import Foundation

// Ghostty's terminal (libghostty), when scripts/ghostty-kit.sh has built it
// into Vendor/. Optional on purpose: it's 140 MB, built with Zig and Apple's
// Metal toolchain, so it isn't in the repo, and without it Coldfall builds
// exactly as before with SwiftTerm. Code that uses it checks
// `#if canImport(GhosttyKit)`.
let ghosttyKit = Context.packageDirectory + "/Vendor/GhosttyKit.xcframework"
let hasGhostty = FileManager.default.fileExists(atPath: ghosttyKit)

// Two targets on purpose. ColdfallCore must not import AppKit — that boundary
// is what keeps a future Linux or Windows front end a UI project rather than a
// rewrite. Roughly a third of the code lives below the line and is already
// nothing but file reads and CLI invocations.
let package = Package(
    name: "ProjectColdfall",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ColdfallCore", targets: ["ColdfallCore"]),
        .executable(name: "Coldfall", targets: ["Coldfall"]),
        .executable(name: "coldfall-cli", targets: ["ColdfallCLI"]),
        .executable(name: "coldfall-holder", targets: ["ColdfallHolder"]),
        .executable(name: "coldfall-test", targets: ["ColdfallTests"]),
    ],
    dependencies: [
        // Pinned to one commit, not tracking main. CI failed on its first run
        // because main had moved to a Swift tools version newer than the
        // runner's — a build that breaks with no change on our side is not a
        // dependency, it is a liability.
        //
        // From a fork, for one line: SwiftTerm 1.20 lists its Metal shader as
        // a processed resource, and Swift 6.4's SwiftPM (macOS 27's Command
        // Line Tools) compiles that with the Metal toolchain, which CLT does not
        // include, so a source build failed with "unable to spawn process
        // metal". The fork is v1.20.0 plus that file moved to the exclude list;
        // the renderer, which Coldfall never turns on, loads the shader source
        // at runtime anyway. Upstream did the same after its 2.0 API break, so
        // this goes away when Coldfall moves to SwiftTerm 2.
        .package(url: "https://github.com/anthonyproctor/SwiftTerm", revision: "969ef554bc4f3746bbe7385032abacff27c82a3a")
    ],
    targets: [
        // No platform UI dependency of any kind.
        .target(name: "ColdfallCore"),
        // The macOS front end.
        .executableTarget(name: "Coldfall",
                          dependencies: ["ColdfallCore", "SwiftTerm"] + (hasGhostty ? ["GhosttyKit"] : []),
                          linkerSettings: hasGhostty ? [
                              .linkedFramework("Carbon"), .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
                              .linkedFramework("CoreText"), .linkedFramework("IOSurface"), .linkedLibrary("c++"),
                          ] : []),
        // Proves the core is genuinely headless, and gives a front end in any
        // language something to shell out to.
        .executableTarget(name: "ColdfallCLI", dependencies: ["ColdfallCore"]),
        // Keeps a desk's agent running when the app quits (see Holder). Core
        // only: it runs outside the app and draws nothing.
        .executableTarget(name: "ColdfallHolder", dependencies: ["ColdfallCore"]),
        // Plain executable, not XCTest. XCTest ships with Xcode, and the whole
        // point of this project building on Command Line Tools alone is that a
        // contributor needs no 15GB download — tests that break that promise
        // are worse than tests that are slightly less ergonomic.
        .executableTarget(name: "ColdfallTests", dependencies: ["ColdfallCore"]),
    ] + (hasGhostty ? [.binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework")] : [])
)
