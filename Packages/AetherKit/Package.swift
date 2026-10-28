// swift-tools-version: 6.2
// AetherKit: everything in Aether except the app target itself.
//
//   AetherDiffuseFFI  the Rust core (proton-diffuse via UniFFI), built by scripts/build-cores.sh
//   DiffuseBridge     the generated Swift bindings for it
//   DiffuseCore       flows, the catalogue, image backends and the run queue
//   DiffuseLocal      image generation on this Mac: Apple's Core ML Stable Diffusion
//   aether-local-bench  times local runs, and the text encoders on each compute unit
//   CanvasCore        a canvas open for editing (proton-raster via the bridge), its pixels in tiles
//   CanvasUI          the Canvas workspace: the canvas, layers, tools
//   AetherGraph       the project: one graph of assets and links, transactions, undo, the package
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
    dependencies: [
        // Apple's Core ML Stable Diffusion pipeline, for runs on this Mac.
        .package(url: "https://github.com/apple/ml-stable-diffusion.git", exact: "1.1.1"),
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
        .target(
            name: "DiffuseLocal",
            dependencies: ["DiffuseCore", .product(name: "StableDiffusion", package: "ml-stable-diffusion")]
        ),
        // Times local runs and the text encoders on each compute unit:
        //   swift run -c release aether-local-bench --help
        .executableTarget(
            name: "aether-local-bench",
            dependencies: ["DiffuseCore", "DiffuseLocal", .product(name: "StableDiffusion", package: "ml-stable-diffusion")],
            path: "Sources/LocalBench"
        ),
        .target(name: "CanvasCore", dependencies: ["DiffuseBridge"]),
        .target(name: "AetherGraph"),
        .target(name: "CanvasUI", dependencies: ["CanvasCore", "AetherDesign", "AetherGraph"]),
        .target(name: "AetherDesign"),
        .target(name: "DiffuseUI", dependencies: ["DiffuseBridge", "DiffuseCore", "DiffuseLocal", "AetherDesign", "AetherGraph"]),
        .target(name: "AetherShell", dependencies: ["AetherDesign", "AetherGraph", "CanvasCore", "CanvasUI", "DiffuseBridge", "DiffuseCore", "DiffuseUI"]),
        .testTarget(name: "AetherGraphTests", dependencies: ["AetherGraph"]),
        .testTarget(
            name: "DiffuseLocalTests",
            dependencies: ["DiffuseLocal", .product(name: "StableDiffusion", package: "ml-stable-diffusion")]
        ),
        .testTarget(name: "CanvasCoreTests", dependencies: ["CanvasCore", "CanvasUI", "AetherGraph"]),
        .testTarget(name: "AetherShellTests", dependencies: ["AetherShell", "AetherGraph"]),
        .testTarget(
            name: "DiffuseCoreTests",
            dependencies: ["DiffuseCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
