#include <metal_stdlib>
using namespace metal;

// One instanced-quad pipeline draws every waveform element: bars, loop region, grid lines, handles and
// the playhead. Shapes are signed-distance rounded rectangles, so edges are anti-aliased at any scale.
// Geometry is rebuilt on the CPU only when the data changes; the playhead and the played/unplayed split
// are uniforms, so a frame while playing costs two draw calls.

struct Rect {
    float4 frame;    // x, y, width, height in points (top-left origin)
    float4 colorA;   // premultiplied-alpha RGBA (unplayed / base colour)
    float4 colorB;   // premultiplied-alpha RGBA (played colour, used when params.y > 0)
    float4 params;   // x: corner radius, y: 1 = colour follows the playhead, z: glow padding (points), w: glow strength
};

struct Uniforms {
    float2 viewSize;     // points
    float playheadX;     // points
    float scale;         // pixels per point
};

struct VOut {
    float4 position [[position]];
    float2 local;        // point offset from the rect centre
    float2 halfSize;
    float4 colorA;
    float4 colorB;
    float4 params;
    float centerX;
};

vertex VOut rectVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                       constant Rect *rects [[buffer(0)]],
                       constant Uniforms &u [[buffer(1)]]) {
    Rect r = rects[iid];
    const float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    float2 c = corners[vid];
    float pad = r.params.z;
    float2 size = r.frame.zw + 2.0 * pad;
    float2 p = r.frame.xy - pad + c * size;
    VOut o;
    o.position = float4(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0, 0.0, 1.0);
    o.local = c * size - pad - r.frame.zw * 0.5;
    o.halfSize = r.frame.zw * 0.5;
    o.colorA = r.colorA;
    o.colorB = r.colorB;
    o.params = r.params;
    o.centerX = r.frame.x + r.frame.z * 0.5;
    return o;
}

fragment float4 rectFragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float radius = min(in.params.x, min(in.halfSize.x, in.halfSize.y));
    float2 q = abs(in.local) - (in.halfSize - radius);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float aa = 1.0 / u.scale;
    float coverage = 1.0 - smoothstep(-0.5 * aa, 0.5 * aa, d);

    float4 colour = in.colorA;
    if (in.params.y > 0.5) {
        float played = 1.0 - smoothstep(u.playheadX - 1.0, u.playheadX + 1.0, in.centerX);
        colour = mix(in.colorA, in.colorB, played);
    }
    float4 result = colour * coverage;
    if (in.params.z > 0.0 && in.params.w > 0.0) {
        // Soft glow around the shape (the playhead and the lifted loop handles).
        float sigma = max(in.params.z * 0.45, 0.001);
        float g = exp(-pow(max(d, 0.0), 2.0) / (2.0 * sigma * sigma)) * in.params.w;
        float4 glow = in.colorB * g;
        result = result + glow * (1.0 - result.a);
    }
    return result;
}
