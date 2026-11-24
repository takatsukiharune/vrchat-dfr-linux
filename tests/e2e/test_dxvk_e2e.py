#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""End-to-end check of the patched DXVK DLLs.

Runs an offscreen D3D11 probe under Wine against a real Vulkan driver with
VK_KHR_fragment_shading_rate, feeds it a fake gaze file and edits the config
file while it runs. The probe reports which tiles were shaded coarsely, so
every assertion here is about pixels that were actually rendered.
"""
import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

WIDTH, HEIGHT = 2048, 1024


class Scenario:
    def __init__(self, args, work, samples=1, validate=False):
        self.args, self.work, self.samples, self.validate = args, work, samples, validate
        self.grid_path = work / "grid.txt"
        self.config = work / "dfr.conf"
        self.gaze = work / "gaze"
        self.writer = self.probe = None
        self.last_frame = 0

    # -- processes ---------------------------------------------------------
    def start_writer(self, ul, vl, ur, vr):
        self.stop_writer()
        self.writer = subprocess.Popen([self.args.writer, str(self.gaze), *map(str, (ul, vl, ur, vr))])

    def stop_writer(self, sig=signal.SIGKILL):
        if self.writer:
            self.writer.send_signal(sig)
            self.writer.wait()
            self.writer = None

    def start_probe(self, env_extra, seconds=120, size=(WIDTH, HEIGHT), mode=()):
        for name in ("d3d11.dll", "dxgi.dll"):
            shutil.copy(Path(self.args.dxvk) / name, self.work / name)
        shutil.copy(self.args.probe, self.work / "probe.exe")
        env = dict(os.environ)
        for name in [n for n in env if n.startswith("DXVK_")] + ["DISPLAY", "WAYLAND_DISPLAY"]:
            env.pop(name, None)
        env.update(WINEDEBUG="-all", WINEDLLOVERRIDES="d3d11,dxgi=n;mscoree,mshtml=",
                   DXVK_LOG_LEVEL="info", DXVK_LOG_PATH=str(self.work), **env_extra)
        if self.validate:
            env.update(VK_INSTANCE_LAYERS="VK_LAYER_KHRONOS_validation",
                       VK_KHRONOS_VALIDATION_LOG_FILENAME=str(self.work / "validation.log"))
        self.probe = subprocess.Popen(
            ["wine", "probe.exe", str(size[0]), str(size[1]), str(seconds),
             "Z:" + str(self.grid_path).replace("/", "\\"), str(self.samples), *mode],
            cwd=self.work, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def stop(self):
        self.stop_writer()
        if self.probe:
            self.probe.kill()
            self.probe.wait()
        subprocess.run(["wineserver", "-k"], stderr=subprocess.DEVNULL)

    # -- observation -------------------------------------------------------
    def write_config(self, **values):
        temporary = self.config.with_suffix(".tmp")
        temporary.write_text("".join(f"{k} = {v}\n" for k, v in values.items()))
        temporary.replace(self.config)

    def read(self):
        """Per eye: (fraction of full-rate tiles, centroid u, centroid v), plus coarse classes seen."""
        try:
            lines = self.grid_path.read_text().split("\n")
            frame, tiles_x, tiles_y = map(int, lines[0].split())
            rows = lines[1:1 + tiles_y]
            if len(rows) != tiles_y or any(len(r) != tiles_x for r in rows):
                return None
        except (OSError, ValueError, IndexError):
            return None
        eyes, half = [], tiles_x // 2
        for eye in range(2):
            cells = [(x, y) for y, row in enumerate(rows)
                     for x, c in enumerate(row[eye * half:(eye + 1) * half]) if c == "0"]
            n = len(cells)
            eyes.append((n / (half * tiles_y),
                         sum(x + 0.5 for x, _ in cells) / n / half if n else -1.0,
                         sum(y + 0.5 for _, y in cells) / n / tiles_y if n else -1.0))
        text = "".join(rows)
        return {"frame": frame, "eyes": eyes, "classes": set(text), "half": text.count("h") / len(text)}

    def wait(self, what, predicate, timeout=10.0):
        deadline, state = time.monotonic() + timeout, None
        while time.monotonic() < deadline:
            if self.probe.poll() is not None:
                raise AssertionError(f"probe exited early (code {self.probe.returncode}) while waiting for: {what}")
            state = self.read()
            if state and state["frame"] > self.last_frame and predicate(state):
                self.last_frame = state["frame"]
                print(f"  ok: {what}")
                return state
            time.sleep(0.05)
        raise AssertionError(f"timed out waiting for: {what}; last state {state}")

    def hold(self, what, predicate, seconds):
        """The predicate must stay true for every snapshot over this period."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            state = self.read()
            if state and not predicate(state):
                raise AssertionError(f"did not hold: {what}; state {state}")
            time.sleep(0.05)
        print(f"  ok: {what}")

    def log(self):
        return "".join(p.read_text(errors="replace") for p in self.work.glob("probe_d3d11.log"))


