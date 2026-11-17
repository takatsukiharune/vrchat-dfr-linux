// SPDX-License-Identifier: MIT
// Edits the gaze-VRS config file that patched DXVK re-reads while the game
// runs, and reports what DXVK and the gaze bridge are doing. Values are
// checked with the same parser DXVK uses, so a bad edit is refused here.
#include "../shared/gaze_config.h"
#include "../shared/gaze_shm.h"

#include <cerrno>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <sstream>
#include <sys/mman.h>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>

namespace {
using dxvk::GazeConfig;

const char* const usage =
  "Usage: dfrctl [--config PATH] [--gaze-file PATH] COMMAND\n"
  "  show                     print the config file and the live status\n"
  "  set KEY VALUE [...]      change settings (KEY=VALUE also works); applies within ~0.3 s\n"
  "  unset KEY [...]          drop settings, back to the DXVK_GAZE_* launch option values\n"
  "  on | off                 enable or disable foveation without restarting the game\n"
  "  reset                    delete the config file\n"
  "  status [--watch]         what DXVK and the gaze bridge are doing right now\n"
  "  keys                     list the settings\n"
  "  launch-options           print the Steam launch options that use this config file\n"
  "Config: $DFR_CONFIG, else ~/.config/vrchat-dfr/dfr.conf. Gaze file: $DFR_GAZE_FILE,\n"
  "else /dev/shm/vrchat_dfr_gaze.\n";

const char* const keys =
  "enabled      0|1          foveation on/off\n"
  "full_area    0..100       % of one eye's image shaded at full rate\n"
  "mid_area     0..100       % shaded at full rate or at 'mid'; the rest uses 'coarse'\n"
  "r1, r2       0..10        zone radii, used only when the areas are unset (-1)\n"
  "coarse       auto|1x1|2x1|1x2|2x2|2x4|4x2|4x4   outer rate, clamped to what the GPU supports\n"
  "mid          auto|1x1|2x1|1x2|2x2   rate of the mid_area ring, never coarser than 'coarse'\n"
  "                         (auto, the default: 2x2, or 'coarse' where that is finer)\n"
  "hold_ms      0..10000     keep the last gaze this long when tracking drops (blinks)\n"
  "fallback     off|center   after hold_ms: full rate, or foveate around the eye centre\n"
  "fmt          Vulkan format number of the scene pass (VRChat: 97), 0 = any\n"
  "samples      MSAA sample count of the scene pass, 0 = any\n"
  "minsize      smallest eye-pass height considered\n"
  "size         WxH          only this pass size, 0 = automatic\n"
  "flip_y, swap_eyes  0|1    gaze orientation\n"
  "flipx_l, flipx_r, flipy_l, flipy_r  0|1|auto   per-eye flips\n"
  "gain_y       0..10        scale vertical gaze offset around the centre\n"
  "dot          0|1          draw the gaze position (side-by-side passes)\n"
  "dot_radius   1..512\n"
  "debug        0|1          per-second diagnostics in the DXVK log\n"
  "fake         none|x|y|circle|fixed|grid   synthetic gaze for testing\n"
  "fixed_y      0..1         gaze height for fake=fixed\n";

[[noreturn]] void fail(const std::string& message) {
  std::cerr << "dfrctl: " << message << "\n";
  std::exit(1);
}

std::string defaultConfig() {
  if (const char* path = std::getenv("DFR_CONFIG"); path && *path) return path;
  if (const char* xdg = std::getenv("XDG_CONFIG_HOME"); xdg && *xdg) return std::string(xdg) + "/vrchat-dfr/dfr.conf";
  const char* home = std::getenv("HOME");
  if (!home || !*home) fail("HOME is not set; use --config PATH");
  return std::string(home) + "/.config/vrchat-dfr/dfr.conf";
}

bool readFile(const std::string& path, std::string& text) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return false;
  std::ostringstream buffer;
  buffer << in.rdbuf();
  text = buffer.str();
  return true;
}

std::vector<std::string> lines(const std::string& text) {
  std::vector<std::string> result;
  std::istringstream in(text);
  for (std::string line; std::getline(in, line);) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    result.push_back(line);
  }
  return result;
}

