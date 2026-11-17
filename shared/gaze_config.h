#pragma once

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

// Gaze VRS tunables. Pure C++ so the native test harness can build it.
// Start-up values come from DXVK_GAZE_* environment variables; an optional
// config file (DXVK_GAZE_CONFIG) overrides them and is re-read while running.
namespace dxvk
{
  enum class GazeFake : uint32_t { None, X, Y, Circle, Fixed, Grid };
  enum class GazeFallback : uint32_t { Off, Center };

  struct GazeConfig
  {
    bool enabled = true;
    float r1 = 0.20f, r2 = 0.40f;
    float fullArea = -1.0f, midArea = -1.0f;
    uint32_t coarse = 5u; // raw rate code, (log2(w) << 2) | log2(h)
    bool autoCoarse = false;
    static constexpr uint32_t RateAuto = 0xffu;
    uint32_t mid = RateAuto; // rate code of the mid_area ring, or RateAuto; see gazeMidRate
    uint32_t minSize = 700u;
    uint32_t onlySamples = 0u, onlyFormat = 0u;
    uint32_t forceW = 0u, forceH = 0u;
    bool debug = false, dot = false;
    int32_t dotRadius = 24;
    bool flipY = false, swapEyes = false;
    int32_t forceFlipX[2] = {-1, -1}, forceFlipY[2] = {-1, -1};
    float gainY = 1.0f, fixedY = 0.25f;
    GazeFake fake = GazeFake::None;
    // Tracking loss (blinks, bridge restart): keep the last gaze this long,
    // then either render at full rate or foveate around the eye centre.
    uint32_t holdMs = 500u;
    GazeFallback fallback = GazeFallback::Off;

