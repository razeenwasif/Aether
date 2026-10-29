import Foundation

/// Metal source for Render's path tracer: a compute kernel that follows rays
/// through the scene on Metal's ray tracing, one sample a pixel at a time,
/// adding up in a texture, and a second that tones the sum into a picture.
/// Between them, if asked, a denoiser: what each pixel first saw (its
/// surface's colour, which way it faced, how far off) is summed alongside
/// the light, and an edge-aware filter smooths the light where those agree
/// and the samples are unsure, so a few dozen samples look like hundreds.
///
/// It shades as the view does, so a path-traced render and a quick one agree
/// where they can: the same materials (each material's program becomes a
/// function, chosen by the triangle's slot), the same metal/rough response,
/// the same lights at the same brightness, and the same tone curve. What it
/// adds is what a raster can't: light that bounces (from a dim, even room
/// round everything), soft shadows from lights with a size, and reflections.
extension SceneShaderSource {
    /// The tracer for a scene whose materials compile to `shaders`; slot 0
    /// is the plain grey (no material, and the floor), slot n is
    /// `shaders[n - 1]`.
    public static func tracer(_ shaders: [SceneShader?]) -> String {
        var functions = ""
        var cases = "        case 0: return plainSurface();\n"
        for (i, shader) in shaders.enumerated() {
            let lines = body(shader, at: "obj").joined(separator: "\n")
            functions += """
            Surface material\(i + 1)(float3 obj, constant float4 *k) {
            \(lines)
                return Surface{base, metal, rough};
            }

            """
            cases += "        case \(i + 1): return material\(i + 1)(obj, k + start[\(i + 1)]);\n"
        }
        return prelude + traceHead + functions + """
        Surface surfaceAt(uint slot, float3 obj, constant float4 *k, constant uint *start) {
            switch (slot) {
        \(cases)        default: return plainSurface();
            }
        }

        """ + traceKernel
    }

    /// What tells two tracers apart: the same programs, whatever their
    /// constants.
    public static func tracerKey(_ shaders: [SceneShader?]) -> String {
        shaders.map(key).joined(separator: "||")
    }

    /// The constants each slot's program reads, one after another, and where
    /// each slot's start: slot 0 reads none.
    public static func tracerConstants(_ shaders: [SceneShader?]) -> (values: [SIMD4<Float>], starts: [UInt32]) {
        var values: [SIMD4<Float>] = [SIMD4(0, 0, 0, 1)]
        var starts: [UInt32] = [0]
        for shader in shaders {
            starts.append(UInt32(values.count))
            values += constants(of: shader)
        }
        return (values, starts)
    }

    static let traceHead = """

    #include <metal_raytracing>
    using namespace raytracing;

    struct Surface {
        float3 base;
        float metal;
        float rough;
    };

    Surface plainSurface() {
        return Surface{float3(0.78), 0.0, 0.55};
    }

    """

