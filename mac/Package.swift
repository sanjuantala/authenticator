// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Totem",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Totem", targets: ["Totem"]),
        .executable(name: "TotemBridge", targets: ["TotemBridge"]),
    ],
    targets: [
        // Vault format, crypto, TOTP, merge, importers: shared logic, no UI.
        .target(name: "TotemCore"),
        // Menu bar app.
        .executableTarget(name: "Totem", dependencies: ["TotemCore"]),
        // Tiny native-messaging host Chrome launches; relays to the running app over a private socket.
        .executableTarget(name: "TotemBridge"),
        // Checks the core against the extension's vault format. Runs without XCTest (Command Line Tools are enough).
        .executableTarget(name: "TotemCoreCheck", dependencies: ["TotemCore"]),
        // Same checks as XCTest tests, for when full Xcode is installed (`swift test`).
        .testTarget(name: "TotemCoreTests", dependencies: ["TotemCore"], resources: [.copy("Fixtures")]),
    ]
)