    static std::string trim(const std::string &s)
    {
      size_t a = 0u, b = s.size();
      while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) a++;
      while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1u]))) b--;
      return s.substr(a, b - a);
    }

    static std::string lower(std::string s)
    {
      for (auto &c : s) c = char(std::tolower(static_cast<unsigned char>(c)));
      return s;
    }

    // "DXVK_GAZE_FULL_AREA", "full_area" and "Full-Area" all name one key.
    static std::string normalizeKey(const std::string &raw)
    {
      std::string key = lower(trim(raw));
      std::replace(key.begin(), key.end(), '-', '_');
      if (key.rfind("dxvk_gaze_", 0u) == 0u) key.erase(0u, 10u);
      return key;
    }

    static bool parseNumber(const std::string &value, double lo, double hi, double &out)
    {
      if (value.empty()) return false;
      char *end = nullptr;
      const double parsed = std::strtod(value.c_str(), &end);
      if (end == value.c_str() || *end || !std::isfinite(parsed) || parsed < lo || parsed > hi)
        return false;
      out = parsed;
      return true;
    }

    static bool parseBool(const std::string &value, bool &out)
    {
      const std::string v = lower(value);
      if (v == "1" || v == "true" || v == "on" || v == "yes") { out = true; return true; }
      if (v == "0" || v == "false" || v == "off" || v == "no") { out = false; return true; }
      return false;
    }

    static bool validRateCode(uint32_t code)
    {
      return code < 16u && (code & 3u) <= 2u && (code >> 2u) <= 2u;
    }

    // Returns false for an unknown key or a value that is not acceptable.
    // A rejected value leaves the setting untouched.
    bool set(const std::string &rawKey, const std::string &rawValue)
    {
      const std::string key = normalizeKey(rawKey);
      const std::string value = trim(rawValue);
      double n = 0.0;
      bool b = false;
      auto number = [&](double lo, double hi) { return parseNumber(value, lo, hi, n); };
      auto tri = [&](int32_t &out) {
        if (value.empty() || lower(value) == "auto" || value == "-1") { out = -1; return true; }
        if (!parseBool(value, b)) return false;
        out = b ? 1 : 0;
        return true;
      };

      // "2x1" or a raw rate code.
      auto rate = [&](uint32_t &out) {
        unsigned w = 0u, h = 0u;
        char tail = 0;
        if (std::sscanf(lower(value).c_str(), "%ux%u%c", &w, &h, &tail) == 2)
        {
          if ((w != 1u && w != 2u && w != 4u) || (h != 1u && h != 2u && h != 4u)) return false;
          out = ((w >> 1u) << 2u) | (h >> 1u);
          return true;
        }
        if (!number(0.0, 15.0) || n != std::floor(n) || !validRateCode(uint32_t(n))) return false;
        out = uint32_t(n);
        return true;
      };

      if (key == "enabled" || key == "vrs") { if (!parseBool(value, b)) return false; enabled = b; }
      else if (key == "r1") { if (!number(0.0, 10.0)) return false; r1 = float(n); }
      else if (key == "r2") { if (!number(0.0, 10.0)) return false; r2 = float(n); }
      else if (key == "full_area") { if (!number(-1.0, 100.0)) return false; fullArea = n < 0.0 ? -1.0f : float(n); }
      else if (key == "mid_area") { if (!number(-1.0, 100.0)) return false; midArea = n < 0.0 ? -1.0f : float(n); }
      else if (key == "coarse" || key == "maxrate")
      {
        if (lower(value) == "auto") { autoCoarse = true; }
        else { if (!rate(coarse)) return false; autoCoarse = false; }
      }
      else if (key == "mid")
      {
        if (lower(value) == "auto") mid = RateAuto;
        else if (!rate(mid)) return false;
      }
      else if (key == "minsize") { if (!number(1.0, 65536.0)) return false; minSize = uint32_t(n); }
      else if (key == "samples") { if (!number(0.0, 64.0)) return false; onlySamples = uint32_t(n); }
      else if (key == "fmt") { if (!number(0.0, 4294967295.0)) return false; onlyFormat = uint32_t(n); }
      else if (key == "size")
      {
        unsigned w = 0u, h = 0u;
        char tail = 0;
        if (value.empty() || value == "0") { forceW = forceH = 0u; }
        else if (std::sscanf(value.c_str(), "%ux%u%c", &w, &h, &tail) == 2 && w && h) { forceW = w; forceH = h; }
        else return false;
      }
      else if (key == "debug") { if (!parseBool(value, b)) return false; debug = b; }
      else if (key == "dot") { if (!parseBool(value, b)) return false; dot = b; }
      else if (key == "dot_radius") { if (!number(1.0, 512.0)) return false; dotRadius = int32_t(n); }
      else if (key == "flip_y") { if (!parseBool(value, b)) return false; flipY = b; }
      else if (key == "swap_eyes") { if (!parseBool(value, b)) return false; swapEyes = b; }
      else if (key == "gain_y") { if (!number(0.0, 10.0)) return false; gainY = float(n); }
      else if (key == "fixed_y") { if (!number(0.0, 1.0)) return false; fixedY = float(n); }
      else if (key == "flipx_l") return tri(forceFlipX[0]);
      else if (key == "flipx_r") return tri(forceFlipX[1]);
      else if (key == "flipy_l") return tri(forceFlipY[0]);
      else if (key == "flipy_r") return tri(forceFlipY[1]);
      else if (key == "fake")
      {
        const std::string v = lower(value);
        if (v.empty() || v == "0" || v == "none" || v == "off") fake = GazeFake::None;
        else if (v == "x") fake = GazeFake::X;
        else if (v == "y") fake = GazeFake::Y;
        else if (v == "circle") fake = GazeFake::Circle;
        else if (v == "fixed") fake = GazeFake::Fixed;
        else if (v == "grid") fake = GazeFake::Grid;
        else return false;
      }
      else if (key == "hold_ms") { if (!number(0.0, 10000.0)) return false; holdMs = uint32_t(n); }
      else if (key == "fallback")
      {
        const std::string v = lower(value);
        if (v.empty() || v == "0" || v == "off" || v == "none") fallback = GazeFallback::Off;
        else if (v == "center" || v == "centre") fallback = GazeFallback::Center;
        else return false;
      }
      // Read once at start-up by their owners; accepted so that one file can
      // hold a whole launch configuration.
      else if (key == "file" || key == "config") { }
      else return false;
      return true;
    }

    // Keep the zones nested whatever order the settings were given in.
    void sanitize()
    {
      if (fullArea >= 0.0f && midArea >= 0.0f) midArea = std::max(midArea, fullArea);
      if (fullArea < 0.0f && midArea < 0.0f) r2 = std::max(r1, r2);
    }

    bool operator==(const GazeConfig &o) const
    {
      return enabled == o.enabled && r1 == o.r1 && r2 == o.r2
          && fullArea == o.fullArea && midArea == o.midArea
          && coarse == o.coarse && autoCoarse == o.autoCoarse && mid == o.mid && minSize == o.minSize
          && onlySamples == o.onlySamples && onlyFormat == o.onlyFormat
          && forceW == o.forceW && forceH == o.forceH && debug == o.debug && dot == o.dot
          && dotRadius == o.dotRadius && flipY == o.flipY && swapEyes == o.swapEyes
          && forceFlipX[0] == o.forceFlipX[0] && forceFlipX[1] == o.forceFlipX[1]
          && forceFlipY[0] == o.forceFlipY[0] && forceFlipY[1] == o.forceFlipY[1]
          && gainY == o.gainY && fixedY == o.fixedY && fake == o.fake
          && holdMs == o.holdMs && fallback == o.fallback;
    }
    bool operator!=(const GazeConfig &o) const { return !(*this == o); }

    std::string describe() const
    {
      static const char *const fakes[] = {"none", "x", "y", "circle", "fixed", "grid"};
      char text[512];
      std::snprintf(text, sizeof(text),
          "enabled=%d full_area=%g mid_area=%g r1=%g r2=%g coarse=%s%u mid=%u fmt=%u samples=%u"
          " minsize=%u size=%ux%u flip_y=%d swap_eyes=%d gain_y=%g fake=%s hold_ms=%u"
          " fallback=%s dot=%d debug=%d",
          int(enabled), double(fullArea), double(midArea), double(r1), double(r2),
          autoCoarse ? "auto/" : "", coarse, mid, onlyFormat, onlySamples, minSize, forceW, forceH,
          int(flipY), int(swapEyes), double(gainY), fakes[uint32_t(fake)], holdMs,
          fallback == GazeFallback::Center ? "center" : "off", int(dot), int(debug));
      return text;
    }
  };

  // Rate of the ring between full_area and mid_area for an outer rate. `auto`
  // gives what the ring had before `mid` existed: 2x2, or the outer rate where
  // that is finer. The ring is never coarser than the outer rate in either axis.
  inline uint32_t gazeMidRate(uint32_t mid, uint32_t coarse)
  {
    const uint32_t want = mid == GazeConfig::RateAuto ? std::min(5u, coarse) : mid;
    return (std::min(want >> 2u, coarse >> 2u) << 2u) | std::min(want & 3u, coarse & 3u);
  }

  // Every key that can also be given as a DXVK_GAZE_<KEY> environment variable.
  inline const std::vector<std::string> &gazeConfigEnvKeys()
  {
    static const std::vector<std::string> keys = {
        "R1", "R2", "FULL_AREA", "MID_AREA", "MAXRATE", "COARSE", "MID", "MINSIZE", "SAMPLES", "FMT",
        "SIZE", "DEBUG", "DOT", "DOT_RADIUS", "FLIP_Y", "SWAP_EYES", "GAIN_Y", "FIXED_Y",
        "FLIPX_L", "FLIPX_R", "FLIPY_L", "FLIPY_R", "FAKE", "HOLD_MS", "FALLBACK"};
    return keys;
  }

  // getenv(name) returns the value, or an empty string when it is not set.
  template<typename Getenv>
  GazeConfig gazeConfigFromEnv(Getenv &&getenv, std::vector<std::string> &errors)
  {
    GazeConfig config;
    for (const auto &key : gazeConfigEnvKeys())
    {
      const std::string name = "DXVK_GAZE_" + key;
      const std::string value = getenv(name.c_str());
      if (!value.empty() && !config.set(key, value))
        errors.push_back(name + "=" + value + " is not valid, ignored");
    }
    config.sanitize();
    return config;
  }

  // "key = value" lines; '#' starts a comment. Returns false and leaves config
  // untouched if any line is wrong, so a typo never applies half a file.
  inline bool parseGazeConfigText(const std::string &text, GazeConfig &config,
      std::vector<std::string> &errors)
  {
    GazeConfig parsed = config;
    bool ok = true;
    size_t pos = 0u;
    uint32_t lineNumber = 0u;
    while (pos <= text.size())
    {
      size_t end = text.find('\n', pos);
      if (end == std::string::npos) end = text.size();
      std::string line = text.substr(pos, end - pos);
      pos = end + 1u;
      lineNumber++;
      const size_t comment = line.find('#');
      if (comment != std::string::npos) line.erase(comment);
      line = GazeConfig::trim(line);
      if (line.empty()) continue;
      const size_t eq = line.find('=');
      std::string value = eq == std::string::npos ? "" : GazeConfig::trim(line.substr(eq + 1u));
      if (value.size() >= 2u && (value.front() == '"' || value.front() == '\'')
          && value.back() == value.front())
        value = value.substr(1u, value.size() - 2u);
      if (eq == std::string::npos || !parsed.set(line.substr(0u, eq), value))
      {
        errors.push_back("line " + std::to_string(lineNumber) + ": cannot use '" + line + "'");
        ok = false;
      }
    }
    if (!ok) return false;
    parsed.sanitize();
    config = parsed;
    return true;
  }

  // Polls the config file by content. A missing file means "environment
  // values only"; a file with errors keeps whatever was in effect before.
  class GazeConfigFile
  {
  public:
    GazeConfigFile() = default;
    GazeConfigFile(std::string path, const GazeConfig &base)
    : m_path(std::move(path)), m_base(base), m_current(base) { }

    const GazeConfig &config() const { return m_current; }
    const std::string &path() const { return m_path; }

    // Returns true when the effective configuration changed. messages gets
    // one-off notes worth logging (file appeared, went away, was rejected).
    bool reload(std::vector<std::string> &messages)
    {
      if (m_path.empty()) return false;
      std::string text;
      const bool exists = read(text);
      if (m_seen && exists == m_exists && text == m_text) return false;
      const bool first = !m_seen;
      m_seen = true;
      m_exists = exists;
      m_text = text;

      GazeConfig next = m_base;
      if (!exists)
      {
        messages.push_back(first ? "config file not found, using environment values: " + m_path
                                 : "config file removed, back to environment values");
      }
      else
      {
        std::vector<std::string> errors;
        if (!parseGazeConfigText(text, next, errors))
        {
          for (const auto &e : errors) messages.push_back("config " + e);
          messages.push_back("config file rejected, keeping previous settings");
          return false;
        }
      }
      if (next == m_current) return false;
      m_current = next;
      return true;
    }

  private:
    std::string m_path, m_text;
    GazeConfig m_base, m_current;
    bool m_seen = false, m_exists = false;

    bool read(std::string &text) const
    {
      std::FILE *file = std::fopen(m_path.c_str(), "rb");
      if (!file) return false;
      char buffer[4096];
      size_t n;
      // Settings are a few hundred bytes; refuse to slurp anything huge.
      while (text.size() <= 65536u && (n = std::fread(buffer, 1u, sizeof(buffer), file)) > 0u)
        text.append(buffer, n);
      std::fclose(file);
      return true;
    }
  };
}
