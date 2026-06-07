// swift-tools-version:5.9
import PackageDescription

// WeftAppKit is the platform-agnostic core (failover supervisor, transport
// backends, the JS contract) — Foundation + Network only, so it builds and
// unit-tests with `swift test` (swift-testing) and no external deps.
//
// WeftAppKitSSH adds the SSH local-forward transport (Citadel / SwiftNIO).
// It is a separate target so WeftAppKit stays dependency-free; the app
// links WeftAppKitSSH when it wants SSH. Both build from the CLI without
// Xcode (the iOS app/extension targets are built by the Xcode project).
let package = Package(
    name: "WeftAppKit",
    // Citadel (SSH transport) requires iOS 17 / macOS 14.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WeftAppKit", targets: ["WeftAppKit"]),
        .library(name: "WeftAppKitSSH", targets: ["WeftAppKitSSH"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0"),
        // Pulled in (matching Citadel's own ranges) so the SSH integration
        // test can stand up an in-process Citadel SSH server.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "WeftAppKit"),
        .target(
            name: "WeftAppKitSSH",
            dependencies: [
                "WeftAppKit",
                .product(name: "Citadel", package: "Citadel"),
            ]
        ),
        .testTarget(name: "WeftAppKitTests", dependencies: ["WeftAppKit"]),
        .testTarget(
            name: "WeftAppKitSSHTests",
            dependencies: [
                "WeftAppKitSSH",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ]
)
