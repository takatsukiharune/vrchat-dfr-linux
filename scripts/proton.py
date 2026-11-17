#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""The Proton builds Steam can use, and the gaze DXVK DLLs in them."""
import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

REPO = Path(os.path.abspath(__file__)).parent.parent

# Present in every d3d11.dll built with the gaze patches, absent from stock DXVK.
MARKER = b"DXVK_GAZE_VRS"

# The `git describe` string DXVK embeds, e.g. v3.1.1-174-gf86377680682448-GE-Proton(dirty).
DLL_VERSION = re.compile(rb"v[0-9]+\.[0-9]+(?:\.[0-9]+)?-[0-9]+-g[0-9a-f]{7,}[-+.A-Za-z0-9()]*")

MANIFEST = """\
"compatibilitytools"
{
  "compat_tools"
  {
    "%(name)s"
    {
      "install_path" "."
      "display_name" "%(name)s"
      "from_oslist"  "windows"
      "to_oslist"    "linux"
    }
  }
}
"""

INSTALL_HELP = """\
Installs the patched d3d11.dll and dxgi.dll for one Proton build.

Default: copy PROTON to <name>-dfr beside it and patch the copy. PROTON itself
is not changed. PROTON may also name such a copy, to update it."""

UNINSTALL_HELP = """\
Undoes install for one Proton build.

A <name>-dfr copy is deleted, whether PROTON names the copy or its source. A
build patched with --in-place gets its own DLLs back from the .stock copies."""


def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def dxvk_dir(proton):
    return proton / "files/lib/wine/dxvk/x86_64-windows"


def is_patched(dll):
    return MARKER in dll.read_bytes()


def dll_version(dll):
    match = DLL_VERSION.search(dll.read_bytes())
    return match[0].decode() if match else ""


def version_commit(version):
    match = re.match(r"v[0-9.]+-[0-9]+-g([0-9a-f]{7,})", version)
    return match[1] if match else ""


def same_commit(a, b):
    return bool(a and b) and (a.startswith(b) or b.startswith(a))


def first_line(path):
    return path.read_text(errors="replace").partition("\n")[0] if path.is_file() else ""


def dxvk_commit(proton):
    """The DXVK commit a Proton build ships: from dxvk/version, else from its stock DLL."""
    version = dxvk_dir(proton).parent / "version"
    if version.is_file() and (match := re.search(r"[0-9a-f]{40}", version.read_text(errors="replace"))):
        return match[0]
    dll = dxvk_dir(proton) / "d3d11.dll"
    if dll.with_name("d3d11.dll.stock").is_file():
        dll = dll.with_name("d3d11.dll.stock")
    if not dll.is_file() or is_patched(dll):
        return ""
    return version_commit(dll_version(dll))


def variant(proton):
    """Release name of a Proton build that patches DXVK itself (GE-Proton11-12,
    cachyos-11.0-20261015-slr). Empty for every other Proton build."""
    words = first_line(proton / "version").split()
    name = words[1] if len(words) > 1 else ""
    return name if name.startswith(("GE-Proton", "cachyos-")) else ""


def made_for(version, release):
    """A build for a Proton release carries that release's DXVK patches and names it."""
    if release:
        return f"-{release}-dfr." in version
    return re.search(r"-g[0-9a-f]+-dfr\.", version) is not None


def parse_vdf(text):
    """Steam's text VDF as a list of (key, value) pairs, where a block's value is
    its own list of pairs."""
    token = re.compile(r'"(?P<string>(?:[^"\\]|\\.)*)"|(?P<brace>[{}])|//[^\n]*|(?P<word>[^\s{}"]+)')
    unescape = {"n": "\n", "t": "\t"}
    tokens = iter([
        (m.lastgroup, re.sub(r"\\(.)", lambda e: unescape.get(e[1], e[1]), m[m.lastgroup]))
        for m in token.finditer(text) if m.lastgroup
    ])

    def block():
        pairs = []
        for kind, key in tokens:
            if kind == "brace":
                break
            kind, value = next(tokens, ("brace", "}"))
            if kind == "brace" and value == "}":
                break
            pairs.append((key, block() if kind == "brace" else value))
        return pairs

    return block()


