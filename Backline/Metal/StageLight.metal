#include <metal_stdlib>
using namespace metal;

// The Stage light (design plan 2.8): one soft lamp per part just above the top edge, coloured like the part
// and as bright as it is loud, plus a floor glow behind the Deck that follows the master level, under 1 pt
// film grain. One full-screen triangle, one pass, at 1 pixel per point.

struct StageUniforms {
    float2 size;        // drawable size, pixels
    float time;         // seconds, for the grain
    float floorGlow;    // floor glow intensity
    float4 floorColor;  // rgb, straight alpha
    uint lampCount;
    float grain;        // grain amplitude (0.025)
    float2 pad;
};

struct Lamp {
    float4 geom;        // centre x, y and radius x, y, as fractions of the view (y down)
    float4 color;       // rgb, and intensity in .a
};

struct StageOut {
    float4 position [[position]];
};

vertex StageOut stageVertex(uint vid [[vertex_id]]) {
    // A triangle that covers the whole view: (-1, -1), (3, -1), (-1, 3).
    float2 p = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;
    StageOut o;
    o.position = float4(p, 0.0, 1.0);
    return o;
}

static float grainHash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

fragment float4 stageFragment(StageOut in [[stage_in]],
                              constant StageUniforms &u [[buffer(0)]],
                              constant Lamp *lamps [[buffer(1)]]) {
    float2 uv = in.position.xy / u.size;
    float3 light = float3(0.0);
    float amount = 0.0;
    for (uint i = 0; i < u.lampCount; ++i) {
        float2 d = (uv - lamps[i].geom.xy) / lamps[i].geom.zw;
        float w = lamps[i].color.a * exp(-2.2 * dot(d, d));
        light += lamps[i].color.rgb * w;
        amount += w;
    }
    // Floor glow: wide and low behind the Deck.
    float2 f = (uv - float2(0.5, 1.05)) / float2(0.75, 0.3);
    float fw = u.floorGlow * exp(-2.0 * dot(f, f));
    light += u.floorColor.rgb * fw;
    amount += fw;
    // Film grain: 1 pixel (= 1 pt here), a new pattern 24 times a second.
    float n = grainHash(floor(in.position.xy) + floor(u.time * 24.0) * float2(17.0, 59.0)) * 2.0 - 1.0;
    float g = 1.0 + u.grain * n;
    amount = saturate(amount * g);
    light = min(light * g, float3(amount));      // premultiplied: colour never above coverage
    return float4(light, amount);
}
