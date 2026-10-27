// swift-tools-version: 6.2
// AetherKit: everything in Aether except the app target itself.
//
//   AetherDiffuseFFI  the Rust core (proton-diffuse via UniFFI), built by scripts/build-cores.sh
//   DiffuseBridge     the generated Swift bindings for it
//   DiffuseCore       flows, the catalogue, image backends and the run queue
//   AetherDesign      Velvet Obsidian: tokens, glass, controls
//   DiffuseUI         the Diffuse workspace: the flow canvas, node library, inspector
//   AetherShell       the window: the rail, panels and workspaces
import PackageDescription

let package = Package(
    name: "AetherKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AetherKit", targets: ["AetherShell"]),
    ],
    targets: [
        .binaryTarget(name: "AetherDiffuseFFI", path: "Frameworks/AetherDiffuseFFI.xcframework"),
        .target(
            name: "DiffuseBridge",
            dependencies: ["AetherDiffuseFFI"],
            linkerSettings: [
                // ureq's TLS checks certificates with the system's verifier.
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .target(
            name: "DiffuseCore",
            dependencies: ["DiffuseBridge"],
            resources: [.copy("Resources/catalogue-v1.json"), .copy("Resources/models.json")]
        ),
        .target(name: "AetherDesign"),
        .target(name: "DiffuseUI", dependencies: ["DiffuseBridge", "DiffuseCore", "AetherDesign"]),
        .target(name: "AetherShell", dependencies: ["AetherDesign", "DiffuseBridge", "DiffuseCore", "DiffuseUI"]),
        .testTarget(
            name: "DiffuseCoreTests",
            dependencies: ["DiffuseCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