// Key of a "key = value" line, or empty for comments and blank lines.
std::string lineKey(std::string line) {
  if (auto comment = line.find('#'); comment != std::string::npos) line.erase(comment);
  auto eq = line.find('=');
  return eq == std::string::npos ? "" : GazeConfig::normalizeKey(line.substr(0, eq));
}

void makeParents(const std::string& path) {
  for (size_t slash = path.find('/', 1); slash != std::string::npos; slash = path.find('/', slash + 1)) {
    const std::string parent = path.substr(0, slash);
    if (mkdir(parent.c_str(), 0755) && errno != EEXIST) fail("cannot create " + parent + ": " + std::strerror(errno));
  }
}

// DXVK reads the file by content at any moment: replace it in one step.
void writeFile(const std::string& path, const std::vector<std::string>& content) {
  std::string text;
  for (const auto& line : content) text += line + "\n";
  GazeConfig check;
  std::vector<std::string> errors;
  if (!dxvk::parseGazeConfigText(text, check, errors)) {
    for (const auto& e : errors) std::cerr << "dfrctl: " << e << "\n";
    fail("not written: fix the lines above in " + path + " (or run 'dfrctl reset')");
  }
  makeParents(path);
  const std::string temporary = path + ".new";
  {
    std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
    out << text;
    if (!out.flush()) fail("cannot write " + temporary);
  }
  if (std::rename(temporary.c_str(), path.c_str())) fail("cannot replace " + path + ": " + std::strerror(errno));
}

void set(std::vector<std::string>& content, const std::string& rawKey, const std::string& value) {
  const std::string key = GazeConfig::normalizeKey(rawKey);
  GazeConfig check;
  if (key == "file" || key == "config") fail(key + " is read once at start-up; set it in the launch options");
  if (!check.set(key, value)) fail("cannot set " + rawKey + " to '" + value + "'. Settings:\n" + keys);
  const std::string line = key + " = " + GazeConfig::trim(value);
  bool replaced = false;
  for (auto it = content.begin(); it != content.end();) {
    if (lineKey(*it) != key) { ++it; continue; }
    if (replaced) { it = content.erase(it); continue; }
    *it++ = line;
    replaced = true;
  }
  if (!replaced) content.push_back(line);
}

// Whether the game and the bridge are running.
int status(const std::string& config, const std::string& gazeFile) {
  const std::string path = config + ".status";
  struct stat info {};
  std::string text;
  if (stat(path.c_str(), &info) || !readFile(path, text)) {
    std::cout << "DXVK:   no status file (" << path << ")\n"
                 "        game not started with DXVK_GAZE_VRS=1 and DXVK_GAZE_CONFIG pointing at this config\n";
  } else if (const long age = long(std::time(nullptr) - info.st_mtime); age > 3) {
    std::cout << "DXVK:   not running (last status " << age << " s ago)\n";
  } else {
    std::cout << "DXVK:   running\n";
    for (const auto& line : lines(text))
      if (line.rfind("tick=", 0) != 0) std::cout << "        " << line << "\n";
  }

  const int fd = open(gazeFile.c_str(), O_RDONLY | O_CLOEXEC);
  struct stat gazeInfo {};
  if (fd < 0 || fstat(fd, &gazeInfo) || gazeInfo.st_size != sizeof(gaze_bridge::SharedGaze)) {
    std::cout << "Bridge: no gaze file at " << gazeFile << " (openxr-gaze-bridge not started)\n";
    if (fd >= 0) close(fd);
    return 0;
  }
  void* mapped = mmap(nullptr, sizeof(gaze_bridge::SharedGaze), PROT_READ, MAP_SHARED, fd, 0);
  close(fd);
  if (mapped == MAP_FAILED) fail("cannot map " + gazeFile);
  auto memory = static_cast<const gaze_bridge::SharedGaze*>(mapped);
  gaze_bridge::Sample first, second;
  uint32_t sequence0 = 0, sequence1 = 0;
  const bool ok0 = gaze_bridge::snapshot(memory, first, sequence0);
  std::this_thread::sleep_for(std::chrono::milliseconds(120));
  const bool ok1 = gaze_bridge::snapshot(memory, second, sequence1);
  munmap(mapped, sizeof(gaze_bridge::SharedGaze));
  if (!ok0 || !ok1 || sequence0 == sequence1) {
    std::cout << "Bridge: not running (gaze file is not being updated)\n";
  } else if (!second.valid)
    std::cout << "Bridge: running, no valid gaze (headset off, not worn, or eye tracking disabled)\n";
  else
    std::printf("Bridge: running, gaze L=(%.3f, %.3f) R=(%.3f, %.3f)\n",
      second.u[0], second.v[0], second.u[1], second.v[1]);
  return 0;
}
} // namespace

