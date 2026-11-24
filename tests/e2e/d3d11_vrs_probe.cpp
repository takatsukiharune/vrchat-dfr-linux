// SPDX-License-Identifier: MIT
// Offscreen D3D11 probe for the DXVK gaze-VRS patch. Draws a per-pixel hash
// into a side-by-side RGBA16F eye target and reports, per 8x8 tile, how
// coarsely it was shaded: '0' = every pixel, 'h' = 2x1 or 1x2, '1' = 2x2,
// '2' = 4x4 or coarser. With a sixth argument "bench" it draws an expensive
// pixel shader instead and reports the time per frame.
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

static const char* shader = R"(
float4 vs(uint id : SV_VertexID) : SV_Position {
  // Clockwise, so the default back-face culling keeps it.
  return float4(float(id & 2) * 2.0 - 1.0, float((id << 1) & 2) * 2.0 - 1.0, 0.5, 1.0);
}
float4 ps(float4 pos : SV_Position) : SV_Target {
  float2 p = floor(pos.xy);
  return float4(frac(p.x * 0.0173 + p.y * 0.2931), 0.0, 0.0, 1.0);
}
float4 ps_bench(float4 pos : SV_Position) : SV_Target {
  float a = 0.0;
  for (int i = 1; i <= 256; i++) a += sin(pos.x * 0.011 * i + a) * cos(pos.y * 0.013 * i);
  return float4(frac(a), 0.0, 0.0, 1.0);
}
)";

