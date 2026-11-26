// The stage's shaders, in Metal: Proton's `game-render.js` programs ported.
// A sprite is one instanced quad of sixteen floats, and a skeleton's part
// triangles already where its pose puts them; a lit one is the room's
// ambient plus each light's colour falling off to nothing at its reach,
// shaded by the angle it meets the art's normal map at, or straight on
// without one. Afterwards: the bright part blurred small and laid back
// (bloom), a grade looked up in an n²×n strip, a vignette, and the picture
// scaled onto the screen (by whole numbers for pixel art).
enum GameRenderSource {
    static let lights = 16

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Sprite {
        float4 rect;    // x, y, w, h: world pixels
        float4 uv;      // u0, v0, u1, v1
        float4 tint;    // r, g, b, amount
        float4 misc;    // opacity, turn (radians), lit, flipped
    };

    struct Frame {
        float4x4 matrix;
        float4 ambient;         // rgb; w the number of lights
        float4 lights[\(lights * 2)]; // x, y, reach, height; r, g, b (times intensity)
    };

    struct Out {
        float4 position [[position]];
        float2 uv;
        float4 tint;
        float opacity;
        float2 world;
        float4 turn;    // cos, sin, lit, 1 or -1 flipped
        float4 color;   // multiplied in: a skeleton slot's colour
    };

    struct MeshPoint {
        float2 world;
        float2 uv;
        float4 color;
        float4 tint;
        float4 misc;    // opacity, 0, lit, 0
    };

