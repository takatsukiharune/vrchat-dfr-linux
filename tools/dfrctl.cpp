// SPDX-License-Identifier: MIT
// Edits the gaze-VRS config file that patched DXVK re-reads while the game
// runs, and reports what DXVK and the gaze bridge are doing. Values are
// checked with the same parser DXVK uses, so a bad edit is refused here.
#include "../shared/gaze_config.h"
#include "../shared/gaze_shm.h"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
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
  "  doctor [APPID]           check the whole setup for a Steam game (default 438100, VRChat)\n"
  "  keys                     list the settings\n"
  "  launch-options           print the Steam launch options that use this config file\n"
  "Config: $DFR_CONFIG, else ~/.config/vrchat-dfr/dfr.conf. Gaze file: $DFR_GAZE_FILE,\n"
  "else /dev/shm/vrchat_dfr_gaze. Steam: $STEAM_DIR, else the usual places under $HOME.\n";

const char* const keys =
  "enabled      0|1          foveation on/off\n"
  "full_area    0..100       % of one eye's image shaded at full rate\n"
  "mid_area     0..100       % shaded at full rate or at 'mid'; the rest uses 'coarse'\n"
  "r1, r2       0..10        zone radii, used only when the areas are unset (-1)\n"
  "coarse       auto|1x1|2x1|1x2|2x2|2x4|4x2|4x4   outer rate, clamped to what the GPU supports\n"
  "mid          1x1|2x1|1x2|2x2   rate of the mid_area ring (default 2x2), never coarser than 'coarse'\n"
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

// Whether the game and the bridge are running. With `problems`, a stopped
// bridge counts as one; a stopped game does not.
int status(const std::string& config, const std::string& gazeFile, int* problems = nullptr) {
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
    if (problems) ++*problems;
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
    if (problems) ++*problems;
  } else if (!second.valid)
    std::cout << "Bridge: running, no valid gaze (headset off, not worn, or eye tracking disabled)\n";
  else
    std::printf("Bridge: running, gaze L=(%.3f, %.3f) R=(%.3f, %.3f)\n",
      second.u[0], second.v[0], second.u[1], second.v[1]);
  return 0;
}
namespace fs = std::filesystem;

// Steam's text VDF: "key" "value" pairs and "key" { ... } blocks, // comments.
struct Vdf {
  std::string key, value;
  std::vector<Vdf> children;

  static bool same(const std::string& a, const std::string& b) {
    return a.size() == b.size() && std::equal(a.begin(), a.end(), b.begin(),
      [](char x, char y) { return std::tolower(uint8_t(x)) == std::tolower(uint8_t(y)); });
  }
  const Vdf* child(const std::string& name) const {
    for (const auto& c : children) if (same(c.key, name)) return &c;
    return nullptr;
  }
  std::string get(const std::string& name) const {
    const Vdf* c = child(name);
    return c ? c->value : "";
  }
  // Every block called `name`, at any depth.
  void findAll(const std::string& name, std::vector<const Vdf*>& out) const {
    for (const auto& c : children) {
      if (same(c.key, name) && !c.children.empty()) out.push_back(&c);
      c.findAll(name, out);
    }
  }
  const Vdf* find(const std::string& name) const {
    std::vector<const Vdf*> all;
    findAll(name, all);
    return all.empty() ? nullptr : all.front();
  }

  static Vdf parse(const std::string& text) {
    size_t i = 0;
    Vdf root;
    root.children = parseBlock(text, i);
    return root;
  }

 private:
  static bool token(const std::string& t, size_t& i, std::string& out) {
    for (;;) {
      while (i < t.size() && std::isspace(uint8_t(t[i]))) ++i;
      if (t.compare(i, 2, "//")) break;
      i = t.find('\n', i);
      if (i == std::string::npos) i = t.size();
    }
    if (i >= t.size()) return false;
    out.clear();
    if (t[i] == '{' || t[i] == '}') { out = t[i++]; return true; }
    if (t[i] != '"') {
      while (i < t.size() && !std::isspace(uint8_t(t[i])) && t[i] != '{' && t[i] != '}') out += t[i++];
      return true;
    }
    for (++i; i < t.size() && t[i] != '"'; ++i) {
      if (t[i] == '\\' && i + 1 < t.size()) {
        const char e = t[++i];
        out += e == 'n' ? '\n' : e == 't' ? '\t' : e;
      } else {
        out += t[i];
      }
    }
    ++i;
    out.insert(out.begin(), '"');  // marks a string, so a quoted "{" is not a brace
    return true;
  }
  static std::vector<Vdf> parseBlock(const std::string& t, size_t& i) {
    std::vector<Vdf> nodes;
    std::string key, next;
    while (token(t, i, key) && key != "}") {
      if (key == "{" || !token(t, i, next) || next == "}") break;
      Vdf node;
      node.key = key[0] == '"' ? key.substr(1) : key;
      if (next == "{") node.children = parseBlock(t, i);
      else node.value = next[0] == '"' ? next.substr(1) : next;
      nodes.push_back(std::move(node));
    }
    return nodes;
  }
};