int main(int argc, char** argv) {
  std::vector<std::string> args(argv + 1, argv + argc);
  std::string config, gazeFile = "/dev/shm/vrchat_dfr_gaze";
  if (const char* path = std::getenv("DFR_GAZE_FILE"); path && *path) gazeFile = path;
  while (args.size() >= 2 && (args[0] == "--config" || args[0] == "--gaze-file")) {
    (args[0] == "--config" ? config : gazeFile) = args[1];
    args.erase(args.begin(), args.begin() + 2);
  }
  if (config.empty()) config = defaultConfig();
  if (args.empty() || args[0] == "--help" || args[0] == "help") { std::cout << usage; return args.empty() ? 2 : 0; }
  const std::string command = args[0];
  args.erase(args.begin());

  std::string text;
  const bool exists = readFile(config, text);
  auto content = lines(text);

  if (command == "keys") { std::cout << keys; return 0; }
  if (command == "launch-options") {
    if (config[0] != '/') fail("use an absolute --config path for launch options");
    std::cout << "DXVK_GAZE_VRS=1 DXVK_GAZE_CONFIG=" << config << " %command%\n";
    return 0;
  }
  if (command == "status") {
    const bool watch = !args.empty() && args[0] == "--watch";
    do {
      if (watch) std::cout << "\033[2J\033[H";
      status(config, gazeFile);
      std::cout.flush();
      if (watch) std::this_thread::sleep_for(std::chrono::seconds(1));
    } while (watch);
    return 0;
  }
  if (command == "show") {
    std::cout << "# " << config << (exists ? "" : " (does not exist: launch option values apply)") << "\n" << text;
    if (!text.empty() && text.back() != '\n') std::cout << "\n";
    std::cout << "\n";
    return status(config, gazeFile);
  }
  if (command == "reset") {
    if (exists && std::remove(config.c_str())) fail("cannot remove " + config);
    std::cout << "Removed " << config << "; launch option values apply.\n";
    return 0;
  }
  if (command == "on" || command == "off") {
    set(content, "enabled", command == "on" ? "1" : "0");
  } else if (command == "set") {
    if (args.empty()) fail("set needs KEY VALUE");
    for (size_t i = 0; i < args.size(); ++i) {
      if (auto eq = args[i].find('='); eq != std::string::npos) set(content, args[i].substr(0, eq), args[i].substr(eq + 1));
      else if (i + 1 < args.size()) { set(content, args[i], args[i + 1]); ++i; }
      else fail("no value given for " + args[i]);
    }
  } else if (command == "unset") {
    if (args.empty()) fail("unset needs KEY");
    for (const auto& raw : args) {
      const std::string key = GazeConfig::normalizeKey(raw);
      GazeConfig check;
      if (!check.set(key, "") && !check.set(key, "0") && !check.set(key, "1")) fail("unknown setting " + raw);
      for (auto it = content.begin(); it != content.end();) it = lineKey(*it) == key ? content.erase(it) : it + 1;
    }
  } else {
    std::cerr << usage;
    return 2;
  }
  if (!exists && content.size() <= 1)
    content.insert(content.begin(), "# vrchat-dfr live settings; edit by hand or with dfrctl. 'dfrctl keys' lists them.");
  writeFile(config, content);
  std::cout << "Wrote " << config << "\n";
  return 0;
}