def blocks(pairs, name):
    """Every block called `name`, at any depth. VDF keys ignore case."""
    for key, value in pairs:
        if isinstance(value, list):
            if key.lower() == name.lower():
                yield value
            yield from blocks(value, name)


def child(pairs, name, kind):
    """The value of the first pair called `name` when it is a `kind`, str or list
    for a block, else an empty one."""
    value = next((value for key, value in pairs if key.lower() == name.lower()), None)
    return value if isinstance(value, kind) else kind()


def internal_name(proton):
    """The name Steam stores per game for a compatibility tool: the first key
    under "compat_tools" in its manifest. Valve's Proton has no manifest, and
    its directory name stands in."""
    manifest = proton / "compatibilitytool.vdf"
    if manifest.is_file():
        tools = next(blocks(parse_vdf(manifest.read_text(errors="replace")), "compat_tools"), None)
        if tools:
            return tools[0][0]
    return proton.name


def write_manifest(proton, name):
    quoted = name.replace("\\", "\\\\").replace('"', '\\"')
    (proton / "compatibilitytool.vdf").write_text(MANIFEST % {"name": quoted})


def copy_source(proton):
    """The Proton build that install copied to this one, or None."""
    source = first_line(proton / ".dfr-clone")
    return Path(source) if source else None


def same_version(a, b):
    """Same version file, or neither has one."""
    def read(proton):
        path = proton / "version"
        return path.read_bytes() if path.exists() else None
    return read(a) == read(b)


def steam_roots():
    home = os.environ.get("HOME", "")
    roots = []
    for root in (os.environ.get("STEAM_DIR", ""), f"{home}/.local/share/Steam", f"{home}/.steam/steam",
                 f"{home}/.var/app/com.valvesoftware.Steam/.local/share/Steam"):
        if root and os.path.isdir(root) and Path(os.path.realpath(root)) not in roots:
            roots.append(Path(os.path.realpath(root)))
    return roots


def proton_installs():
    """Every Proton build Steam can use."""
    found = []
    for root in steam_roots():
        for parent in (root / "compatibilitytools.d", root / "steamapps/common"):
            if not parent.is_dir():
                continue
            dirs = [d for d in parent.iterdir() if d.is_dir() and not d.name.startswith(".")]
            found += [d for d in sorted(dirs, key=lambda d: d.name.casefold())
                      if (dxvk_dir(d) / "d3d11.dll").is_file()]
    return found


def listing():
    lines = []
    for proton in proton_installs():
        dll = dxvk_dir(proton) / "d3d11.dll"
        state = "patched" if is_patched(dll) else "stock"
        lines.append(f"  {state:<8} {dll_version(dll):<34} {proton}")
    return "\n".join(lines)


def resolve(name):
    """A path, or the directory name of a discovered Proton build."""
    if os.path.isdir(name):
        return Path(os.path.abspath(name))
    for proton in proton_installs():
        if proton.name == name:
            return proton
    die(f"No Proton build '{name}'. Found:\n{listing()}")


def tools_dir_of(proton):
    """compatibilitytools.d of the Steam installation that holds a Proton build."""
    for parent in ("/compatibilitytools.d/", "/steamapps/common/"):
        steam, found, _ = str(proton).rpartition(parent)
        if found:
            return Path(steam) / "compatibilitytools.d"
    return None