def near(value, target, tolerance):
    return abs(value - target) <= tolerance


def foveated(area, left, right, area_tol=None, pos_tol=0.03):
    """Both eyes show a full-rate disc of this area (fraction) at these UVs."""
    area_tol = area_tol or max(0.012, area * 0.12)
    def check(state):
        return all(near(eye[0], area, area_tol) and near(eye[1], uv[0], pos_tol) and near(eye[2], uv[1], pos_tol)
                   for eye, uv in zip(state["eyes"], (left, right)))
    return check


def full_rate(state):
    return state["classes"] == {"0"}


def run_main(args, work, samples, validate):
    s = Scenario(args, work, samples, validate)
    base = dict(full_area=5, mid_area=15, coarse="auto", hold_ms=500)
    L, R = (0.40, 0.45), (0.60, 0.55)
    try:
        s.write_config(**base)
        s.start_writer(*L, *R)
        # Linux-style paths on purpose: DXVK converts them to Z: paths.
        s.start_probe(dict(DXVK_GAZE_VRS="1", DXVK_GAZE_FMT="97", DXVK_GAZE_FILE=str(s.gaze),
                           DXVK_GAZE_CONFIG=str(s.config), DXVK_GAZE_FULL_AREA="10",
                           DXVK_GAZE_MID_AREA="20", DXVK_GAZE_COARSE="auto"))
        state = s.wait("foveated at the published gaze, 5% full rate", foveated(0.05, L, R), 60)
        assert state["classes"] <= {"0", "1", "2"} and state["classes"] != {"0"}

        s.write_config(**{**base, "full_area": 30, "mid_area": 50})
        s.wait("live change: full_area 5 -> 30", foveated(0.30, L, R))

        s.write_config(**{**base, "flip_y": 1})
        s.wait("live change: flip_y mirrors the fovea vertically",
               foveated(0.05, (L[0], 1 - L[1]), (R[0], 1 - R[1])))

        s.write_config(**{**base, "swap_eyes": 1})
        s.wait("live change: swap_eyes", foveated(0.05, R, L))

        s.write_config(**{**base, "enabled": 0})
        s.wait("live change: enabled=0 renders everything at full rate", full_rate)
        s.write_config(**base)
        s.wait("live change: enabled=1 foveates again", foveated(0.05, L, R))

        s.write_config(**{**base, "coarse": "1x1"})
        s.wait("live change: coarse=1x1 is full rate everywhere", full_rate)
        # 4x4 is not supported on every GPU; it must be clamped, never passed through.
        s.write_config(**{**base, "coarse": "4x4"})
        s.wait("live change: coarse=4x4 (clamped to what the GPU supports)", foveated(0.05, L, R))

        # The ring between full_area and mid_area takes the intermediate rate.
        s.write_config(**{**base, "mid": "2x1"})
        s.wait("live change: mid=2x1 shades the mid ring at a half step",
               lambda state: foveated(0.05, L, R)(state) and near(state["half"], 0.10, 0.03))
        s.write_config(**base)
        s.wait("live change: mid back to 2x2", lambda state: "h" not in state["classes"])

        s.config.write_text("full_area = banana\nmid_area = 50\n")
        s.hold("a config file with an invalid value is rejected as a whole", foveated(0.05, L, R), 1.5)
        assert "config file rejected" in s.log(), "rejection was not logged"

        s.write_config(**{**base, "hold_ms": 2500})
        s.wait("hold_ms raised", foveated(0.05, L, R))
        time.sleep(0.6)
        s.stop_writer()  # SIGKILL, like a crashed bridge
        killed = time.monotonic()
        s.hold("gaze is held after the bridge dies", foveated(0.05, L, R), 1.5)
        s.wait("held gaze expires to full rate", full_rate)
        elapsed = time.monotonic() - killed
        assert 2.0 <= elapsed <= 5.0, f"hold lasted {elapsed:.2f}s, expected about 2.5s"

        s.write_config(**{**base, "fallback": "center"})
        s.wait("fallback=center foveates around the eye centre", foveated(0.05, (0.5, 0.5), (0.5, 0.5)))

        L2, R2 = (0.30, 0.60), (0.70, 0.40)
        s.start_writer(*L2, *R2)
        s.wait("bridge restart is picked up", foveated(0.05, L2, R2), 15)

        s.config.unlink()
        s.wait("config file removed: environment values apply", foveated(0.10, L2, R2))
        s.write_config(**base)
        s.wait("config file restored", foveated(0.05, L2, R2))

        # Written once a second, so give it time to catch up with the restart.
        deadline, status = time.monotonic() + 5, {}
        while time.monotonic() < deadline:
            status = dict(line.split("=", 1) for line in
                          (s.work / "dfr.conf.status").read_text().splitlines() if "=" in line)
            if (status.get("gaze") == "live" and status.get("source") == "open"
                    and int(status.get("foveated_passes_per_s", 0)) > 0):
                break
            time.sleep(0.2)
        else:
            raise AssertionError(f"status file never reported live foveation: {status}")
        print("  ok: status file reports live foveation")

        log = s.log()
        assert "GazeVRS: init ok" in log
        opened = log.count("gaze source opened")
        assert opened == 1, f"'gaze source opened' logged {opened} times"
    finally:
        s.stop()