Vdf readVdf(const fs::path& path) {
  std::string text;
  readFile(path.string(), text);
  return Vdf::parse(text);
}

// The environment Steam's launch options give the game: the shell words before
// %command%, as assignments up to the first command word, or after `env`.
// Without %command% the options are game arguments and set nothing.
std::map<std::string, std::string> launchEnvironment(const std::string& options) {
  std::vector<std::string> words;
  std::string word;
  bool inWord = false;
  for (size_t i = 0; i < options.size(); ++i) {
    const char c = options[i];
    if (c == '\'' || c == '"') {
      const size_t end = options.find(c, i + 1);
      word += options.substr(i + 1, end == std::string::npos ? std::string::npos : end - i - 1);
      i = end == std::string::npos ? options.size() : end;
      inWord = true;
    } else if (c == '\\' && i + 1 < options.size()) {
      word += options[++i];
      inWord = true;
    } else if (std::isspace(uint8_t(c))) {
      if (inWord) words.push_back(word);
      word.clear();
      inWord = false;
    } else {
      word += c;
      inWord = true;
    }
  }
  if (inWord) words.push_back(word);

  std::map<std::string, std::string> env;
  const auto command = std::find(words.begin(), words.end(), "%command%");
  if (command == words.end()) return env;
  bool assigning = true;
  for (auto it = words.begin(); it != command; ++it) {
    const size_t eq = it->find('=');
    const bool assignment = eq != std::string::npos && eq > 0
      && std::all_of(it->begin(), it->begin() + eq, [](char c) { return std::isalnum(uint8_t(c)) || c == '_'; });
    if (assignment && assigning) env[it->substr(0, eq)] = it->substr(eq + 1);
    else if (*it == "env") assigning = true;
    else if (!assignment) assigning = false;
  }
  return env;
}

// The `git describe` string DXVK embeds, e.g. v3.1.1-174-gf8637768-dfr.90f053c.
std::string dxvkVersion(const std::string& dll) {
  auto digits = [&](size_t& i) { const size_t start = i; while (i < dll.size() && std::isdigit(uint8_t(dll[i]))) ++i; return i > start; };
  for (size_t at = dll.find('v'); at != std::string::npos; at = dll.find('v', at + 1)) {
    size_t i = at + 1;
    if (!digits(i) || dll[i++] != '.' || !digits(i)) continue;
    if (dll[i] == '.' && !digits(++i)) continue;
    if (dll[i++] != '-' || !digits(i) || dll.compare(i, 2, "-g")) continue;
    const size_t hash = i += 2;
    while (i < dll.size() && std::isxdigit(uint8_t(dll[i]))) ++i;
    if (i - hash < 7) continue;
    while (i < dll.size() && (std::isalnum(uint8_t(dll[i])) || (dll[i] && std::strchr("-+.()", dll[i])))) ++i;
    return dll.substr(at, i - at);
  }
  return "";
}

std::string firstLine(const fs::path& path) {
  std::string text;
  readFile(path.string(), text);
  return text.substr(0, text.find('\n'));
}

// Directory of the compatibility tool Steam calls `name`: a tool in
// compatibilitytools.d that declares it, or Valve's Proton in steamapps/common.
fs::path findTool(const fs::path& steam, const std::string& name) {
  std::error_code ignored;
  for (const auto& entry : fs::directory_iterator(steam / "compatibilitytools.d", ignored)) {
    const Vdf manifest = readVdf(entry.path() / "compatibilitytool.vdf");
    const Vdf* tools = manifest.find("compat_tools");
    if ((tools && tools->child(name)) || entry.path().filename() == name) return entry.path();
  }
  // proton_experimental, proton_hotfix, proton_9 -> "Proton - Experimental", "Proton Hotfix", "Proton 9.0..."
  std::string folder;
  if (name == "proton_experimental") folder = "Proton - Experimental";
  else if (name == "proton_hotfix") folder = "Proton Hotfix";
  else if (name.rfind("proton_", 0) == 0) folder = "Proton " + name.substr(7) + ".0";
  for (const auto& entry : fs::directory_iterator(steam / "steamapps/common", ignored)) {
    const std::string dir = entry.path().filename().string();
    if (!folder.empty() && dir.rfind(folder, 0) == 0
        && fs::exists(entry.path() / "files/lib/wine/dxvk/x86_64-windows/d3d11.dll", ignored)) return entry.path();
  }
  return {};
}