    static let traceKernel = """
    // The light round everything, for rays that leave the scene: a dim, even
    // room, as the view's ambient term stands for.
    constant float ROOM_LIGHT = 0.22;

    constant float3 LUMA = float3(0.2126, 0.7152, 0.0722);

    struct TraceFrame {
        float4x4 eye;        // the camera's place and turn in the world
        float tanHalf;       // tan of half the field of view, top to bottom
        float aspect;
        uint width;
        uint height;
        uint sample;         // the first sample this pass adds
        uint samples;        // how many this pass adds
        uint lights;
        uint bounces;
        float4 background;   // the ground behind, in light (a = 0: clear)
    };

    struct TraceLight {
        float4 at;     // a point's place (w 1), or the way towards a sun (w 0)
        float4 color;  // colour × strength; w: a point's radius, or a sun's angle
    };

    uint hashed(uint x) {
        x ^= x >> 16; x *= 0x7feb352d;
        x ^= x >> 15; x *= 0x846ca68b;
        x ^= x >> 16;
        return x;
    }

    struct Random {
        uint state;
        float next() {
            state = hashed(state + 0x9e3779b9);
            return float(state >> 8) * (1.0 / 16777216.0);
        }
    };

    // A frame about `n`: two axes across it.
    void across(float3 n, thread float3 &t, thread float3 &b) {
        float3 up = abs(n.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
        t = normalize(cross(up, n));
        b = cross(n, t);
    }

    float3 cosineHemisphere(float3 n, float u1, float u2) {
        float r = sqrt(u1), phi = 6.28318530718 * u2;
        float3 t, b;
        across(n, t, b);
        return normalize(t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(0.0, 1.0 - u1)));
    }

    // A half-way vector from GGX's distribution about `n`.
    float3 ggxHalf(float3 n, float a2, float u1, float u2) {
        float phi = 6.28318530718 * u1;
        float cosT = sqrt((1.0 - u2) / (1.0 + (a2 - 1.0) * u2));
        float sinT = sqrt(max(0.0, 1.0 - cosT * cosT));
        float3 t, b;
        across(n, t, b);
        return normalize(t * (sinT * cos(phi)) + b * (sinT * sin(phi)) + n * cosT);
    }

    float ggx(float ndh, float a2) {
        float d = ndh * ndh * (a2 - 1.0) + 1.0;
        return a2 / (3.14159265 * d * d);
    }

    // How likely a sampled direction is under the mix of the two ways
    // directions are chosen: one sample, both weighed, so neither way's
    // misses blow up.
    float pdfOf(float3 n, float3 v, float3 l, float a2, float specular) {
        float ndl = max(dot(n, l), 0.0);
        float3 h = normalize(v + l);
        float ndh = max(dot(n, h), 0.0), vdh = max(dot(v, h), 1e-4);
        float diffuse = ndl / 3.14159265;
        float spec = ggx(ndh, a2) * ndh / (4.0 * vdh);
        return mix(diffuse, spec, specular);
    }

    bool blocked(float3 from, float3 dir, float far, primitive_acceleration_structure accel) {
        ray r;
        r.origin = from;
        r.direction = dir;
        r.min_distance = 1e-4;
        r.max_distance = far;
        intersector<triangle_data> shadow;
        shadow.accept_any_intersection(true);
        return shadow.intersect(r, accel).type != intersection_type::none;
    }

    kernel void trace(uint2 gid [[thread_position_in_grid]],
                      constant TraceFrame &f [[buffer(0)]],
                      primitive_acceleration_structure accel [[buffer(1)]],
                      device const float4 *normals [[buffer(2)]],
                      device const float4 *objects [[buffer(3)]],
                      device const uint *indices [[buffer(4)]],
                      device const uint *slots [[buffer(5)]],
                      constant float4 *k [[buffer(6)]],
                      constant uint *start [[buffer(7)]],
                      constant TraceLight *lights [[buffer(8)]],
                      device const float4 *places [[buffer(9)]],
                      texture2d<float, access::read_write> sum [[texture(0)]],
                      texture2d<float, access::read_write> albedoSum [[texture(1)]],
                      texture2d<float, access::read_write> guideSum [[texture(2)]],
                      texture2d<float, access::read_write> momentSum [[texture(3)]]) {
        if (gid.x >= f.width || gid.y >= f.height) return;
        // The first pass starts the sums; the rest add to them.
        bool fresh = f.sample == 0;
        float4 total = fresh ? float4(0.0) : sum.read(gid);
        // What the denoiser keeps edges by: the first surface's colour (1
        // where nothing was hit) and how many samples hit one, its normal
        // and its distance, and the light's luminance squared, for how
        // unsure the pixel is.
        float4 albedos = fresh ? float4(0.0) : albedoSum.read(gid);
        float4 guides = fresh ? float4(0.0) : guideSum.read(gid);
        float moments = fresh ? 0.0 : momentSum.read(gid).x;
        intersector<triangle_data> intersect;
        for (uint s = 0; s < f.samples; s++) {
            Random rng{hashed(gid.x * 1973u + gid.y * 9277u + (f.sample + s) * 26699u)};
            // A ray through somewhere in the pixel, so edges come out smooth.
            float2 at = (float2(gid) + float2(rng.next(), rng.next())) / float2(f.width, f.height);
            float2 ndc = float2(at.x * 2.0 - 1.0, 1.0 - at.y * 2.0);
            float3 local = normalize(float3(ndc.x * f.tanHalf * f.aspect, ndc.y * f.tanHalf, -1.0));
            ray r;
            r.origin = f.eye[3].xyz;
            r.direction = normalize((f.eye * float4(local, 0.0)).xyz);
            r.min_distance = 0.0;
            r.max_distance = 1e6;
            float3 light = float3(0.0);
            float3 through = float3(1.0);
            float covered = 1.0;
            float4 albedo = float4(1.0, 1.0, 1.0, 0.0);
            float4 guide = float4(0.0);
            for (uint bounce = 0; bounce <= f.bounces; bounce++) {
                intersection_result<triangle_data> hit = intersect.intersect(r, accel);
                if (hit.type == intersection_type::none) {
                    if (bounce == 0) {
                        light = f.background.rgb;
                        covered = f.background.a;
                    } else {
                        light += through * ROOM_LIGHT;
                    }
                    break;
                }
                uint tri = hit.primitive_id;
                uint i0 = indices[tri * 3], i1 = indices[tri * 3 + 1], i2 = indices[tri * 3 + 2];
                float2 bc = hit.triangle_barycentric_coord;
                float w0 = 1.0 - bc.x - bc.y;
                float3 p = r.origin + r.direction * hit.distance;
                // From the first corner along the two edges, so a face flat in
                // an axis keeps that coordinate exactly, as the raster does: a
                // checker's cell edge on a face mustn't flicker.
                float3 o0 = objects[i0].xyz;
                float3 obj = o0 + (objects[i1].xyz - o0) * bc.x + (objects[i2].xyz - o0) * bc.y;
                float3 geometric = normalize(cross(places[i1].xyz - places[i0].xyz, places[i2].xyz - places[i0].xyz));
                float3 n = normals[i0].xyz * w0 + normals[i1].xyz * bc.x + normals[i2].xyz * bc.y;
                n = dot(n, n) > 0.25 ? normalize(n) : geometric;
                float3 v = -r.direction;
                if (dot(geometric, v) < 0.0) geometric = -geometric;
                if (dot(n, v) < 0.0) n = -n;
                Surface surface = surfaceAt(slots[tri], obj, k, start);
                float rough = clamp(surface.rough, 0.03, 1.0);
                float a2 = pow(rough, 4.0);
                float3 lift = p + geometric * 1e-3;
                if (bounce == 0) {
                    albedo = float4(surface.base, 1.0);
                    guide = float4(n, hit.distance);
                }

                // The lights, each looked at directly, through what's between.
                for (uint i = 0; i < f.lights; i++) {
                    TraceLight one = lights[i];
                    float3 l;
                    float far;
                    float3 bright;
                    if (one.at.w > 0.5) {
                        // A point with a size: somewhere on its ball, so its
                        // shadows soften with distance.
                        float z = rng.next() * 2.0 - 1.0, phi = 6.28318530718 * rng.next();
                        float rr = sqrt(max(0.0, 1.0 - z * z));
                        float3 spot = one.at.xyz + one.color.w * float3(rr * cos(phi), rr * sin(phi), z);
                        float3 to = spot - p;
                        float d2 = max(dot(to, to), 1e-4);
                        far = sqrt(d2);
                        l = to / far;
                        bright = one.color.rgb / d2;
                    } else {
                        // A sun with a width in the sky.
                        float3 t, b;
                        across(one.at.xyz, t, b);
                        float spread = one.color.w;
                        float phi = 6.28318530718 * rng.next(), rr = spread * sqrt(rng.next());
                        l = normalize(one.at.xyz + t * (rr * cos(phi)) + b * (rr * sin(phi)));
                        far = 1e6;
                        bright = one.color.rgb;
                    }
                    if (dot(geometric, l) <= 0.0 || dot(n, l) <= 0.0) continue;
                    if (blocked(lift, l, far, accel)) continue;
                    light += through * reflected(surface.base, surface.metal, rough, n, v, l) * bright;
                }

                // On to the next bounce: off the surface diffusely or as a
                // reflection, chosen by how much each matters here.
                float3 f0 = mix(float3(0.04), surface.base, surface.metal);
                float specular = clamp(0.25 + 0.75 * max(f0.r, max(f0.g, f0.b)), 0.1, 0.9);
                specular = mix(specular, 0.5, rough * 0.5);
                float3 next;
                if (rng.next() < specular) {
                    float3 h = ggxHalf(n, a2, rng.next(), rng.next());
                    next = reflect(-v, h);
                } else {
                    next = cosineHemisphere(n, rng.next(), rng.next());
                }
                if (dot(next, geometric) <= 0.0 || dot(next, n) <= 0.0) break;
                float pdf = pdfOf(n, v, next, a2, specular);
                if (pdf < 1e-6) break;
                through *= reflected(surface.base, surface.metal, rough, n, v, next) / pdf;
                // Past three bounces, a path that carries little is ended at
                // random, and one that goes on carries the rest.
                if (bounce >= 3) {
                    float keep = clamp(max(through.r, max(through.g, through.b)), 0.05, 0.95);
                    if (rng.next() > keep) break;
                    through /= keep;
                }
                r.origin = lift;
                r.direction = next;
                r.min_distance = 0.0;
                r.max_distance = 1e6;
            }
            // A path that runs away is clipped, so one sample can't speckle.
            light = min(light, float3(20.0));
            total += float4(light * covered, covered);
            albedos += albedo;
            guides += guide;
            float l = dot(light * covered, LUMA);
            moments += l * l;
        }
        sum.write(total, gid);
        albedoSum.write(albedos, gid);
        guideSum.write(guides, gid);
        momentSum.write(float4(moments), gid);
    }

    // Light (with its coverage multiplied in) toned with the view's own
    // curve.
    float4 toned(float3 premultiplied, float alpha) {
        float3 light = alpha > 1e-4 ? premultiplied / alpha : float3(0.0);
        return float4(sqrt(light / (1.0 + light)) * alpha, alpha);
    }

    // The sum toned into a picture.
    kernel void finish(uint2 gid [[thread_position_in_grid]],
                       constant uint &count [[buffer(0)]],
                       texture2d<float, access::read> sum [[texture(0)]],
                       texture2d<float, access::write> out [[texture(1)]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float4 t = sum.read(gid) / float(max(count, 1u));
        out.write(toned(t.rgb, clamp(t.a, 0.0, 1.0)), gid);
    }

    // The denoiser, after SVGF's spatial filter (Schied et al. 2017) on one
    // frame. First the sums become what it smooths: the light each surface
    // takes in, its own colour divided out so the filter blurs light and not
    // texture, with how unsure that is (the variance of the pixel's mean);
    // and its guide, the normal and distance (-1: nothing was hit).
    kernel void prepare(uint2 gid [[thread_position_in_grid]],
                        constant uint &count [[buffer(0)]],
                        texture2d<float, access::read> sum [[texture(0)]],
                        texture2d<float, access::read> albedoSum [[texture(1)]],
                        texture2d<float, access::read> guideSum [[texture(2)]],
                        texture2d<float, access::read> momentSum [[texture(3)]],
                        texture2d<float, access::write> taken [[texture(4)]],
                        texture2d<float, access::write> guide [[texture(5)]]) {
        if (gid.x >= sum.get_width() || gid.y >= sum.get_height()) return;
        float n = float(max(count, 1u));
        float3 mean = sum.read(gid).rgb / n;
        float4 a = albedoSum.read(gid);
        float3 albedo = max(a.rgb / n, float3(1e-3));
        float lum = dot(mean, LUMA);
        float variance = max(0.0, momentSum.read(gid).x / n - lum * lum) / n;
        float al = max(dot(albedo, LUMA), 1e-3);
        taken.write(float4(mean / albedo, variance / (al * al)), gid);
        float4 g = guideSum.read(gid);
        float facing = length(g.xyz);
        if (a.w < 0.5 || facing < 1e-6) {
            guide.write(float4(0.0, 0.0, 0.0, -1.0), gid);
        } else {
            guide.write(float4(g.xyz / facing, g.w / a.w), gid);
        }
    }

    // One pass of the à-trous filter: a 5 × 5 B-spline kernel with holes
    // `step` pixels apart, each neighbour weighed by how alike it faces, how
    // near its depth is to where the surface's slope would put it, and how
    // near its light is, against how unsure this pixel's light is. Five
    // passes, 1 to 16 apart, reach 62 pixels each way for 125 reads.
    kernel void smooth(uint2 gid [[thread_position_in_grid]],
                       constant int &step [[buffer(0)]],
                       texture2d<float, access::read> taken [[texture(0)]],
                       texture2d<float, access::read> guide [[texture(1)]],
                       texture2d<float, access::write> out [[texture(2)]]) {
        int w = int(taken.get_width()), h = int(taken.get_height());
        int2 p = int2(gid);
        if (p.x >= w || p.y >= h) return;
        float4 c = taken.read(gid);
        float4 g = guide.read(gid);
        if (g.w < 0.0) {
            out.write(c, gid);
            return;
        }
        // How much depth changes a pixel across, here.
        float slope = 0.0;
        int2 sides[4] = {int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1)};
        for (int i = 0; i < 4; i++) {
            int2 q = clamp(p + sides[i], int2(0), int2(w - 1, h - 1));
            float d = guide.read(uint2(q)).w;
            if (d >= 0.0) slope = max(slope, abs(d - g.w));
        }
        // The variance blurred a little, so the test it sets isn't as noisy
        // as what it tests.
        const float k3[3] = {0.25, 0.5, 0.25};
        float variance = 0.0;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                int2 q = clamp(p + int2(dx, dy), int2(0), int2(w - 1, h - 1));
                variance += k3[dx + 1] * k3[dy + 1] * taken.read(uint2(q)).a;
            }
        }
        float tolerance = 4.0 * sqrt(max(variance, 0.0)) + 1e-5;
        float lum = dot(c.rgb, LUMA);
        const float k5[5] = {1.0 / 16.0, 1.0 / 4.0, 3.0 / 8.0, 1.0 / 4.0, 1.0 / 16.0};
        float centre = k5[2] * k5[2];
        float3 light = c.rgb * centre;
        float spread = c.a * centre * centre;
        float weight = centre;
        for (int dy = -2; dy <= 2; dy++) {
            for (int dx = -2; dx <= 2; dx++) {
                if (dx == 0 && dy == 0) continue;
                int2 q = p + int2(dx, dy) * step;
                if (q.x < 0 || q.y < 0 || q.x >= w || q.y >= h) continue;
                float4 gq = guide.read(uint2(q));
                if (gq.w < 0.0) continue;
                float4 cq = taken.read(uint2(q));
                float wn = pow(max(dot(g.xyz, gq.xyz), 0.0), 128.0);
                float reach = slope * length(float2(dx, dy)) * float(step) + 1e-3 * g.w + 1e-5;
                float wz = exp(-abs(g.w - gq.w) / reach);
                float wl = exp(-abs(lum - dot(cq.rgb, LUMA)) / tolerance);
                float k = k5[dx + 2] * k5[dy + 2] * wn * wz * wl;
                light += cq.rgb * k;
                spread += cq.a * k * k;
                weight += k;
            }
        }
        out.write(float4(light / weight, spread / (weight * weight)), gid);
    }

    // The smoothed light, each surface's colour multiplied back, toned.
    kernel void finishSmoothed(uint2 gid [[thread_position_in_grid]],
                               constant uint &count [[buffer(0)]],
                               texture2d<float, access::read> sum [[texture(0)]],
                               texture2d<float, access::read> albedoSum [[texture(1)]],
                               texture2d<float, access::read> smoothed [[texture(2)]],
                               texture2d<float, access::write> out [[texture(3)]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float n = float(max(count, 1u));
        float alpha = clamp(sum.read(gid).a / n, 0.0, 1.0);
        float3 albedo = max(albedoSum.read(gid).rgb / n, float3(1e-3));
        out.write(toned(smoothed.read(gid).rgb * albedo, alpha), gid);
    }

    """
}