def replace_file(src, dst):
    """Replace a file, read-only or not, by renaming a new one over it. A running
    game keeps its old copy, and the new file gets the mode of the original."""
    fd, tmp = tempfile.mkstemp(prefix=dst.name + ".", dir=dst.parent)
    os.close(fd)
    try:
        shutil.copyfile(src, tmp)
        shutil.copymode(dst, tmp)
        os.replace(tmp, dst)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def install(args):
    target = resolve(args.proton)
    if not (dxvk_dir(target) / "d3d11.dll").is_file():
        die(f"No DXVK in {target}.")

    # source: the Proton build a copy is made from, None for --in-place. dest: where the DLLs go.
    source = copy_source(target)
    tools_dir = None
    if source:
        dest, tools_dir = target, target.parent
    elif args.in_place:
        dest = target
    else:
        source = target
        tools_dir = Path(args.tools_dir) if args.tools_dir else tools_dir_of(source)
        if not tools_dir:
            die(f"Cannot tell which Steam has {source}. Pass --tools-dir DIR.")
        dest = tools_dir / f"{source.name}-dfr"
        if dest.exists() and not copy_source(dest):
            die(f"{dest} exists and was not made by this script. Remove it, or patch it with: "
                f"{sys.argv[0]} install --in-place '{dest}'")
        if dest.exists() and copy_source(dest) != source:
            die(f"{dest} is a copy of {copy_source(dest)}, not of {source}.")

    # A new copy is made when there is none yet, or when --refresh asks for one
    # because its source changed.
    fresh = False
    if source:
        if not dest.exists():
            fresh = True
        elif not source.is_dir():
            if args.refresh:
                die(f"{source} no longer exists, so {dest} cannot be copied again.")
        elif not same_version(source, dest):
            if not args.refresh:
                die(f"{source} changed after {dest} was made.\n"
                    "Close the game and run again with --refresh to copy it again.")
            fresh = True

    # The DLLs must fit the DXVK the game will run with: the copy's own, unless a
    # new copy is about to replace it.
    shipped = source if fresh else dest
    commit, release = dxvk_commit(shipped), variant(shipped)

    dxvk_from = args.dxvk_from
    if not dxvk_from:
        for build in sorted((REPO / "dist").glob("dxvk*"), key=lambda d: d.name.casefold()):
            if not ((build / "d3d11.dll").is_file() and (build / "dxgi.dll").is_file()):
                continue
            version = dll_version(build / "d3d11.dll")
            if same_commit(commit, version_commit(version)) and made_for(version, release):
                dxvk_from = build
                break
        else:
            die(f"No build in {REPO / 'dist'} was made for {release or 'DXVK ' + (commit or 'of this Proton build')}.\n"
                f"Build it with: scripts/dev-container.sh build --proton '{shipped}'")

    with tempfile.TemporaryDirectory() as unpacked:
        dlls = Path(dxvk_from)
        if dlls.is_file() and dlls.suffix == ".zip":
            with zipfile.ZipFile(dlls) as archive:
                archive.extractall(unpacked)
            found = sorted(Path(unpacked).rglob("d3d11.dll"))
            dlls = found[0].parent if found else Path(unpacked)
        if not ((dlls / "d3d11.dll").is_file() and (dlls / "dxgi.dll").is_file()):
            die(f"No d3d11.dll and dxgi.dll in {dlls}.")
        if not is_patched(dlls / "d3d11.dll"):
            die(f"{dlls / 'd3d11.dll'} is not a gaze-VRS build.")

        new_version = dll_version(dlls / "d3d11.dll")
        if not commit:
            print("Cannot tell which DXVK commit this Proton build ships; version match not checked.")
        elif not same_commit(commit, version_commit(new_version)):
            message = f"The DLLs are DXVK {new_version}, but this Proton build ships DXVK commit {commit[:12]}."
            if not args.force:
                die(f"{message}\nBuild matching DLLs with: scripts/dev-container.sh build --proton '{shipped}'\n"
                    "or pass --force to install these.")
            print(f"{message} Installing them because of --force.")
        if not made_for(new_version, release):
            print(f"Note: these DLLs were not built with the DXVK patches of {release or 'plain upstream DXVK'}.")

        # Steam keeps the internal name per game. The copy uses its source's name
        # plus -dfr, so a game set to a hand-made copy of the same name keeps working.
        name = None
        if source and source.is_dir():
            name = internal_name(source) + "-dfr"
            others = tools_dir.iterdir() if tools_dir.is_dir() else []
            for other in others:
                if other.is_dir() and not other.name.startswith(".") and other != dest and internal_name(other) == name:
                    die(f"{other} already uses the name {name}; Steam could pick either. Remove one of them.")

        def install_dlls(proton):
            for dll in ("d3d11.dll", "dxgi.dll"):
                replace_file(dlls / dll, dxvk_dir(proton) / dll)

        if fresh:
            tools_dir.mkdir(parents=True, exist_ok=True)
            staging = Path(tempfile.mkdtemp(prefix=dest.name + ".", dir=tools_dir))
            try:
                if subprocess.run(["cp", "-a", "--reflink=auto", f"{source}/.", f"{staging}/"]).returncode:
                    die(f"Cannot copy {source} to {staging}.")
                (staging / ".dfr-clone").write_text(f"{source}\n")
                write_manifest(staging, name)
                install_dlls(staging)
                if dest.exists():
                    shutil.rmtree(dest)
                staging.rename(dest)
            finally:
                shutil.rmtree(staging, ignore_errors=True)
            print(f"Made {dest} from {source} with DXVK {new_version}.")
            print(f"Select '{name}' as the compatibility tool for the game in Steam (restart Steam if it is not listed).")
            return

        if name:
            write_manifest(dest, name)
        elif not source:
            # Keep Proton's own DLLs once. A patched DLL is never kept as stock.
            target_dlls = dxvk_dir(dest)
            if not is_patched(target_dlls / "d3d11.dll"):
                for dll in ("d3d11.dll", "dxgi.dll"):
                    stock = target_dlls / f"{dll}.stock"
                    stock.unlink(missing_ok=True)
                    shutil.copy2(target_dlls / dll, stock)
                print(f"Kept Proton's DLLs as {target_dlls}/{{d3d11,dxgi}}.dll.stock")
            elif not (target_dlls / "d3d11.dll.stock").is_file():
                print(f"{dest} is already patched and has no .stock copy; uninstall cannot bring its own DLLs back.")
        install_dlls(dest)
        print(f"Installed DXVK {new_version} into {dest}.")


