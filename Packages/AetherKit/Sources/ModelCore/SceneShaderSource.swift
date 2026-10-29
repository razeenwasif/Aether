import Foundation

/// Metal source for the viewport: the surface shader each material becomes,
/// and the lines'. Proton's `gl.js`, in Metal: the core compiles a material's
/// graph into instructions, and this turns those into a fragment function, one
/// line an instruction. The lighting is a shading cue and no more: one key
/// light, a metal/rough response, a grey room, rolled off at the top.
public enum SceneShaderSource {
    /// What every surface program shares: the vertex stage, noise, and light.
    static let prelude = """
    #include <metal_stdlib>
    using namespace metal;

    struct Frame {
        float4x4 proj;
        float3 light;
        float3 tint;
    };

    struct Object {
        float4x4 modelView;
        float3x3 normal;
        float picked;
    };

    struct In {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
    };

    struct Out {
        float4 position [[position]];
        float3 eye;
        float3 obj;
        float3 normal;
    };

    vertex Out surfaceVertex(In in [[stage_in]], constant Frame &frame [[buffer(1)]], constant Object &object [[buffer(2)]]) {
        Out out;
        float4 eye = object.modelView * float4(in.position, 1.0);
        out.position = frame.proj * eye;
        out.eye = eye.xyz;
        out.obj = in.position;
        out.normal = object.normal * in.normal;
        return out;
    }

    float hash(float3 p) {
        p = fract(p * 0.3183099 + float3(0.1, 0.2, 0.3));
        p *= 17.0;
        return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
    }

    float lattice(float3 x) {
        float3 i = floor(x);
        float3 f = fract(x);
        f = f * f * (3.0 - 2.0 * f);
        return mix(
            mix(mix(hash(i + float3(0,0,0)), hash(i + float3(1,0,0)), f.x),
                mix(hash(i + float3(0,1,0)), hash(i + float3(1,1,0)), f.x), f.y),
            mix(mix(hash(i + float3(0,0,1)), hash(i + float3(1,0,1)), f.x),
                mix(hash(i + float3(0,1,1)), hash(i + float3(1,1,1)), f.x), f.y),
            f.z);
    }

    float fbm(float3 p, int octaves) {
        float sum = 0.0, amp = 0.5, total = 0.0;
        for (int i = 0; i < 8; i++) {
            if (i >= octaves) break;
            sum += amp * lattice(p);
            total += amp;
            amp *= 0.5;
            p *= 2.0;
        }
        return total > 0.0 ? sum / total : 0.0;
    }

    float checker(float3 p, float scale) {
        float3 cell = floor(p * scale);
        return fmod(abs(cell.x + cell.y + cell.z), 2.0);
    }

    constant float LIGHT = 3.2;
    constant float AMBIENT = 0.22;
    constant float ROOM = 0.5;

    float3 lit(float3 base, float metal, float rough, float3 n, float3 v, float3 l) {
        float ndl = max(dot(n, l), 0.0);
        float ndv = max(dot(n, v), 0.0);
        float3 h = normalize(l + v);
        float ndh = max(dot(n, h), 0.0);
        float vdh = max(dot(v, h), 0.0);
        float a = rough * rough;
        float a2 = a * a;
        float d = ndh * ndh * (a2 - 1.0) + 1.0;
        float dist = a2 / (3.14159265 * d * d);
        float k = a * 0.5;
        float vis = 0.5 / (ndl * (ndv * (1.0 - k) + k) + ndv * (ndl * (1.0 - k) + k) + 1e-6);
        float spec = (ndl > 0.0 && ndv > 0.0) ? dist * vis : 0.0;
        float3 f0 = mix(float3(0.04), base, metal);
        float3 f = f0 + (1.0 - f0) * pow(1.0 - vdh, 5.0);
        float3 diffuse = base * (1.0 - metal) * (1.0 - f) / 3.14159265;
        float3 direct = (diffuse + spec * f) * ndl * LIGHT;
        float3 ambient = base * (1.0 - metal) * AMBIENT + f0 * ROOM;
        float3 total = direct + ambient;
        return sqrt(total / (1.0 + total));
    }

    struct Line {
        float3 position [[attribute(0)]];
        float4 color [[attribute(1)]];
    };

    struct LineOut {
        float4 position [[position]];
        float4 color;
    };

    vertex LineOut lineVertex(Line in [[stage_in]], constant float4x4 &viewProj [[buffer(1)]]) {
        LineOut out;
        out.position = viewProj * float4(in.position, 1.0);
        out.color = in.color;
        return out;
    }

    fragment float4 lineFragment(LineOut in [[stage_in]]) {
        return in.color;
    }

    // Edit mode's edges, corners and chosen faces: drawn over the mesh they
    // belong to, each pulled a fifth of a percent of its distance toward the
    // eye, so they sit on the surface without showing through from behind.
    struct Overlay {
        float4x4 view;
        float4x4 proj;
        float size;
    };

    struct PointOut {
        float4 position [[position]];
        float4 color;
        float size [[point_size]];
    };

    float4 overlaid(float3 position, constant Overlay &o) {
        float4 eye = o.view * float4(position, 1.0);
        eye.xyz *= 0.998;
        return o.proj * eye;
    }

    vertex LineOut overlayVertex(Line in [[stage_in]], constant Overlay &o [[buffer(1)]]) {
        LineOut out;
        out.position = overlaid(in.position, o);
        out.color = in.color;
        return out;
    }

    vertex PointOut pointVertex(Line in [[stage_in]], constant Overlay &o [[buffer(1)]]) {
        PointOut out;
        out.position = overlaid(in.position, o);
        out.color = in.color;
        out.size = o.size;
        return out;
    }

    fragment float4 pointFragment(PointOut in [[stage_in]], float2 at [[point_coord]]) {
        if (length(at - 0.5) > 0.5) discard_fragment();
        return in.color;
    }

    """