int doctor(const std::string& config, const std::string& gazeFile, const std::string& app) {
  int problems = 0;
  auto bad = [&](const std::string& message) { std::cout << "  !! " << message << "\n"; ++problems; };
  auto good = [](const std::string& message) { std::cout << "  ok " << message << "\n"; };

  std::vector<fs::path> roots;
  const std::string home = std::getenv("HOME") ? std::getenv("HOME") : "";
  for (const std::string& root : { std::string(std::getenv("STEAM_DIR") ? std::getenv("STEAM_DIR") : ""),
      home + "/.local/share/Steam", home + "/.steam/steam", home + "/.var/app/com.valvesoftware.Steam/.local/share/Steam" }) {
    std::error_code error;
    const fs::path real = fs::canonical(root, error);
    if (!root.empty() && !error && std::find(roots.begin(), roots.end(), real) == roots.end()) roots.push_back(real);
  }

  bool any = false;
  for (const auto& steam : roots) {
    // A Steam directory without a configuration is not one Steam runs from.
    if (!fs::exists(steam / "config/config.vdf")) continue;
    any = true;
    std::cout << "Steam:  " << steam.string() << "\n";
    const Vdf steamConfig = readVdf(steam / "config/config.vdf");
    const Vdf* mapping = steamConfig.find("CompatToolMapping");
    std::string name;
    // A game without a tool of its own uses Steam's default, stored as app 0.
    for (const std::string& id : { app, std::string("0") })
      if (const Vdf* entry = mapping ? mapping->child(id) : nullptr; name.empty() && entry) name = entry->get("name");
    const fs::path tool = name.empty() ? fs::path() : findTool(steam, name);
    if (name.empty()) {
      bad("app " + app + " has no compatibility tool selected; select a patched one in its Steam properties");
    } else if (tool.empty()) {
      bad("app " + app + " uses '" + name + "', which is not in compatibilitytools.d; install-dxvk.sh makes a patched copy");
    } else {
      const fs::path dxvk = tool / "files/lib/wine/dxvk";
      std::string dll;
      readFile((dxvk / "x86_64-windows/d3d11.dll").string(), dll);
      const std::string version = dxvkVersion(dll), shipped = firstLine(dxvk / "version");
      const size_t hash = version.find("-g");
      const size_t hashEnd = hash == std::string::npos ? hash : version.find_first_not_of("0123456789abcdef", hash + 2);
      const std::string commit = hash == std::string::npos ? "" : version.substr(hash + 2, hashEnd - hash - 2);
      if (dll.find("DXVK_GAZE_VRS") == std::string::npos)
        bad("app " + app + " uses '" + name + "' with stock DXVK " + version + "; run install-dxvk.sh");
      else if (commit.empty() || shipped.find(commit) == std::string::npos)
        bad("'" + name + "' has gaze DXVK " + version + ", but this Proton build ships" + shipped + "; build with --proton and reinstall");
      else
        good("app " + app + " uses '" + name + "' with gaze DXVK " + version);
      // GE-Proton and proton-cachyos patch DXVK; a build for them names the release.
      std::string release = firstLine(tool / "version");
      release.erase(0, release.find(' ') + 1);
      if (dll.find("DXVK_GAZE_VRS") != std::string::npos && version.find("-" + release + "-dfr.") == std::string::npos
          && (release.rfind("GE-Proton", 0) == 0 || release.rfind("cachyos-", 0) == 0))
        bad("this DXVK lacks the DXVK patches of " + release + "; build with --proton and reinstall");
      // A copy whose source is gone keeps working; one whose source changed is behind.
      const std::string origin = firstLine(tool / ".dfr-clone");
      if (!origin.empty() && fs::is_directory(origin) && firstLine(fs::path(origin) / "version") != firstLine(tool / "version"))
        bad(origin + " changed after this copy was made; run install-dxvk.sh --refresh '" + tool.filename().string() + "'");
    }

    bool found = false;
    std::error_code ignored;
    for (const auto& user : fs::directory_iterator(steam / "userdata", ignored)) {
      const Vdf local = readVdf(user.path() / "config/localconfig.vdf");
      std::vector<const Vdf*> lists;
      local.findAll("apps", lists);
      std::string options;
      for (const Vdf* list : lists)
        if (const Vdf* entry = list->child(app); options.empty() && entry) options = entry->get("LaunchOptions");
      if (options.empty()) continue;
      found = true;
      const auto env = launchEnvironment(options);
      auto setting = [&](const std::string& key) { const auto it = env.find(key); return it == env.end() ? std::string() : it->second; };
      if (setting("DXVK_GAZE_VRS") != "1") bad("launch options lack DXVK_GAZE_VRS=1 before %command%; see 'dfrctl launch-options'");
      else if (setting("DXVK_GAZE_CONFIG") != config) bad("launch options do not point DXVK_GAZE_CONFIG at " + config + "; live tuning and status are off");
      else if (const std::string file = setting("DXVK_GAZE_FILE"); !file.empty() && file != gazeFile) bad("launch options use gaze file " + file + ", the bridge check below uses " + gazeFile);
      else good("launch options enable gaze VRS with this config file");
    }
    if (!found) bad("no launch options set for app " + app + "; see 'dfrctl launch-options'");
  }
  if (!any) bad("no Steam configuration found; set STEAM_DIR");
  status(config, gazeFile, &problems);
  std::cout << (problems ? "Problems found: " + std::to_string(problems) : std::string("No problems found.")) << "\n";
  return problems ? 1 : 0;
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
  if (command == "doctor") return doctor(config, gazeFile, args.empty() ? "438100" : args[0]);
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