def uninstall(args):
    proton = resolve(args.proton)
    removed_message = "Removed {}. Select another compatibility tool for the game in Steam."
    if copy_source(proton):
        shutil.rmtree(proton)
        print(removed_message.format(proton))
        return
    removed = False
    for copy in proton_installs():
        if copy_source(copy) == proton:
            shutil.rmtree(copy)
            print(removed_message.format(copy))
            removed = True

    dlls = dxvk_dir(proton)
    if not (dlls / "d3d11.dll").is_file():
        die(f"No DXVK in {proton}.")
    stock = {dll: dlls / f"{dll}.stock" for dll in ("d3d11.dll", "dxgi.dll")}
    if not is_patched(dlls / "d3d11.dll"):
        # A Proton update put its own, newer DLLs back: the kept ones are older.
        for path in stock.values():
            path.unlink(missing_ok=True)
        if not removed:
            print(f"{proton} already has Proton's own DXVK.")
        return
    if not all(path.is_file() for path in stock.values()):
        die(f"{proton} is patched but has no .stock copies. Reinstall this Proton build, or verify its files in Steam.")
    for dll, path in stock.items():
        os.replace(path, dlls / dll)
    print(f"Proton's own DXVK is back in {proton}.")


def read_vdf(path):
    return parse_vdf(path.read_text(errors="replace")) if path.is_file() else []


def launch_environment(options):
    """The environment Steam's launch options give the game: the shell words
    before %command%, as assignments up to the first command word, or after
    `env`. Without %command% the options are game arguments and set nothing."""
    try:
        words = shlex.split(options)
    except ValueError:
        return {}
    if "%command%" not in words:
        return {}
    env, assigning = {}, True
    for word in words[:words.index("%command%")]:
        name, eq, value = word.partition("=")
        if eq and re.fullmatch(r"\w+", name, re.ASCII):
            if assigning:
                env[name] = value
        elif word == "env":
            assigning = True
        else:
            assigning = False
    return env


