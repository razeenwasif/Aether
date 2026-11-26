// swift-tools-version: 6.2
// PhotonKit: everything in Photon except the app target itself.
//
//   PhotonDiffuseFFI  the Rust core (proton-diffuse via UniFFI), built by scripts/build-cores.sh
//   DiffuseBridge     the generated Swift bindings for it
//   DiffuseCore       flows, the catalogue, image backends and the run queue
//   DiffuseLocal      image generation on this Mac: Apple's Core ML Stable Diffusion
//   photon-local-bench  times local runs, and the text encoders on each compute unit
//   CanvasCore        a canvas open for editing (proton-raster via the bridge), its pixels in tiles
//   CanvasUI          the Canvas workspace: the canvas, layers, tools
//   ModelCore         a scene open for editing (proton-scene and proton-mesh via the bridge), a mesh in Edit mode (photon-poly), its maths, its Metal source
//   ModelUI           the Model workspace: the Metal viewport, the outliner, the inspector, Edit mode
//   GameCore          a game open for editing (proton-game via the bridge), a run of it, its parallax arithmetic
//   GameUI            the Game workspace: the room stage, rooms and entities, Play
//   DesignCore        a design open for editing (photon-design and proton-design via the bridge), its tokens resolved, its pages laid out
//   DesignUI          the Design workspace: the artboards, layers and tokens, the inspector, the code drawer
//   PhotonGraph       the project: one graph of assets and links, transactions, undo, the package
//   PhotonDesign      Velvet Obsidian: tokens, glass, controls
//   DiffuseUI         the Diffuse workspace: the flow canvas, node library, inspector
//   PhotonShell       the window: the rail, panels and workspaces
import PackageDescription

let package = Package(
    name: "PhotonKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PhotonKit", targets: ["PhotonShell"]),
    ],
    dependencies: [
        // Apple's Core ML Stable Diffusion pipeline, for runs on this Mac.
        .package(url: "https://github.com/apple/ml-stable-diffusion.git", exact: "1.1.1"),
    ],
    targets: [
        .binaryTarget(name: "PhotonDiffuseFFI", path: "Frameworks/PhotonDiffuseFFI.xcframework"),
        .target(
            name: "DiffuseBridge",
            dependencies: ["PhotonDiffuseFFI"],
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
        //   swift run -c release photon-local-bench --help
        .executableTarget(
            name: "photon-local-bench",
            dependencies: ["DiffuseCore", "DiffuseLocal", .product(name: "StableDiffusion", package: "ml-stable-diffusion")],
            path: "Sources/LocalBench"
        ),
        .target(name: "CanvasCore", dependencies: ["DiffuseBridge"]),
        .target(name: "PhotonGraph"),
        .target(name: "ModelCore", dependencies: ["DiffuseBridge"]),
        .target(name: "ModelUI", dependencies: ["ModelCore", "PhotonDesign", "PhotonGraph"]),
        .target(name: "GameCore", dependencies: ["DiffuseBridge"]),
        .target(name: "GameUI", dependencies: ["GameCore", "PhotonDesign", "PhotonGraph"]),
        .target(name: "DesignCore", dependencies: ["DiffuseBridge"]),
        .target(name: "DesignUI", dependencies: ["DesignCore", "PhotonDesign", "PhotonGraph"]),
        .target(name: "CanvasUI", dependencies: ["CanvasCore", "DiffuseBridge", "PhotonDesign", "PhotonGraph"]),
        .target(name: "PhotonDesign"),
        .target(name: "DiffuseUI", dependencies: ["DiffuseBridge", "DiffuseCore", "DiffuseLocal", "PhotonDesign", "PhotonGraph"]),
        .target(name: "PhotonShell", dependencies: ["PhotonDesign", "PhotonGraph", "CanvasCore", "CanvasUI", "DiffuseBridge", "DiffuseCore", "DiffuseUI", "DesignCore", "DesignUI", "GameCore", "GameUI", "ModelCore", "ModelUI"]),
        .testTarget(name: "ModelCoreTests", dependencies: ["ModelCore", "ModelUI", "PhotonGraph"]),
        .testTarget(name: "PhotonGraphTests", dependencies: ["PhotonGraph"]),
        .testTarget(name: "DesignCoreTests", dependencies: ["DesignCore", "DesignUI", "PhotonGraph"]),
        .testTarget(name: "GameCoreTests", dependencies: ["GameCore", "GameUI", "CanvasCore"]),
        .testTarget(
            name: "DiffuseLocalTests",
            dependencies: ["DiffuseLocal", .product(name: "StableDiffusion", package: "ml-stable-diffusion")]
        ),
        .testTarget(name: "CanvasCoreTests", dependencies: ["CanvasCore", "CanvasUI", "PhotonGraph"]),
        .testTarget(name: "PhotonShellTests", dependencies: ["PhotonShell", "PhotonGraph", "CanvasCore", "CanvasUI", "DiffuseUI", "DiffuseCore"]),
        .testTarget(name: "DiffuseUITests", dependencies: ["DiffuseUI", "DiffuseCore", "PhotonGraph"]),
        .testTarget(
            name: "DiffuseCoreTests",
            dependencies: ["DiffuseCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
