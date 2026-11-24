// VIctory plane compositor: the console's display composes a title's planes (the game's scene,
// with its interface plane over it). Drawn as one fullscreen triangle into the swap chain's
// back buffer. Compiled ahead of time (dxc, see Apply-PlaneCompositor.ps1) to DXIL with the
// root signature embedded.
#define RS "DescriptorTable(SRV(t0, numDescriptors = 2), visibility = SHADER_VISIBILITY_PIXEL), " \
           "StaticSampler(s0, filter = FILTER_MIN_MAG_MIP_LINEAR, addressU = TEXTURE_ADDRESS_CLAMP, " \
           "addressV = TEXTURE_ADDRESS_CLAMP, visibility = SHADER_VISIBILITY_PIXEL)"

Texture2D<float4> scene : register(t0);
Texture2D<float4> overlay : register(t1);
SamplerState linear_clamp : register(s0);

struct Varyings {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

[RootSignature(RS)]
Varyings vs(uint id : SV_VertexID) {
    Varyings o;
    o.uv = float2((id << 1) & 2, id & 2);
    o.position = float4(o.uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}

// Premultiplied-alpha "over": the interface plane on top of the scene.
[RootSignature(RS)]
float4 ps(Varyings i) : SV_Target {
    float4 s = scene.Sample(linear_clamp, i.uv);
    float4 o = overlay.Sample(linear_clamp, i.uv);
    return float4(o.rgb + s.rgb * (1 - o.a), 1);
}