    /// The source of one surface program, from a material's compiled
    /// instructions — or the plain grey with none, or one the core couldn't
    /// compile. Its fragment function is `surfaceFragment`. The constants
    /// aren't in it: they're read from buffer 4 (`constants(of:)`), so a
    /// colour changed, or dragged, draws with the program already compiled.
    public static func surface(_ shader: SceneShader?) -> String {
        var lines: [String] = []
        if let shader, shader.problem.isEmpty, !shader.ops.isEmpty {
            var k = 0
            for (at, op) in shader.ops.enumerated() {
                let r = "r\(at)"
                switch op {
                case .constant:
                    lines.append("    float3 \(r) = k[\(k)].xyz;")
                    k += 1
                case .position:
                    lines.append("    float3 \(r) = in.obj;")
                case let .noise(from, scale, detail):
                    lines.append("    float3 \(r) = float3(fbm(r\(from) * \(num(scale)), \(max(1, min(8, Int(detail.rounded()))))));")
                case let .checker(from, scale):
                    lines.append("    float3 \(r) = float3(checker(r\(from), \(num(scale))));")
                case let .mix(a, b, fac):
                    lines.append("    float3 \(r) = mix(r\(a), r\(b), clamp(r\(fac).x, 0.0, 1.0));")
                case .unknown:
                    lines.append("    float3 \(r) = float3(0.78);")
                }
            }
            lines.append("    float3 base = r\(shader.base);")
            lines.append("    float metal = clamp(r\(shader.metallic).x, 0.0, 1.0);")
            lines.append("    float rough = clamp(r\(shader.roughness).x, 0.03, 1.0);")
        } else {
            lines.append("    float3 base = float3(0.78);")
            lines.append("    float metal = 0.0;")
            lines.append("    float rough = 0.55;")
        }
        return prelude + """
        fragment float4 surfaceFragment(Out in [[stage_in]], bool front [[front_facing]], constant Frame &frame [[buffer(1)]], constant Object &object [[buffer(2)]], constant float4 *k [[buffer(4)]]) {
        \(lines.joined(separator: "\n"))
            float3 v = normalize(-in.eye);
            float3 n;
            if (dot(in.normal, in.normal) > 0.25) {
                n = normalize(in.normal);
                if (!front) n = -n;
            } else {
                n = normalize(cross(dfdx(in.eye), dfdy(in.eye)));
                if (dot(n, v) < 0.0) n = -n;
            }
            float3 colour = lit(mix(base, frame.tint, object.picked * 0.3), metal, rough, n, v, frame.light);
            // The object chosen: tinted, and lit round its edge in ice, so it
            // reads at a glance against a grey of the same brightness.
            float rim = pow(1.0 - max(dot(n, v), 0.0), 2.0);
            colour = mix(colour, frame.tint, object.picked * (0.12 + 0.7 * rim));
            return float4(colour, 1.0);
        }

        """
    }

    /// What tells two programs apart: equal for the same instructions,
    /// whatever their constants.
    public static func key(_ shader: SceneShader?) -> String {
        guard let shader, shader.problem.isEmpty, !shader.ops.isEmpty else { return "plain" }
        let ops = shader.ops.map { op -> String in
            if case .constant = op { return "k" }
            return "\(op)"
        }
        return "\(ops)|\(shader.base)|\(shader.metallic)|\(shader.roughness)"
    }

    /// The constants a program reads from buffer 4, in order: never empty,
    /// as the buffer is bound whatever the program.
    public static func constants(of shader: SceneShader?) -> [SIMD4<Float>] {
        var out: [SIMD4<Float>] = []
        if let shader, shader.problem.isEmpty {
            for case .constant(let v) in shader.ops {
                out.append(SIMD4(v.count > 0 ? v[0] : 0, v.count > 1 ? v[1] : 0, v.count > 2 ? v[2] : 0, 1))
            }
        }
        return out.isEmpty ? [SIMD4(0, 0, 0, 1)] : out
    }

    /// A float Metal reads as one.
    static func num(_ value: Float) -> String {
        guard value.isFinite else { return "0.0" }
        return value == value.rounded() && abs(value) < 1e7 ? String(format: "%.1f", value) : "\(value)"
    }
}