def run_multipass(args, work, validate):
    """Three candidate pass shapes per frame alongside an idle second D3D11 device.

    Every candidate pass must keep foveating, and the status file must stay
    non-empty and non-zero across multiple status ticks.
    """
    s = Scenario(args, work, 4, validate)
    L, R = (0.40, 0.45), (0.60, 0.55)
    try:
        s.write_config(full_area=5, mid_area=15, coarse="auto", hold_ms=500)
        s.start_writer(*L, *R)
        # Omit samples and size so all three RGBA16F passes match.
        s.start_probe(
            dict(DXVK_GAZE_VRS="1", DXVK_GAZE_FMT="97", DXVK_GAZE_FILE=str(s.gaze),
                 DXVK_GAZE_CONFIG=str(s.config)),
            mode=("multipass",),
        )
        s.wait("4x MSAA pass foveates alongside 1x and smaller passes",
               foveated(0.05, L, R), 60)

        status_path = s.work / "dfr.conf.status"
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if status_path.exists():
                st = dict(line.split("=", 1) for line in status_path.read_text().splitlines() if "=" in line)
                if st.get("gaze") == "live" and int(st.get("foveated_passes_per_s", 0)) > 0:
                    break
            time.sleep(0.1)
        else:
            raise AssertionError("status file never reported live foveation in multipass mode")

        # Poll for 3.5 s across multiple 1 s status ticks from both D3D11 devices.
        deadline, ticks = time.monotonic() + 3.5, set()
        while time.monotonic() < deadline:
            text = status_path.read_text()
            assert text.strip(), "status file was empty during read"
            st = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
            cand = int(st.get("candidate_passes_per_s", 0))
            fov = int(st.get("foveated_passes_per_s", 0))
            assert st.get("gaze") == "live" and st.get("source") == "open", f"status dropped gaze: {st}"
            assert cand > 0, f"candidate_passes_per_s dropped to 0: {st}"
            assert fov > 0 and fov * 5 >= cand * 4, f"foveated_passes_per_s dropped ({fov}/{cand}): {st}"
            assert st.get("pass") == f"{WIDTH}x{HEIGHT} layers=1 fmt=97 samples=4", f"unexpected primary pass: {st}"
            ticks.add(st.get("tick", ""))
            state = s.read()
            if state:
                assert foveated(0.05, L, R)(state), f"main pass lost foveation: {state}"
            time.sleep(0.1)
        assert len(ticks) >= 2, f"status file did not advance across ticks: {ticks}"
        print(f"  ok: status stayed non-zero across {len(ticks)} ticks with three pass shapes and an idle second device")
    finally:
        s.stop()