    vertex Out spriteVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device Sprite *sprites [[buffer(0)]], constant Frame &frame [[buffer(1)]]) {
        Sprite s = sprites[iid];
        float2 corner = float2(float(vid & 1), float(vid >> 1));
        float2 half_size = s.rect.zw * 0.5;
        float2 local = (corner - 0.5) * s.rect.zw;
        float c = cos(s.misc.y), n = sin(s.misc.y);
        float2 world = s.rect.xy + half_size + float2(local.x * c - local.y * n, local.x * n + local.y * c);
        Out o;
        o.position = frame.matrix * float4(world, 0.0, 1.0);
        o.uv = mix(s.uv.xy, s.uv.zw, corner);
        o.tint = s.tint;
        o.opacity = s.misc.x;
        o.world = world;
        o.turn = float4(c, n, s.misc.z, s.misc.w > 0.5 ? -1.0 : 1.0);
        o.color = float4(1.0);
        return o;
    }

    // A skeleton's part: each point already where the pose puts it.
    vertex Out meshVertex(uint vid [[vertex_id]], const device MeshPoint *points [[buffer(0)]], constant Frame &frame [[buffer(1)]]) {
        MeshPoint p = points[vid];
        Out o;
        o.position = frame.matrix * float4(p.world, 0.0, 1.0);
        o.uv = p.uv;
        o.tint = p.tint;
        o.opacity = p.misc.x;
        o.world = p.world;
        o.turn = float4(1.0, 0.0, p.misc.z, 1.0);
        o.color = p.color;
        return o;
    }

    float3 lit(constant Frame &frame, float2 world, float3 normal, bool shaded) {
        float3 light = frame.ambient.rgb;
        int count = int(frame.ambient.w);
        for (int i = 0; i < count; i++) {
            float4 at = frame.lights[i * 2];
            float4 hue = frame.lights[i * 2 + 1];
            float2 d = at.xy - world;
            float fall = clamp(1.0 - length(d) / max(at.z, 1.0), 0.0, 1.0);
            fall *= fall;
            // The map's green is up, the world's y down.
            float facing = shaded ? max(dot(normal, normalize(float3(d.x, -d.y, at.w))), 0.0) : 1.0;
            light += hue.rgb * fall * facing;
        }
        return min(light, float3(4.0));
    }

    fragment float4 spriteFragment(Out in [[stage_in]], constant Frame &frame [[buffer(1)]], constant float &mapped [[buffer(2)]],
                                   texture2d<float> art [[texture(0)]], texture2d<float> normals [[texture(1)]], sampler s [[sampler(0)]]) {
        float4 texel = art.sample(s, in.uv);   // premultiplied
        float3 rgb = texel.rgb * in.color.rgb;
        if (in.turn.z > 0.5) {
            // The map's normal, flipped and turned with the art.
            float3 n = normals.sample(s, in.uv).xyz * 2.0 - 1.0;
            n.x *= in.turn.w;
            n.xy = float2(n.x * in.turn.x + n.y * in.turn.y, -n.x * in.turn.y + n.y * in.turn.x);
            rgb *= lit(frame, in.world, normalize(n), mapped > 0.5);
        }
        float3 hazed = mix(rgb, in.tint.rgb * texel.a, in.tint.a);
        return float4(hazed, texel.a) * in.color.a * in.opacity;
    }

    struct Full {
        float4 position [[position]];
        float2 uv;
    };

    // A triangle over the whole target.
    vertex Full fullVertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        Full o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    // What's bright enough to bloom: past the threshold, eased in.
    fragment float4 brightFragment(Full in [[stage_in]], texture2d<float> picture [[texture(0)]], sampler s [[sampler(0)]]) {
        float3 c = min(picture.sample(s, in.uv).rgb, float3(1.0));
        float b = max(c.r, max(c.g, c.b));
        float knee = clamp((b - 0.6) / 0.4, 0.0, 1.0);
        return float4(c * knee * knee, 1.0);
    }

    // One way of a Gaussian blur, nine taps.
    fragment float4 blurFragment(Full in [[stage_in]], texture2d<float> picture [[texture(0)]], sampler s [[sampler(0)]], constant float2 &step [[buffer(0)]]) {
        const float w[5] = {0.2270270, 0.1945946, 0.1216216, 0.0540541, 0.0162162};
        float3 c = picture.sample(s, in.uv).rgb * w[0];
        for (int i = 1; i < 5; i++) {
            c += picture.sample(s, in.uv + step * float(i)).rgb * w[i];
            c += picture.sample(s, in.uv - step * float(i)).rgb * w[i];
        }
        return float4(c, 1.0);
    }

    struct Finish {
        float bloom;
        float vignette;
        float lut;      // the grade's size a side; 0 for none
        float nearest;  // the picture scaled up by whole numbers, sampled nearest
    };

    float3 graded(texture2d<float> grade, sampler s, float3 c, float n) {
        float b = clamp(c.b, 0.0, 1.0) * (n - 1.0);
        float lo = floor(b), hi = min(lo + 1.0, n - 1.0);
        float2 at = float2(clamp(c.r, 0.0, 1.0) * (n - 1.0) + 0.5, clamp(c.g, 0.0, 1.0) * (n - 1.0) + 0.5);
        float3 a = grade.sample(s, float2((lo * n + at.x) / (n * n), at.y / n)).rgb;
        float3 d = grade.sample(s, float2((hi * n + at.x) / (n * n), at.y / n)).rgb;
        return mix(a, d, b - lo);
    }

    // The picture with its bloom laid over it, graded and vignetted.
    fragment float4 compositeFragment(Full in [[stage_in]], texture2d<float> picture [[texture(0)]], texture2d<float> bloom [[texture(1)]],
                                      texture2d<float> grade [[texture(2)]], constant Finish &finish [[buffer(0)]]) {
        constexpr sampler smooth(filter::linear, address::clamp_to_edge);
        constexpr sampler sharp(filter::nearest, address::clamp_to_edge);
        float3 c = (finish.nearest > 0.5 ? picture.sample(sharp, in.uv) : picture.sample(smooth, in.uv)).rgb;
        c = min(c, float3(1.0)) + bloom.sample(smooth, in.uv).rgb * finish.bloom;
        if (finish.lut > 0.5) c = graded(grade, smooth, c, finish.lut);
        float r = length(in.uv - 0.5) * 1.4142;
        c *= 1.0 - finish.vignette * smoothstep(0.35, 1.0, r);
        return float4(min(c, float3(1.0)), 1.0);
    }
    """
}