def find_tool(steam, name):
    """The Proton build Steam calls `name`: a tool in compatibilitytools.d that
    declares it, or Valve's Proton in steamapps/common."""
    # proton_experimental, proton_hotfix, proton_9: "Proton - Experimental", "Proton Hotfix", "Proton 9.0..."
    folder = {"proton_experimental": "Proton - Experimental", "proton_hotfix": "Proton Hotfix"}.get(name)
    if not folder and name.startswith("proton_"):
        folder = f"Proton {name[len('proton_'):]}.0"
    for proton in proton_installs():
        if proton.parent == steam / "compatibilitytools.d" and internal_name(proton) == name:
            return proton
        if proton.parent == steam / "steamapps/common" and folder and proton.name.startswith(folder):
            return proton
    return None


def doctor(args):
    """Checks the Proton build and the launch options Steam uses for a game."""
    problems = 0

    def bad(message):
        nonlocal problems
        problems += 1
        print(f"  !! {message}")

    app = args.app
    roots = [steam for steam in steam_roots() if (steam / "config/config.vdf").is_file()]
    if not roots:
        bad("no Steam configuration found; set STEAM_DIR")
    for steam in roots:
        print(f"Steam:  {steam}")
        mapping = next(blocks(read_vdf(steam / "config/config.vdf"), "CompatToolMapping"), [])
        # A game without a tool of its own uses Steam's default, stored as app 0.
        name = child(child(mapping, app, list), "name", str) or child(child(mapping, "0", list), "name", str)
        tool = find_tool(steam, name) if name else None
        if not name:
            bad(f"app {app} has no compatibility tool selected; select a patched one in its Steam properties")
        elif not tool:
            bad(f"app {app} uses '{name}', which is not in compatibilitytools.d; scripts/proton.py install makes a patched copy")
        else:
            dll = dxvk_dir(tool) / "d3d11.dll"
            version, commit, release, patched = dll_version(dll), dxvk_commit(tool), variant(tool), is_patched(dll)
            if not patched:
                bad(f"app {app} uses '{name}' with stock DXVK {version}; run scripts/proton.py install")
            elif not same_commit(commit, version_commit(version)):
                bad(f"'{name}' has gaze DXVK {version}, but this Proton build ships DXVK commit {commit[:12]}; "
                    "build with --proton and reinstall")
            else:
                print(f"  ok app {app} uses '{name}' with gaze DXVK {version}")
            # GE-Proton and proton-cachyos patch DXVK; a build for them names the release.
            if patched and release and not made_for(version, release):
                bad(f"this DXVK lacks the DXVK patches of {release}; build with --proton and reinstall")
            # A copy whose source is gone keeps working; one whose source changed is behind.
            source = copy_source(tool)
            if source and source.is_dir() and not same_version(source, tool):
                bad(f"{source} changed after this copy was made; run scripts/proton.py install --refresh '{tool.name}'")

        userdata = steam / "userdata"
        options = []
        for user in sorted(userdata.iterdir()) if userdata.is_dir() else []:
            for apps in blocks(read_vdf(user / "config/localconfig.vdf"), "apps"):
                if launch := child(child(apps, app, list), "LaunchOptions", str):
                    options.append(launch)
                    break
        if not options:
            bad(f"no launch options set for app {app}; see 'dfrctl launch-options'")
        for env in map(launch_environment, options):
            gaze_file = env.get("DXVK_GAZE_FILE", "")
            if env.get("DXVK_GAZE_VRS") != "1":
                bad("launch options lack DXVK_GAZE_VRS=1 before %command%; see 'dfrctl launch-options'")
            elif env.get("DXVK_GAZE_CONFIG") != args.config:
                bad(f"launch options do not point DXVK_GAZE_CONFIG at {args.config}; live tuning and status are off")
            elif gaze_file and gaze_file != args.gaze_file:
                bad(f"launch options use gaze file {gaze_file}, but dfrctl status reads {args.gaze_file}")
            else:
                print("  ok launch options enable gaze VRS with this config file")
    print(f"Problems found: {problems}" if problems else "No problems found.")
    if problems:
        sys.exit(1)