#define CHECK(call) do { HRESULT hr_ = (call); if (FAILED(hr_)) { \
  std::fprintf(stderr, "%s failed: 0x%08lx\n", #call, static_cast<unsigned long>(hr_)); return 1; } } while (0)

int main(int argc, char** argv) {
  if (argc < 5) { std::fprintf(stderr, "Usage: probe WIDTH HEIGHT SECONDS OUTPUT [SAMPLES [bench]]\n"); return 2; }
  const UINT width = std::atoi(argv[1]), height = std::atoi(argv[2]);
  const double seconds = std::atof(argv[3]);
  const std::string output = argv[4];
  const UINT samples = argc > 5 ? std::atoi(argv[5]) : 1;
  const std::string mode = argc > 6 ? argv[6] : "";
  const bool bench = mode == "bench";
  const bool multipass = mode == "multipass";

  ID3D11Device* device = nullptr;
  ID3D11DeviceContext* context = nullptr;
  D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  CHECK(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &level, 1,
    D3D11_SDK_VERSION, &device, nullptr, &context));

  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = width; desc.Height = height; desc.MipLevels = 1; desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
  desc.SampleDesc.Count = samples;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  ID3D11Texture2D *target = nullptr, *resolved = nullptr, *staging = nullptr;
  CHECK(device->CreateTexture2D(&desc, nullptr, &target));
  desc.SampleDesc.Count = 1;
  CHECK(device->CreateTexture2D(&desc, nullptr, &resolved));
  desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = 0; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  CHECK(device->CreateTexture2D(&desc, nullptr, &staging));
  ID3D11RenderTargetView* rtv = nullptr;
  CHECK(device->CreateRenderTargetView(target, nullptr, &rtv));

  // In multipass mode, render two more candidate passes per frame: a 1x
  // full-size pass and a 1x 1536x768 pass. A second D3D11 device also draws
  // a 256x256 non-candidate pass.
  ID3D11RenderTargetView *postRtv = nullptr, *smallRtv = nullptr;
  ID3D11Device* auxDevice = nullptr;
  ID3D11DeviceContext* auxContext = nullptr;
  ID3D11RenderTargetView* auxRtv = nullptr;
  ID3D11VertexShader* auxVs = nullptr;
  ID3D11PixelShader* auxPs = nullptr;
  const UINT smallW = 1536, smallH = 768;
  if (multipass) {
    CHECK(device->CreateRenderTargetView(resolved, nullptr, &postRtv));
    D3D11_TEXTURE2D_DESC smallDesc = {};
    smallDesc.Width = smallW; smallDesc.Height = smallH; smallDesc.MipLevels = 1; smallDesc.ArraySize = 1;
    smallDesc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
    smallDesc.SampleDesc.Count = 1;
    smallDesc.Usage = D3D11_USAGE_DEFAULT;
    smallDesc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D* smallTex = nullptr;
    CHECK(device->CreateTexture2D(&smallDesc, nullptr, &smallTex));
    CHECK(device->CreateRenderTargetView(smallTex, nullptr, &smallRtv));

    CHECK(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &level, 1,
      D3D11_SDK_VERSION, &auxDevice, nullptr, &auxContext));
    D3D11_TEXTURE2D_DESC auxDesc = smallDesc;
    auxDesc.Width = 256; auxDesc.Height = 256;
    auxDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    ID3D11Texture2D* auxTex = nullptr;
    CHECK(auxDevice->CreateTexture2D(&auxDesc, nullptr, &auxTex));
    CHECK(auxDevice->CreateRenderTargetView(auxTex, nullptr, &auxRtv));
  }

  ID3DBlob *vsBlob = nullptr, *psBlob = nullptr, *errors = nullptr;
  if (FAILED(D3DCompile(shader, strlen(shader), "probe", nullptr, nullptr, "vs", "vs_5_0", 0, 0, &vsBlob, &errors))
   || FAILED(D3DCompile(shader, strlen(shader), "probe", nullptr, nullptr, bench ? "ps_bench" : "ps", "ps_5_0", 0, 0, &psBlob, &errors))) {
    std::fprintf(stderr, "Shader compile failed: %s\n", errors ? static_cast<const char*>(errors->GetBufferPointer()) : "?");
    return 1;
  }
  ID3D11VertexShader* vs = nullptr;
  ID3D11PixelShader* ps = nullptr;
  CHECK(device->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, &vs));
  CHECK(device->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, &ps));
  if (multipass) {
    CHECK(auxDevice->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, &auxVs));
    CHECK(auxDevice->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, &auxPs));
  }

  const D3D11_VIEWPORT viewport = {0, 0, float(width), float(height), 0, 1};
  const float clear[4] = {0, 0, 0, 1};
  const UINT tilesX = width / 8, tilesY = height / 8;
  std::string grid;
  std::vector<uint16_t> values(64);
  DWORD start = GetTickCount();

  if (bench) {
    // Reading one pixel back after each frame waits for the GPU, so the wall
    // time per frame is the GPU time of the pass.
    desc.Width = desc.Height = 1;
    ID3D11Texture2D* pixel = nullptr;
    CHECK(device->CreateTexture2D(&desc, nullptr, &pixel));
    const D3D11_BOX box = {0, 0, 0, 1, 1, 1};
    unsigned frames = 0;
    const double warmup = 3.0;
    for (bool measuring = false;; ++frames) {
      const double elapsed = (GetTickCount() - start) / 1000.0;
      if (!measuring && elapsed >= warmup) { measuring = true; frames = 0; start = GetTickCount(); }
      else if (measuring && elapsed >= seconds) break;
      context->OMSetRenderTargets(1, &rtv, nullptr);
      context->RSSetViewports(1, &viewport);
      context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
      context->VSSetShader(vs, nullptr, 0);
      context->PSSetShader(ps, nullptr, 0);
      context->Draw(3, 0);
      context->OMSetRenderTargets(0, nullptr, nullptr);
      if (samples > 1) context->ResolveSubresource(resolved, 0, target, 0, desc.Format);
      context->CopySubresourceRegion(pixel, 0, 0, 0, 0, samples > 1 ? resolved : target, 0, &box);
      D3D11_MAPPED_SUBRESOURCE mapped = {};
      CHECK(context->Map(pixel, 0, D3D11_MAP_READ, 0, &mapped));
      context->Unmap(pixel, 0);
    }
    if (FILE* file = std::fopen(output.c_str(), "wb")) {
      std::fprintf(file, "%u %.4f\n", frames, (GetTickCount() - start) / double(frames));
      std::fclose(file);
    }
    return 0;
  }

  for (unsigned frame = 1; (GetTickCount() - start) / 1000.0 < seconds; ++frame) {
    context->OMSetRenderTargets(1, &rtv, nullptr);
    context->RSSetViewports(1, &viewport);
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->VSSetShader(vs, nullptr, 0);
    context->PSSetShader(ps, nullptr, 0);
    context->ClearRenderTargetView(rtv, clear);
    context->Draw(3, 0);
    context->OMSetRenderTargets(0, nullptr, nullptr);
    if (multipass) {
      // Draw a 1x pass at the same size as the main pass.
      context->OMSetRenderTargets(1, &postRtv, nullptr);
      context->RSSetViewports(1, &viewport);
      context->ClearRenderTargetView(postRtv, clear);
      context->Draw(3, 0);
      // Draw a smaller 1x side-by-side pass.
      const D3D11_VIEWPORT smallVp = {0, 0, float(smallW), float(smallH), 0, 1};
      context->OMSetRenderTargets(1, &smallRtv, nullptr);
      context->RSSetViewports(1, &smallVp);
      context->ClearRenderTargetView(smallRtv, clear);
      context->Draw(3, 0);
      context->OMSetRenderTargets(0, nullptr, nullptr);
      // Draw a small non-candidate pass on a separate D3D11 device.
      const D3D11_VIEWPORT auxVp = {0, 0, 256.0f, 256.0f, 0, 1};
      auxContext->OMSetRenderTargets(1, &auxRtv, nullptr);
      auxContext->RSSetViewports(1, &auxVp);
      auxContext->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
      auxContext->VSSetShader(auxVs, nullptr, 0);
      auxContext->PSSetShader(auxPs, nullptr, 0);
      auxContext->ClearRenderTargetView(auxRtv, clear);
      auxContext->Draw(3, 0);
      auxContext->OMSetRenderTargets(0, nullptr, nullptr);
      auxContext->Flush();
    }
    if (frame % 8) { context->Flush(); Sleep(5); continue; }

    if (samples > 1) {
      context->ResolveSubresource(resolved, 0, target, 0, desc.Format);
      context->CopyResource(staging, resolved);
    } else {
      context->CopyResource(staging, target);
    }
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    CHECK(context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped));
    grid.clear();
    for (UINT ty = 0; ty < tilesY; ++ty) {
      for (UINT tx = 0; tx < tilesX; ++tx) {
        for (UINT y = 0; y < 8; ++y) {
          auto row = reinterpret_cast<const uint16_t*>(
            static_cast<const uint8_t*>(mapped.pData) + size_t(ty * 8 + y) * mapped.RowPitch) + size_t(tx) * 8 * 4;
          for (UINT x = 0; x < 8; ++x) values[y * 8 + x] = row[x * 4];
        }
        std::sort(values.begin(), values.end());
        const auto distinct = std::unique(values.begin(), values.end()) - values.begin();
        grid += distinct > 32 ? '0' : distinct > 16 ? 'h' : distinct > 4 ? '1' : '2';
      }
      grid += '\n';
    }
    context->Unmap(staging, 0);
    const std::string temporary = output + ".tmp";
    if (FILE* file = std::fopen(temporary.c_str(), "wb")) {
      std::fprintf(file, "%u %u %u\n", frame, tilesX, tilesY);
      std::fwrite(grid.data(), 1, grid.size(), file);
      std::fclose(file);
      MoveFileExA(temporary.c_str(), output.c_str(), MOVEFILE_REPLACE_EXISTING);
    }
  }
  std::printf("probe finished\n");
  return 0;
}
