struct VertexOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

VertexOutput vertexMain(uint index : SV_VertexID) {
    const float2 positions[4] = {float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)};
    VertexOutput output;
    output.position = float4(positions[index], 0, 1);
    output.uv = positions[index] * 0.5 + 0.5;
    return output;
}

float4 fragmentMain(VertexOutput input) : SV_Target0 {
    return float4(input.uv, 0.5, 1);
}