def default_config():
    """dfrctl's config file, the one the launch options must name."""
    if os.environ.get("DFR_CONFIG"):
        return os.environ["DFR_CONFIG"]
    config_home = os.environ.get("XDG_CONFIG_HOME") or f"{os.environ.get('HOME', '')}/.config"
    return f"{config_home}/vrchat-dfr/dfr.conf"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")
    commands.add_parser("list", help="list the Proton builds found")

    proton_help = "a directory, or the directory name of a Proton build that 'list' shows"
    raw = argparse.RawDescriptionHelpFormatter
    command = commands.add_parser("install", help="install the gaze DXVK DLLs", description=INSTALL_HELP, formatter_class=raw)
    command.add_argument("--in-place", action="store_true",
                         help="patch PROTON itself and keep its DLLs as d3d11.dll.stock and dxgi.dll.stock")
    command.add_argument("--refresh", action="store_true", help="copy PROTON again when it changed after <name>-dfr was made")
    command.add_argument("--dxvk-from", metavar="PATH", default=os.environ.get("DXVK_FROM", ""),
                         help="directory or .zip with d3d11.dll and dxgi.dll "
                              "(default: the build in dist/ made for PROTON with `build --proton`)")
    command.add_argument("--force", action="store_true", help="install DLLs built from a different DXVK commit than PROTON ships")
    command.add_argument("--tools-dir", metavar="DIR",
                         help="where <name>-dfr goes (default: the compatibilitytools.d of PROTON's Steam)")
    command.add_argument("proton", metavar="PROTON", help=proton_help)
    command = commands.add_parser("uninstall", help="undo install", description=UNINSTALL_HELP, formatter_class=raw)
    command.add_argument("proton", metavar="PROTON", help=proton_help)

    command = commands.add_parser("doctor", help="check the Proton build and the launch options of a Steam game")
    command.add_argument("--config", metavar="PATH", default=default_config(),
                         help="the config file the launch options must name (default: dfrctl's)")
    command.add_argument("--gaze-file", metavar="PATH",
                         default=os.environ.get("DFR_GAZE_FILE") or "/dev/shm/vrchat_dfr_gaze",
                         help="the gaze file dfrctl status reads")
    command.add_argument("app", metavar="APPID", nargs="?", default="438100", help="the Steam app (default: 438100, VRChat)")

    command = commands.add_parser("resolve", help="print the directory of a Proton build")
    command.add_argument("proton", metavar="PROTON", help=proton_help)
    command = commands.add_parser("commit", help="print the DXVK commit a Proton build ships; fails when unknown")
    command.add_argument("dir", metavar="DIR", type=Path)
    command = commands.add_parser("variant", help="print the GE-Proton or proton-cachyos release of a Proton build, if any")
    command.add_argument("dir", metavar="DIR", type=Path)
    command = commands.add_parser("dll-version", help="print the DXVK version a DLL names")
    command.add_argument("dll", metavar="DLL", type=Path)

    args = parser.parse_args()
    if args.command == "list":
        print(listing())
    elif args.command == "install":
        install(args)
    elif args.command == "uninstall":
        uninstall(args)
    elif args.command == "doctor":
        doctor(args)
    elif args.command == "resolve":
        print(resolve(args.proton))
    elif args.command == "commit":
        commit = dxvk_commit(args.dir)
        if not commit:
            sys.exit(1)
        print(commit)
    elif args.command == "variant":
        print(variant(args.dir))
    elif args.command == "dll-version":
        print(dll_version(args.dll))


if __name__ == "__main__":
    main()
