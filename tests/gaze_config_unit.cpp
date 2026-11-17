// SPDX-License-Identifier: MIT
#include "dxvk_gaze_config.h"
#include <cassert>
#include <cstdio>
#include <fstream>
#include <map>
#include <unistd.h>

using namespace dxvk;

static void write(const std::string& path, const std::string& text) {
  std::ofstream(path, std::ios::binary | std::ios::trunc) << text;
}

int main() {
  // Environment: valid values apply, bad ones are reported and ignored.
  std::map<std::string, std::string> env = {
    {"DXVK_GAZE_FULL_AREA", "45"}, {"DXVK_GAZE_MID_AREA", "65"}, {"DXVK_GAZE_COARSE", "auto"},
    {"DXVK_GAZE_FMT", "97"}, {"DXVK_GAZE_FLIP_Y", "1"}, {"DXVK_GAZE_GAIN_Y", "abc"},
    {"DXVK_GAZE_SIZE", "4128x2208"}, {"DXVK_GAZE_FAKE", "circle"}};
  std::vector<std::string> errors;
  GazeConfig base = gazeConfigFromEnv([&](const char* name) { return env[name]; }, errors);
  assert(base.fullArea == 45.f && base.midArea == 65.f && base.autoCoarse && base.onlyFormat == 97);
  assert(base.flipY && base.gainY == 1.f && base.forceW == 4128 && base.forceH == 2208);
  assert(base.fake == GazeFake::Circle && base.enabled && base.holdMs == 500);
  assert(errors.size() == 1 && errors[0].find("DXVK_GAZE_GAIN_Y") != std::string::npos);

  // MAXRATE is the old name; COARSE wins when both are present.
  env = {{"DXVK_GAZE_MAXRATE", "10"}, {"DXVK_GAZE_COARSE", "6"}};
  errors.clear();
  assert(gazeConfigFromEnv([&](const char* name) { return env[name]; }, errors).coarse == 6);

  // Keys: any spelling of the name, and every value form.
  GazeConfig c;
  assert(c.set("DXVK_GAZE_FULL_AREA", " 30 ") && c.fullArea == 30.f);
  assert(c.set("Mid-Area", "50") && c.midArea == 50.f);
  assert(c.set("coarse", "4x4") && c.coarse == 10 && !c.autoCoarse);
  assert(c.set("coarse", "2x4") && c.coarse == 6);
  assert(c.set("coarse", "auto") && c.autoCoarse);
  assert(c.set("coarse", "5") && c.coarse == 5 && !c.autoCoarse);
  assert(c.mid == 5 && c.set("mid", "2x1") && c.mid == 4 && c.set("mid", "1") && c.mid == 1);
  assert(!c.set("mid", "auto") && !c.set("mid", "3x3") && c.mid == 1);
  assert(c.set("enabled", "off") && !c.enabled && c.set("vrs", "1") && c.enabled);
  assert(c.set("flipx_l", "1") && c.forceFlipX[0] == 1 && c.set("flipx_l", "auto") && c.forceFlipX[0] == -1);
  assert(c.set("fallback", "center") && c.fallback == GazeFallback::Center);
  assert(c.set("size", "0") && c.forceW == 0 && c.set("fake", "none") && c.fake == GazeFake::None);
  assert(c.set("file", "anything") && c.set("config", "anything"));

  // Rejected values never change anything.
  const GazeConfig before = c;
  for (auto bad : {"3", "7", "12", "16", "-1", "8x8", "3x3", "2x", "fast", "nan", "5.5", ""})
    assert(!c.set("coarse", bad));
  for (auto bad : {"101", "-2", "inf", "nan", "1e999", "30%", ""})
    assert(!c.set("full_area", bad));
  assert(!c.set("hold_ms", "-1") && !c.set("hold_ms", "99999") && !c.set("enabled", "2"));
  assert(!c.set("dot_radius", "0") && !c.set("fake", "square") && !c.set("size", "12"));
  assert(!c.set("no_such_key", "1") && !c.set("", "1"));
  assert(c == before);

  // Zones stay nested however they were given.
  GazeConfig nested;
  nested.set("full_area", "60");
  nested.set("mid_area", "40");
  nested.sanitize();
  assert(nested.midArea == 60.f);
  GazeConfig radii;
  radii.set("r1", "0.3");
  radii.set("r2", "0.1");
  radii.sanitize();
  assert(radii.r2 == 0.3f);

  // Text: comments, quotes, blank lines, CRLF, env-style names.
  GazeConfig parsed = base;
  errors.clear();
  assert(parseGazeConfigText("# tuning\r\n\r\nfull_area = 20  # sharp\r\nDXVK_GAZE_MID_AREA=\"35\"\n"
    "coarse='2x2'\nhold_ms=250", parsed, errors));
  assert(parsed.fullArea == 20.f && parsed.midArea == 35.f && parsed.coarse == 5 && parsed.holdMs == 250);
  assert(parsed.onlyFormat == 97 && parsed.flipY);
  // One bad line rejects the whole text and names the line.
  GazeConfig untouched = parsed;
  assert(!parseGazeConfigText("full_area=10\nmid_area\nbogus=1\n", parsed, errors));
  assert(parsed == untouched && errors.size() == 2 && errors[0].find("line 2") != std::string::npos);

  // File: missing -> base, valid -> override, broken -> previous, removed -> base.
  const std::string path = "/tmp/gaze-config-unit-" + std::to_string(getpid());
  std::remove(path.c_str());
  GazeConfigFile file(path, base);
  std::vector<std::string> messages;
  assert(!file.reload(messages) && file.config() == base && messages.size() == 1);
  messages.clear();
  assert(!file.reload(messages) && messages.empty());
  write(path, "full_area=12\n");
  assert(file.reload(messages) && file.config().fullArea == 12.f && file.config().midArea == 65.f);
  assert(!file.reload(messages));
  write(path, "full_area=12\n# only a comment changed\n");
  assert(!file.reload(messages) && messages.empty());
  write(path, "full_area=twelve\n");
  assert(!file.reload(messages) && file.config().fullArea == 12.f && messages.size() == 2);
  messages.clear();
  assert(!file.reload(messages) && messages.empty());
  write(path, "full_area=13\nenabled=0\n");
  assert(file.reload(messages) && file.config().fullArea == 13.f && !file.config().enabled);
  std::remove(path.c_str());
  assert(file.reload(messages) && file.config() == base);
  // No path configured: never changes, never reports.
  GazeConfigFile none("", base);
  messages.clear();
  assert(!none.reload(messages) && messages.empty() && none.config() == base);

  assert(!base.describe().empty());
  std::puts("Gaze config tests passed");
}
