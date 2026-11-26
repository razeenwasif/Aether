import Foundation

/// A surface: its colour (linear RGB, 0 to 1), how metallic and how rough
/// (`photon_layers::Surface`).
public struct SceneSurface: Codable, Sendable, Equatable {
    public var color: [Double]
    public var metallic: Double
    public var roughness: Double

    public init(color: [Double], metallic: Double, roughness: Double) {
        self.color = color
        self.metallic = metallic
        self.roughness = roughness
    }

    public static let plain = SceneSurface(color: [0.8, 0.8, 0.8], metallic: 0, roughness: 0.5)
}

/// What decides where a layer covers.
public enum LayerPattern: String, Codable, Sendable, CaseIterable, Identifiable {
    case solid, noise, checker

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .solid: "square.fill"
        case .noise: "cloud.fill"
        case .checker: "checkerboard.rectangle"
        }
    }
}

/// One layer over a material's base (`photon_layers::Layer`).
public struct SceneLayer: Codable, Sendable, Equatable {
    public var pattern: LayerPattern
    public var surface: SceneSurface
    /// How much it covers where it covers, 0 to 1.
    public var amount: Double
    /// A pattern's cells or blots a metre, in the object's own space.
    public var scale: Double
    /// Noise's octaves, 1 to 8.
    public var detail: Double
    /// How much of the surface noise covers, 0 to 1.
    public var coverage: Double
    /// How hard noise's edge is, 0 to 1.
    public var edge: Double

    public init(pattern: LayerPattern, surface: SceneSurface, amount: Double = 1, scale: Double = 4, detail: Double = 3, coverage: Double = 0.5, edge: Double = 0.5) {
        self.pattern = pattern
        self.surface = surface
        self.amount = amount
        self.scale = scale
        self.detail = detail
        self.coverage = coverage
        self.edge = edge
    }

    /// A new layer of a pattern, as Add Layer makes it: something that reads
    /// at once over a plain grey.
    public static func starting(_ pattern: LayerPattern) -> SceneLayer {
        switch pattern {
        case .solid: SceneLayer(pattern: .solid, surface: SceneSurface(color: [0.75, 0.22, 0.14], metallic: 0, roughness: 0.4), amount: 0.5)
        case .noise: SceneLayer(pattern: .noise, surface: SceneSurface(color: [0.22, 0.16, 0.1], metallic: 0, roughness: 0.9), coverage: 0.4)
        case .checker: SceneLayer(pattern: .checker, surface: SceneSurface(color: [0.08, 0.08, 0.09], metallic: 0, roughness: 0.3))
        }
    }
}

/// A material as a base and the layers over it, bottom first
/// (`photon_layers::Stack`).
public struct SceneStack: Codable, Sendable, Equatable {
    public var base: SceneSurface
    public var layers: [SceneLayer]

    public init(base: SceneSurface = .plain, layers: [SceneLayer] = []) {
        self.base = base
        self.layers = layers
    }

    /// The most layers a stack takes (`photon_layers::MOST`).
    public static let most = 8
}
