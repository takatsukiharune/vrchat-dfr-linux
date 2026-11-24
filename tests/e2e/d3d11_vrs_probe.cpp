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
  const bool nodepth = mode == "nodepth";
  const bool fullvp = mode == "fullvp";
  const bool overlay = mode == "overlay";

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

  D3D11_TEXTURE2D_DESC depthDesc = {};
  depthDesc.Width = width; depthDesc.Height = height; depthDesc.MipLevels = 1; depthDesc.ArraySize = 1;
  depthDesc.Format = DXGI_FORMAT_D32_FLOAT;
  depthDesc.SampleDesc.Count = samples;
  depthDesc.Usage = D3D11_USAGE_DEFAULT;
  depthDesc.BindFlags = D3D11_BIND_DEPTH_STENCIL;
  ID3D11Texture2D* depthTex = nullptr;
  ID3D11DepthStencilView* dsv = nullptr;
  CHECK(device->CreateTexture2D(&depthDesc, nullptr, &depthTex));
  CHECK(device->CreateDepthStencilView(depthTex, nullptr, &dsv));

  D3D11_DEPTH_STENCIL_DESC dssOnDesc = {};
  dssOnDesc.DepthEnable = TRUE;
  dssOnDesc.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ALL;
  dssOnDesc.DepthFunc = D3D11_COMPARISON_ALWAYS;
  ID3D11DepthStencilState* dssOn = nullptr;
  CHECK(device->CreateDepthStencilState(&dssOnDesc, &dssOn));

  D3D11_DEPTH_STENCIL_DESC dssOffDesc = {};
  dssOffDesc.DepthEnable = FALSE;
  dssOffDesc.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ZERO;
  dssOffDesc.DepthFunc = D3D11_COMPARISON_ALWAYS;
  ID3D11DepthStencilState* dssOff = nullptr;
  CHECK(device->CreateDepthStencilState(&dssOffDesc, &dssOff));

  // In multipass mode, render two more candidate passes per frame: a 1x
  // full-size pass and a 1x 1536x768 pass. A second D3D11 device also draws
  // a 256x256 non-candidate pass.
  ID3D11RenderTargetView *postRtv = nullptr, *smallRtv = nullptr;
  ID3D11DepthStencilView *postDsv = nullptr, *smallDsv = nullptr;
  ID3D11Device* auxDevice = nullptr;
  ID3D11DeviceContext* auxContext = nullptr;
  ID3D11RenderTargetView* auxRtv = nullptr;
  ID3D11VertexShader* auxVs = nullptr;
  ID3D11PixelShader* auxPs = nullptr;
  const UINT smallW = 1536, smallH = 768;
  if (multipass) {
    CHECK(device->CreateRenderTargetView(resolved, nullptr, &postRtv));
    D3D11_TEXTURE2D_DESC postDepthDesc = depthDesc;
    postDepthDesc.SampleDesc.Count = 1;
    ID3D11Texture2D* postDepthTex = nullptr;
    CHECK(device->CreateTexture2D(&postDepthDesc, nullptr, &postDepthTex));
    CHECK(device->CreateDepthStencilView(postDepthTex, nullptr, &postDsv));

    D3D11_TEXTURE2D_DESC smallDesc = {};
    smallDesc.Width = smallW; smallDesc.Height = smallH; smallDesc.MipLevels = 1; smallDesc.ArraySize = 1;
    smallDesc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
    smallDesc.SampleDesc.Count = 1;
    smallDesc.Usage = D3D11_USAGE_DEFAULT;
    smallDesc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D* smallTex = nullptr;
    CHECK(device->CreateTexture2D(&smallDesc, nullptr, &smallTex));
    CHECK(device->CreateRenderTargetView(smallTex, nullptr, &smallRtv));
    D3D11_TEXTURE2D_DESC smallDepthDesc = postDepthDesc;
    smallDepthDesc.Width = smallW; smallDepthDesc.Height = smallH;
    ID3D11Texture2D* smallDepthTex = nullptr;
    CHECK(device->CreateTexture2D(&smallDepthDesc, nullptr, &smallDepthTex));
    CHECK(device->CreateDepthStencilView(smallDepthTex, nullptr, &smallDsv));

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

  const D3D11_VIEWPORT vpLeft = {0, 0, float(width) * 0.5f, float(height), 0, 1};
  const D3D11_VIEWPORT vpRight = {float(width) * 0.5f, 0, float(width) * 0.5f, float(height), 0, 1};
  const D3D11_VIEWPORT vpOverlayL = {0, 0, float(width) * 0.5f, float(height) * 0.25f, 0, 1};
  const D3D11_VIEWPORT vpOverlayR = {float(width) * 0.5f, 0, float(width) * 0.5f, float(height) * 0.25f, 0, 1};
  const float clear[4] = {0, 0, 0, 1};
  const UINT tilesX = width / 8, tilesY = height / 8;
  std::string grid;
  std::vector<uint16_t> values(64);
  DWORD start = GetTickCount();

  auto drawStereo = [&](ID3D11RenderTargetView* targetRtv, ID3D11DepthStencilView* targetDsv, UINT w, UINT h, bool useFullVp) {
    context->OMSetRenderTargets(1, &targetRtv, targetDsv);
    context->OMSetDepthStencilState(targetDsv ? dssOn : dssOff, 0);
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->VSSetShader(vs, nullptr, 0);
    context->PSSetShader(ps, nullptr, 0);
    context->ClearRenderTargetView(targetRtv, clear);
    if (targetDsv) context->ClearDepthStencilView(targetDsv, D3D11_CLEAR_DEPTH, 1.0f, 0);
    if (useFullVp) {
      const D3D11_VIEWPORT full = {0, 0, float(w), float(h), 0, 1};
      context->RSSetViewports(1, &full);
      context->Draw(3, 0);
    } else {
      const D3D11_VIEWPORT left = {0, 0, float(w) * 0.5f, float(h), 0, 1};
      const D3D11_VIEWPORT right = {float(w) * 0.5f, 0, float(w) * 0.5f, float(h), 0, 1};
      context->RSSetViewports(1, &left);
      context->Draw(3, 0);
      context->RSSetViewports(1, &right);
      context->Draw(3, 0);
    }
  };

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
      context->OMSetRenderTargets(1, &rtv, dsv);
      context->OMSetDepthStencilState(dssOn, 0);
      context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
      context->VSSetShader(vs, nullptr, 0);
      context->PSSetShader(ps, nullptr, 0);
      context->RSSetViewports(1, &vpLeft);
      context->Draw(3, 0);
      context->RSSetViewports(1, &vpRight);
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
    drawStereo(rtv, nodepth ? nullptr : dsv, width, height, fullvp);
    if (overlay) {
      // Draw a 2D UI strip in the top 25% of the same pass with depth disabled.
      context->OMSetDepthStencilState(dssOff, 0);
      context->RSSetViewports(1, &vpOverlayL);
      context->Draw(3, 0);
      context->RSSetViewports(1, &vpOverlayR);
      context->Draw(3, 0);
    }
    context->OMSetRenderTargets(0, nullptr, nullptr);
    if (multipass) {
      // Draw a 1x pass at the same size as the main pass.
      drawStereo(postRtv, postDsv, width, height, false);
      // Draw a smaller 1x side-by-side pass.
      drawStereo(smallRtv, smallDsv, smallW, smallH, false);
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