def run_baseline(args, work, validate):
    """Same probe without DXVK_GAZE_VRS: nothing may be shaded coarsely."""
    s = Scenario(args, work, 1, validate)
    try:
        s.start_writer(0.5, 0.5, 0.5, 0.5)
        s.start_probe(dict(DXVK_GAZE_FILE=str(s.gaze)))
        s.wait("without DXVK_GAZE_VRS everything is full rate", full_rate, 60)
        assert "GazeVRS" not in s.log(), "gaze code ran although DXVK_GAZE_VRS is unset"
    finally:
        s.stop()


def run_bench(args, root):
    """Time per frame of an expensive pixel shader at an HMD-sized target, VRS off and on."""
    width, height = map(int, args.bench_size.split("x"))
    env = dict(DXVK_GAZE_VRS="1", DXVK_GAZE_FMT="97", DXVK_GAZE_FAKE="fixed", DXVK_GAZE_COARSE="auto")
    cases = [("VRS off", {})]
    for spec in args.bench:
        full, mid_area, mid = (spec.split(",") + ["auto"])[:3]
        # DXVK ignores a value it cannot parse, so the label would lie.
        if not (full.isdigit() and mid_area.isdigit() and int(full) <= 100 and int(mid_area) <= 100):
            sys.exit(f"--bench {spec}: FULL and MID_AREA must be percentages")
        if mid not in ("auto", "1x1", "2x1", "1x2", "2x2"):
            sys.exit(f"--bench {spec}: mid must be auto, 1x1, 2x1, 1x2 or 2x2, not {mid}")
        cases.append((f"full_area={full} mid_area={mid_area} mid={mid}",
                      dict(env, DXVK_GAZE_FULL_AREA=full, DXVK_GAZE_MID_AREA=mid_area, DXVK_GAZE_MID=mid)))
    print(f"{width}x{height} side by side, {args.samples} sample(s), {args.bench_seconds:g} s per case")
    baseline = None
    for index, (name, case_env) in enumerate(cases):
        work = root / f"bench{index}"
        work.mkdir(parents=True)
        s = Scenario(args, work, args.samples)
        s.start_probe(case_env, args.bench_seconds, (width, height), ("bench",))
        try:
            s.probe.wait(timeout=args.bench_seconds + 90)
        finally:
            s.stop()
        frames, ms = s.grid_path.read_text().split()
        baseline = baseline or float(ms)
        print(f"  {name:<44} {float(ms):7.2f} ms/frame  {float(ms) / baseline:6.1%} of VRS off  ({frames} frames)")


def vuids(work):
    path = work / "validation.log"
    return set(re.findall(r"VUID-[\w-]+", path.read_text(errors="replace"))) if path.exists() else set()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dxvk", required=True)
    parser.add_argument("--probe", required=True)
    parser.add_argument("--writer", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--no-validate", action="store_true")
    parser.add_argument("--bench", nargs="*", metavar="FULL,MID_AREA[,MID]",
                        help="measure instead of test; default cases: 45,65 and 45,65,2x1")
    parser.add_argument("--bench-size", default="4128x2208")
    parser.add_argument("--bench-seconds", type=float, default=8.0)
    parser.add_argument("--samples", type=int, default=1)
    args = parser.parse_args()
    validate = not args.no_validate
    root = Path(args.work)
    shutil.rmtree(root, ignore_errors=True)

    def directory(name):
        path = root / name
        path.mkdir(parents=True)
        return path

    if args.bench is not None:
        args.bench = args.bench or ["45,65", "45,65,2x1"]
        return run_bench(args, root)

    print("baseline (VRS off):")
    baseline = directory("baseline")
    run_baseline(args, baseline, validate)
    print("gaze VRS, 1 sample:")
    single = directory("single")
    run_main(args, single, 1, validate)
    print("gaze VRS, 4x MSAA:")
    msaa = directory("msaa")
    run_main(args, msaa, 4, validate)
    print("gaze VRS, multiple passes and second device:")
    multipass = directory("multipass")
    run_multipass(args, multipass, validate)

    if validate:
        for work in (baseline, single, msaa, multipass):
            assert (work / "validation.log").exists(), "validation layer did not load"
        new = (vuids(single) | vuids(msaa) | vuids(multipass)) - vuids(baseline)
        assert not new, f"Vulkan validation errors introduced by gaze VRS: {sorted(new)}"
        print(f"  ok: no Vulkan validation errors beyond the {len(vuids(baseline))} of stock DXVK paths")
    print("DXVK gaze VRS end-to-end checks passed")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        print(f"FAILED: {error}", file=sys.stderr)
        sys.exit(1)
